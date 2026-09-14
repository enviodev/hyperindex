open Vitest

// A batch reaches ClickHouse as entity rows first and their checkpoints last,
// so a checkpoint row is what makes the rows it covers readable. Where each
// chain counts its own checkpoints, the ids of two chains are not comparable:
// a sibling's higher id must not make another chain's not-yet-checkpointed rows
// readable.

let chainYaml = chainId =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"`

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-frontier
disable_default_cross_chain: true
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:${chainYaml(1)}${chainYaml(137)}
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

let setCounter = (~count) =>
  async (args: Internal.handlerArgs) => {
    let context = args.context->(Utils.magic: Internal.handlerContext => counterContext)
    context.counter.set({id: "total", count})
  }

let feed = async (indexer: IndexerRunner.t, ~source: MockSource.t, ~blockNumber, ~count) => {
  source.resolveGetItemsOrThrow(
    [{blockNumber, logIndex: 0, handler: setCounter(~count)}],
    ~filter=MockSource.coveringBlock(blockNumber),
    ~latestFetchedBlockNumber=blockNumber,
  )
  await indexer.getBatchWritePromise()
}

describe("ClickHouse view under per-chain checkpoints", () => {
  scenario->Scenario.it(
    "hides a chain's rows until that chain's own checkpoint lands",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source) => {
      source(1).resolveGetHeightOrThrow(100000)
      source(137).resolveGetHeightOrThrow(100000)
      // Chain 1 takes ids 1..3; chain 137 takes id 1 of its own sequence.
      await feed(indexer, ~source=source(1), ~blockNumber=5, ~count=1n)
      await feed(indexer, ~source=source(1), ~blockNumber=12, ~count=2n)
      await feed(indexer, ~source=source(1), ~blockNumber=14, ~count=3n)
      await feed(indexer, ~source=source(137), ~blockNumber=5, ~count=10n)

      // Chain 137's next batch, caught between its entity insert and its
      // checkpoint insert: the row is there, the checkpoint proving it is not.
      let database = TestClickHouse.currentDatabase()
      let _ = await TestClickHouse.query(
        `INSERT INTO \`${database}\`.\`envio_history_Counter\` (id, chainId, count, envio_checkpoint_id, envio_change) VALUES ('total', 137, 999, 2, 'SET')`,
      )

      let rows = await TestClickHouse.query(
        `SELECT chainId, count FROM \`${database}\`.\`Counter\` ORDER BY chainId FORMAT JSONEachRow`,
      )
      t.expect(rows->String.trim->String.split("\n")).toEqual([
        `{"chainId":1,"count":"3"}`,
        `{"chainId":137,"count":"10"}`,
      ])
    },
  )
})
