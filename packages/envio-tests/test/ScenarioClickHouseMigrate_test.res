open Vitest

// `envio local db-migrate up` against a deployment that is still indexing, as a
// deploy step can run it. It checks the storage and leaves it be: resuming
// ClickHouse under the live run would fence off the chains' rows that run goes
// on writing, and nothing it indexed afterwards would become readable there.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-migrate-beside-a-run
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
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
  ~unsupported=[{backend: #postgres, reason: "asserts against a ClickHouse server"}],
)

type counter = {id: string, count: bigint}
type counterOps = {set: counter => unit}
type counterContext = {@as("Counter") counter: counterOps}

let setCounter = (~block, ~count): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args =>
    (args.context->(Utils.magic: Internal.handlerContext => counterContext)).counter.set({
      id: "total",
      count,
    }),
}

describe("A migration beside a run that is indexing", () => {
  scenario->Scenario.it("leaves ClickHouse to the run", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let source = source(1)
    source.resolveGetHeightOrThrow(20)
    await source.expectItemsQueries([
      {
        fromBlock: 0,
        toBlock: Unbounded,
        reply: Respond({items: [setCounter(~block=5, ~count=1n)], latestFetchedBlockNumber: 10}),
      },
    ])
    await indexer.getBatchWritePromise()

    let config = scenario.config
    let storage = Storage.makeStorageFromEnv(
      ~config,
      ~pgSchema=indexer.pg.pgSchema,
      ~isHasuraEnabled=false,
    )
    await Storage.makePersistenceFromConfig(~config, ~storage)->Main.migrateStorage(
      ~config,
      ~reset=false,
    )
    await storage.close()

    await source.expectItemsQueries([
      {
        fromBlock: 11,
        toBlock: Unbounded,
        reply: Respond({items: [setCounter(~block=15, ~count=2n)], latestFetchedBlockNumber: 20}),
      },
    ])
    await indexer.getBatchWritePromise()

    let database = TestClickHouse.currentDatabase()
    let rows = await TestClickHouse.query(
      `SELECT id, count FROM \`${database}\`.\`Counter\` FORMAT JSONEachRow`,
    )
    t.expect(rows->String.trim).toEqual(`{"id":"total","count":"2"}`)
  })
})
