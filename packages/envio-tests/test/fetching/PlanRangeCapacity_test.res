open Vitest

// The range a source served on its last two partial responses sizes the
// chunks a partition is split into (1.8x the smaller of the two). Parallel
// chunks can answer out of order, and an earlier chunk's response landing after
// a later one's is stale evidence: it must not shrink the chunks.
let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-range-capacity
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
)

// Splits the partition into 900-block chunks, served 501 then 500 blocks, and
// answers the chunks 1001..1900 and 1901..2800 partially, in the given order:
// 1001..1100 and 1901..2500. Returns the gap fills the chain asks for next.
let gapFillsAfterPartialChunks = async (
  ~indexer: IndexerRunner.t,
  ~mock: MockSource.t,
  ~laterChunkFirst,
) => {
  mock.resolveGetHeightOrThrow(100_000)
  await mock.expectItemsQueries([
    {
      fromBlock: 0,
      reply: Respond({items: [{blockNumber: 100, logIndex: 0}], latestFetchedBlockNumber: 500}),
    },
  ])
  await mock.expectItemsQueries([
    {
      fromBlock: 501,
      reply: Respond({items: [{blockNumber: 600, logIndex: 0}], latestFetchedBlockNumber: 1000}),
    },
  ])
  let respondPartially = async (~fromBlock, ~toBlock, ~latestFetchedBlockNumber) =>
    await mock.expectItemsQueries([
      {
        fromBlock,
        toBlock: Bounded(toBlock),
        reply: Respond({items: [], latestFetchedBlockNumber}),
      },
      {reply: LeavePending},
    ])
  let earlierChunk = () =>
    respondPartially(~fromBlock=1001, ~toBlock=1900, ~latestFetchedBlockNumber=1100)
  let laterChunk = () =>
    respondPartially(~fromBlock=1901, ~toBlock=2800, ~latestFetchedBlockNumber=2500)
  if laterChunkFirst {
    await laterChunk()
    await earlierChunk()
  } else {
    await earlierChunk()
    await laterChunk()
  }
  await indexer.waitUntilIdle()
  mock.pendingItemsQueries
  ->Array.filter(query => query.fromBlock < 2801)
  ->Array.map(query => (query.fromBlock, query.toBlock))
  ->Array.toSorted(((a, _), (b, _)) => Int.compare(a, b))
}

describe("Indexing plan: source range capacity", () => {
  scenario->Scenario.it(
    "shrinks the chunks to an earlier chunk's partial response landing first",
    ~sources=[{chain: 1}],
    ~targetBufferSize=100_000,
    async (~t, ~indexer, ~source) => {
      t.expect(
        await gapFillsAfterPartialChunks(~indexer, ~mock=source(1), ~laterChunkFirst=false),
      ).toEqual([(1101, MockSource.Bounded(1280)), (1281, Bounded(1460))])
    },
  )

  scenario->Scenario.it(
    "keeps the chunk size when an earlier chunk's partial response lands after a later one's",
    ~sources=[{chain: 1}],
    ~targetBufferSize=100_000,
    async (~t, ~indexer, ~source) => {
      t.expect(
        await gapFillsAfterPartialChunks(~indexer, ~mock=source(1), ~laterChunkFirst=true),
      ).toEqual([(1101, MockSource.Bounded(1900)), (2501, Bounded(2800))])
    },
  )
})
