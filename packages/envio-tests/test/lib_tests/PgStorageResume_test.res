open Vitest

// Two processes racing to add the same chain can't be lined up from outside,
// so this one case drives the storage directly.
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
let enums = config.allEnums
let pgSchemas = []

let makeStorage = () => {
  let pgSchema = TestPgSchema.make()
  pgSchemas->Array.push(pgSchema)->ignore
  PgStorage.make(~pgSchema, ~ecosystem=Evm)
}

let storedOf = (chains: array<Config.chain>): ResumePlan.stored => {
  envioInfo: Some(config.envioInfo),
  chains: chains->Array.map((chain): ResumePlan.storedChain => {
    id: chain.id,
    ecosystem: (chain.ecosystem :> string),
    startBlock: chain->Config.startBlockOrThrow,
    endBlock: chain.endBlock,
    maxReorgDepth: chain.maxReorgDepth,
    // The encoder hands back a Buffer; a bytea read back is a plain Uint8Array.
    configAddresses: chain
    ->ChainState.configStorageRows(
      ~ecosystem=chain.ecosystem,
      ~contractMapping=config.contractMapping,
    )
    ->Array.map(row => {
      ...row,
      address: row.address
      ->(Utils.magic: NodeJs.Buffer.t => Uint8Array.t)
      ->Uint8Array.fromArrayLikeOrIterable
      ->(Utils.magic: Uint8Array.t => NodeJs.Buffer.t),
    }),
  }),
  contractMapping: config.contractMapping,
}

Async.afterAll(async () => {
  for idx in 0 to pgSchemas->Array.length - 1 {
    let _ = await sql->Sql.query(
      `DROP SCHEMA IF EXISTS "${pgSchemas->Array.getUnsafe(idx)}" CASCADE;`,
    )
  }
  await sql->Sql.close
})

describe("Resuming Postgres storage", () => {
  // Two `envio start --chain` processes naming the same new chain can both
  // plan to add it. Only one may: the other would index the chain alongside it.
  Async.it("adds a chain once, failing a second add of it that runs at the same time", async t => {
    let storage = makeStorage()
    let _ = await storage.initialize(
      ~chainConfigs=[],
      ~contractMapping=config.contractMapping,
      ~entities,
      ~enums,
      ~envioInfo=config.envioInfo,
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
