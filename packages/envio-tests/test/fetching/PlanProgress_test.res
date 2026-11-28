open Vitest

// A batch's progress block is the block it fully processed: the fetched
// frontier once the chain's ready items are all taken, or the block just below
// the first item a batch left behind, since that block is only partly done.
let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-progress
rollback_on_reorg: false
full_batch_size: 1
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address:
          - "0x0000000000000000000000000000000000000001"
          - "0x0000000000000000000000000000000000000002"
`,
)

let progressBlock = async (indexer: IndexerRunner.t) => await indexer.metric("envio_progress_block")

let chainLabels = dict{"chainId": "1"}

// Holds the batch the item lands in until the test has read the progress the
// batches before it left.
let heldItem = (~blockNumber, ~logIndex, ~gate: MockSource.Gate.t): MockSource.itemMock => {
  blockNumber,
  logIndex,
  handler: _ => gate.wait(),
}

describe("Indexing plan: progress", () => {
  scenario->Scenario.it(
    "reaches the fetched block when nothing is left to process",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(1000)
      await mock.expectItemsQueries([{reply: Respond({items: [], latestFetchedBlockNumber: 100})}])
      await indexer.getBatchWritePromise()

      t.expect(await progressBlock(indexer)).toEqual([{value: "100", labels: chainLabels}])
    },
  )

  scenario->Scenario.it(
    "stops below the block of the next unprocessed item, whatever its log index",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      let atLogIndexZero = MockSource.Gate.make()
      let atLaterLogIndex = MockSource.Gate.make()
      mock.resolveGetHeightOrThrow(1000)
      await mock.expectItemsQueries([
        {
          reply: Respond({
            items: [
              {blockNumber: 50, logIndex: 0},
              heldItem(~blockNumber=55, ~logIndex=0, ~gate=atLogIndexZero),
              heldItem(~blockNumber=60, ~logIndex=5, ~gate=atLaterLogIndex),
            ],
            latestFetchedBlockNumber: 100,
          }),
        },
      ])

      // Real time: handlers run off the clock.
      await Scenario.waitUntil(
        () => atLogIndexZero.entered.contents > 0,
        ~message="the batch holding block 55",
      )
      let beforeBlock55 = await progressBlock(indexer)
      atLogIndexZero.release()

      // Real time: handlers run off the clock.
      await Scenario.waitUntil(
        () => atLaterLogIndex.entered.contents > 0,
        ~message="the batch holding block 60",
      )
      let beforeBlock60 = await progressBlock(indexer)
      atLaterLogIndex.release()
      await indexer.getBatchWritePromise()

      t.expect((beforeBlock55, beforeBlock60, await progressBlock(indexer))).toEqual((
        [{value: "54", labels: chainLabels}],
        [{value: "59", labels: chainLabels}],
        [{value: "100", labels: chainLabels}],
      ))
    },
  )

  scenario->Scenario.it(
    "stays at the lagging partition's frontier while items wait above it",
    ~sources=[{chain: 1}],
    ~maxAddressesPerGroup=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(1000)
      await mock.expectItemsQueries([
        {
          address: "0x0000000000000000000000000000000000000001",
          reply: Respond({
            items: [
              {blockNumber: 101, logIndex: 2},
              {blockNumber: 103, logIndex: 1},
              {blockNumber: 105, logIndex: 2},
            ],
            latestFetchedBlockNumber: 110,
          }),
        },
        {
          address: "0x0000000000000000000000000000000000000002",
          reply: Respond({items: [], latestFetchedBlockNumber: 90}),
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect((
        await progressBlock(indexer),
        (await indexer.metric("envio_indexing_buffer_size"))->Array.map(
          ({value}: IndexerRunner.metric) => value,
        ),
      )).toEqual(([{value: "90", labels: chainLabels}], ["3"]))
    },
  )
})
