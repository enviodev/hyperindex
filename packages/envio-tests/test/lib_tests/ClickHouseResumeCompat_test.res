open Vitest

// The stored config lives in Postgres, and it is what decides whether a resume
// is allowed at all. A resume that ClickHouse would trip over (an entity added
// since the storage was built, whose history table it never created) has to be
// refused off that stored config first, so the user reads which config paths
// changed rather than a ClickHouse error about a table it doesn't have.

let sql = PgStorage.makeClient()

let configYaml = `
name: clickhouse-resume-compat
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
storage:
  postgres:
    default: true
  clickhouse:
    default: true
`

let counterSchema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

let counterAndExtraSchema = `
type Counter {
  id: ID!
  count: BigInt!
}

type Extra {
  id: ID!
}
`

// What `envio start` stores and later diffs: the public config, with the
// entities the schema declares.
let parse = (~schema) => {
  let publicConfigJson = Core.fromUserApi(~schema, configYaml).config->JSON.parseOrThrow
  (Config.fromPublic(publicConfigJson), publicConfigJson->Config.stripSensitiveData)
}

let created = []

Async.afterAll(async () => {
  let _ = await created
  ->Array.map(async ((pgSchema, database)) => {
    let _ = await sql->Postgres.unsafe(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`)
    await TestClickHouse.drop(~database)
  })
  ->Promise.all
  await sql->Postgres.endSql
})

let init = async (~config, ~envioInfo, ~pgSchema, ~database, ~reset) => {
  TestClickHouse.use(~database)
  let storage = PgStorage.makeStorageFromEnv(~config, ~sql, ~pgSchema, ~isHasuraEnabled=false)
  let persistence = PgStorage.makePersistenceFromConfig(~config, ~storage)
  await persistence->Persistence.init(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping=config.contractMapping,
    ~envioInfo,
    ~resetCommand="envio start -r",
    ~runCommand=Some("envio start"),
    ~reset,
  )
}

describe("Resuming ClickHouse storage against a changed config", () => {
  let name = "refuses an added entity off the stored config, before ClickHouse is asked"
  switch IndexerRunner.selectedBackend {
  | #postgres =>
    Async.it_skip(`${name} [no postgres: asserts against a ClickHouse server]`, async _ => ())
  | #clickhouse =>
    Async.it(name, async t => {
      let pgSchema = TestPgSchema.make()
      let database = TestClickHouse.make()
      created->Array.push((pgSchema, database))->ignore

      let (config, envioInfo) = parse(~schema=counterSchema)
      await init(~config, ~envioInfo, ~pgSchema, ~database, ~reset=true)

      let (changedConfig, changedEnvioInfo) = parse(~schema=counterAndExtraSchema)
      let message = try {
        await init(
          ~config=changedConfig,
          ~envioInfo=changedEnvioInfo,
          ~pgSchema,
          ~database,
          ~reset=false,
        )
        "the resume to fail, but it succeeded"
      } catch {
      | JsExn(e) => e->JsExn.message->Option.getOr("an error without a message")
      | Persistence.StorageError({message}) => message
      }

      t.expect(
        message->String.includes(
          "The following config changes are incompatible with the existing indexer data",
        ),
        ~message,
      ).toBe(true)
    })
  }
})
