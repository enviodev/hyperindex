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
let pgSchemas = []

let makeStorage = () => {
  let pgSchema = TestPgSchema.make()
  pgSchemas->Array.push(pgSchema)->ignore
  PgStorage.make(
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
}

let storedOf = (chains: array<Config.chain>): Config.stored => {
  config: Some(config.storedConfig),
  chains: chains->Array.map(chain => (chain.id, chain.storedConfig)),
  contractMapping: config.contractMapping,
}

Async.afterAll(async () => {
  for idx in 0 to pgSchemas->Array.length - 1 {
    let _ = await sql->Postgres.unsafe(
      `DROP SCHEMA IF EXISTS "${pgSchemas->Array.getUnsafe(idx)}" CASCADE;`,
    )
  }
  await sql->Postgres.endSql
})

describe("Resuming Postgres storage", () => {
  Async.it(
    "reads back the config it was initialized with, each chain from its own row",
    async t => {
      let storage = makeStorage()
      let _ = await storage.initialize(
        ~chainConfigs=config.chainMap->ChainMap.values,
        ~contractMapping=config.contractMapping,
        ~entities,
        ~enums,
        ~storedConfig=config.storedConfig,
      )

      t.expect(await storage.readStoredConfig()).toEqual(config.chainMap->ChainMap.values->storedOf)
    },
  )

  // Two `envio start --chain` processes naming the same new chain can both
  // plan to add it. Only one may: the other would index the chain alongside it.
  Async.it("adds a chain once, failing a second add of it that runs at the same time", async t => {
    let storage = makeStorage()
    let _ = await storage.initialize(
      ~chainConfigs=[],
      ~contractMapping=config.contractMapping,
      ~entities,
      ~enums,
      ~storedConfig=config.storedConfig,
    )
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    let add = async () =>
      switch await storage.addChain(
        ~chainConfig=chain,
        ~entities,
        ~contractMapping=config.contractMapping,
      ) {
      | () => true
      | exception _ => false
      }

    let added = await Promise.all([add(), add()])

    t.expect((
      added->Array.filter(added => added)->Array.length,
      await storage.readStoredConfig(),
    )).toEqual((1, [chain]->storedOf))
  })
})
