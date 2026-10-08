open Vitest

// A schema whose addresses are keyed without the contract mapping can't be
// resumed against.
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
let enums = config.allEnums

let chainId = (config.chainMap->ChainMap.values->Array.getUnsafe(0)).id
let contractMapping = config.contractMapping

let createdSchemas = []

Async.afterAll(async () => {
  let _ = await createdSchemas
  ->Array.map(pgSchema => sql->Sql.query(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`))
  ->Promise.all
  await sql->Sql.close
})

let setup = async () => {
  let pgSchema = TestPgSchema.make()
  createdSchemas->Array.push(pgSchema)->ignore
  let storage = PgStorage.make(~pgSchema, ~ecosystem=Evm)
  let _ = await storage.initialize(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping,
    ~entities=config.userEntities,
    ~enums,
    ~envioInfo=JSON.Encode.object(Dict.make()),
  )
  (storage, pgSchema)
}

describe("envio_addresses", () => {
  // A schema written before the addresses table was reshaped can't be resumed
  // against: the rows in it are keyed differently. That has to surface as the
  // incompatible-storage error, not as a missing column halfway through the
  // resume.
  Async.it("refuses to resume a schema that predates the contract mapping", async t => {
    let (storage, pgSchema) = await setup()
    let _ = await sql->Sql.query(`DROP TABLE "${pgSchema}"."envio_contracts";`)
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
      ~message,
    ).toBe(true)
  })
})
