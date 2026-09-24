open Vitest

// What Postgres stored is what the compatibility check has to be handed: the
// only thing binding the check to the storage is this read.
let sql = PgStorage.makeClient()

let config = TestConfig.make(
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
)
let entities = [config->IndexerRunner.entityConfigByName("Counter")]
let enums =
  config.allEnums->Array.concat([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])
let pgSchema = TestPgSchema.make()

Async.afterAll(async () => {
  let _ = await sql->Postgres.unsafe(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`)
  await sql->Postgres.endSql
})

describe("Resuming Postgres storage", () => {
  Async.it(
    "reads back the config it was initialized with, each chain from its own row",
    async t => {
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
        ~contractMapping=config.contractMapping,
        ~entities,
        ~enums,
        ~storedConfig=config.storedConfig,
      )

      t.expect(await storage.readStoredConfig()).toEqual(
        (
          {
            config: Some(config.storedConfig),
            chains: config.chainMap
            ->ChainMap.values
            ->Array.map(chain => (chain.id, chain.storedConfig)),
            contractMapping: config.contractMapping,
          }: Config.stored
        ),
      )
    },
  )
})
