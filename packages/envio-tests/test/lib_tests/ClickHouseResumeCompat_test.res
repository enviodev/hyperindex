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

let init = async (~schema, ~pgSchema, ~reset) => {
  let publicConfigJson = Core.fromUserApi(~schema, configYaml).config->JSON.parseOrThrow
  let config = Config.fromPublic(publicConfigJson)
  let storage = PgStorage.makeStorageFromEnv(~config, ~sql, ~pgSchema, ~isHasuraEnabled=false)
  await PgStorage.makePersistenceFromConfig(~config, ~storage)->Persistence.init(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping=config.contractMapping,
    ~envioInfo=publicConfigJson->Config.stripSensitiveData,
    ~resetCommand="envio start -r",
    ~runCommand=Some("envio start"),
    ~reset,
  )
}

Async.afterAll(async () => {
  await sql->Postgres.endSql
})

describe("Resuming ClickHouse storage against a changed config", () => {
  let name = "refuses an added entity off the stored config, before ClickHouse is asked"
  switch IndexerRunner.selectedBackend {
  | #postgres =>
    Async.it_skip(`${name} [no postgres: asserts against a ClickHouse server]`, async _ => ())
  | #clickhouse =>
    Async.it(name, async t => {
      let pgSchema = TestPgSchema.make()
      let database = TestClickHouse.make()
      TestClickHouse.use(~database)

      await init(~schema=counterSchema, ~pgSchema, ~reset=true)
      let message = try {
        await init(~schema=counterAndExtraSchema, ~pgSchema, ~reset=false)
        "the resume to fail, but it succeeded"
      } catch {
      | JsExn(e) => e->JsExn.message->Option.getOr("an error without a message")
      | Persistence.StorageError({message}) => message
      }
      let _ = await sql->Postgres.unsafe(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`)
      await TestClickHouse.drop(~database)

      t.expect(
        message,
      ).toBe(`The following config changes are incompatible with the existing indexer data:

    - entities[1]

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio start -r            # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_CLICKHOUSE_DATABASE=<new_db> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio start`)
    })
  }
})
