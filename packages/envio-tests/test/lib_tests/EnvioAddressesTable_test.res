open Vitest

// envio_addresses is insert-only, one row per (chain, address, contract).
// Rollback deletes rows by that primary key. These run against a real database.
let sql = PgStorage.makeClient()

// Two contracts, one of them holding the chain's only config address.
let config = TestConfig.fromUserApi(`
name: envio-addresses-table
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
      - name: NftFactory
        events:
          - event: "TestEvent()"
`)
let enums =
  config.allEnums->Array.concat([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])

let chainId = (config.chainMap->ChainMap.values->Array.getUnsafe(0)).id
let contractMapping = config.contractMapping

let createdSchemas = []

Async.afterAll(async () => {
  let _ = await createdSchemas
  ->Array.map(pgSchema => sql->Postgres.unsafe(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`))
  ->Promise.all
  await sql->Postgres.endSql
})

let setup = async () => {
  let pgSchema = TestPgSchema.make()
  createdSchemas->Array.push(pgSchema)->ignore
  let storage = PgStorage.make(
    ~sql,
    ~pgHost=Env.Db.host,
    ~pgSchema,
    ~pgPort=Env.Db.port,
    ~pgUser=Env.Db.user,
    ~pgDatabase=Env.Db.database,
    ~pgPassword=Env.Db.password,
    ~isHasuraEnabled=false,
    ~ecosystem=Evm,
  )
  let _ = await storage.initialize(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping,
    ~entities=config.userEntities,
    ~enums,
    ~envioInfo=JSON.Encode.object(Dict.make()),
  )
  (storage, pgSchema)
}

let address = index => Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(index)

let configAddress =
  ((config.chainMap->ChainMap.values->Array.getUnsafe(0)).contracts->Array.getUnsafe(0)).addresses
  ->Array.getUnsafe(0)

let row = (~address: Address.t, ~contractName, ~registrationBlock): AddressRows.row => {
  {
    chainId,
    address: Core.getAddon()
    .encodeAddresses(~ecosystem="evm", ~addresses=[address])
    ->Array.getUnsafe(0),
    contractId: contractMapping->ContractMapping.idOfOrThrow(contractName),
    registrationBlock,
  }
}

let storedRows = async (~pgSchema) => {
  let rows: array<AddressRows.row> = await sql->Postgres.unsafe(
    InternalTable.EnvioAddresses.makeGetRowsQuery(~pgSchema),
  )
  let rendered = rows->AddressRows.render(~ecosystem="evm", ~shouldChecksum=true)
  rows->Array.mapWithIndex((row, idx) => (
    rendered->Array.getUnsafe(idx),
    contractMapping->ContractMapping.nameOfOrThrow(row.contractId),
    row.registrationBlock,
  ))
}

describe("envio_addresses", () => {
  // https://github.com/enviodev/hyperindex/issues/1187
  Async.it("deletes one contract's registration of a shared address", async t => {
    let (_storage, pgSchema) = await setup()

    let sharedForNftFactory = row(
      ~address=address(1),
      ~contractName="NftFactory",
      ~registrationBlock=20,
    )
    await sql->InternalTable.EnvioAddresses.insert(
      ~pgSchema,
      ~rows=[
        row(~address=address(1), ~contractName="Gravatar", ~registrationBlock=10),
        // The same address, registered later for another contract.
        sharedForNftFactory,
        row(~address=address(2), ~contractName="NftFactory", ~registrationBlock=20),
      ],
    )

    // What a rollback past block 15 leaves the store holding.
    await sql->InternalTable.EnvioAddresses.delete(
      ~pgSchema,
      ~keys=[
        sharedForNftFactory->AddressRows.keyOf,
        row(~address=address(2), ~contractName="NftFactory", ~registrationBlock=20)
        ->AddressRows.keyOf,
      ],
    )

    t.expect(
      await storedRows(~pgSchema),
      ~message="the other contract's registration of the same address is untouched",
    ).toEqual([(configAddress, "Gravatar", -1), (address(1), "Gravatar", 10)])
  })

  // A schema written before the addresses table was reshaped can't be resumed
  // against: the rows in it are keyed differently. That has to surface as the
  // incompatible-storage error, not as a missing column halfway through the
  // resume.
  Async.it("refuses to resume a schema that predates the contract mapping", async t => {
    let (storage, pgSchema) = await setup()
    let _ = await sql->Postgres.unsafe(
      `DROP TABLE "${pgSchema}"."${InternalTable.EnvioContracts.table.tableName}";`,
    )
    let persistence = Persistence.make(
      ~userEntities=config.userEntities,
      ~allEnums=config.allEnums,
      ~storage,
    )
    let message = try {
      await persistence->Persistence.init(
        ~chainConfigs=config.chainMap->ChainMap.values,
        ~contractMapping=config.contractMapping,
        ~envioInfo=JSON.Encode.object(Dict.make()),
        ~resetCommand="envio local db-migrate setup",
        ~runCommand=None,
      )
      "the resume to fail, but it succeeded"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("")
    | _ => "an error without a message"
    }
    t.expect(
      message->String.includes("storage was initialized by an older envio version"),
      ~message=message,
    ).toBe(true)
  })

  Async.it("takes one row per contract and ignores a repeat of one", async t => {
    let (_storage, pgSchema) = await setup()

    let shared = row(~address=address(1), ~contractName="Gravatar", ~registrationBlock=10)
    await sql->InternalTable.EnvioAddresses.insert(
      ~pgSchema,
      ~rows=[
        shared,
        {...shared, contractId: contractMapping->ContractMapping.idOfOrThrow("NftFactory")},
      ],
    )
    // A retried batch write re-inserts what it already wrote.
    await sql->InternalTable.EnvioAddresses.insert(~pgSchema, ~rows=[shared])

    t.expect(
      (await storedRows(~pgSchema))->Array.filter(((_, _, block)) => block !== -1),
      ~message="the address is stored once per contract, however often it is written",
    ).toEqual([
      (address(1), "Gravatar", 10),
      (address(1), "NftFactory", 10),
    ])
  })
})
