open Vitest

// A chain is ready for the reorg threshold once its fetch frontier reaches the
// head the pre-threshold lag lets it fetch (max_reorg_depth + 1 below the
// known height), or its end block when that comes first, with nothing left to
// process at or below the frontier. With a head of 1000 and a depth of 199 the
// lagged head is block 800.
let makeScenario = (~name, ~endBlock=?, ~startBlock=1, ~addresses=1) => {
  let endBlockYaml = switch endBlock {
  | Some(endBlock) => `\n    end_block: ${endBlock->Int.toString}`
  | None => ""
  }
  let addressesYaml =
    Array.fromInitializer(~length=addresses, i =>
      `\n          - "0x000000000000000000000000000000000000000${(i + 1)->Int.toString}"`
    )->Array.join("")
  Scenario.make(
    ~configYaml=`
name: ${name}
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
    start_block: ${startBlock->Int.toString}${endBlockYaml}
    max_reorg_depth: 199
    contracts:
      - name: Token
        address:${addressesYaml}
`,
  )
}

let openEnded = makeScenario(~name="fetch-state-reorg-threshold")
let endBlockAboveHead = makeScenario(~name="fetch-state-reorg-threshold-far-end", ~endBlock=2000)
let endBlockBelowHead = makeScenario(~name="fetch-state-reorg-threshold-near-end", ~endBlock=100)
let startBlockPastHead = makeScenario(
  ~name="fetch-state-reorg-threshold-far-start",
  ~startBlock=6000,
)
let twoPartitions = makeScenario(~name="fetch-state-reorg-threshold-partitions", ~addresses=2)

let sources: array<Scenario.sourceMock> = [
  {chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
]

let inReorgThreshold = async (indexer: IndexerRunner.t) =>
  (await indexer.metric("envio_reorg_threshold"))->Array.map(sample => sample.value)

let respondUpTo = async (~indexer: IndexerRunner.t, ~mock: MockSource.t, ~fromBlock, ~to) => {
  await mock.expectItemsQueries([
    {fromBlock, reply: Respond({items: [], latestFetchedBlockNumber: to})},
  ])
  await indexer.getBatchWritePromise()
}

// Answers up to one block short of `readyAt`, then up to it, reading whether
// the indexer is in the threshold after each.
let thresholdShortOfAndAt = async (
  ~indexer,
  ~source: (int, ~index: int=?) => MockSource.t,
  ~readyAt,
) => {
  let mock = source(1)
  mock.resolveGetHeightOrThrow(1000)
  await respondUpTo(~indexer, ~mock, ~fromBlock=1, ~to=readyAt - 1)
  let shortOf = await inReorgThreshold(indexer)
  await respondUpTo(~indexer, ~mock, ~fromBlock=readyAt, ~to=readyAt)
  (shortOf, await inReorgThreshold(indexer))
}

describe("FetchState readiness for the reorg threshold", () => {
  startBlockPastHead->Scenario.it(
    "does not enter before the chain knows its head, even with a start block past the depth",
    ~sources,
    async (~t, ~indexer, ~source as _) => {
      await indexer.waitUntilIdle()
      t.expect(await inReorgThreshold(indexer)).toEqual(["0"])
    },
  )

  openEnded->Scenario.it(
    "enters once the frontier reaches the lagged head, not a block before",
    ~sources,
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      t.expect(await thresholdShortOfAndAt(~indexer, ~source, ~readyAt=800)).toEqual((["0"], ["1"]))
    },
  )

  endBlockAboveHead->Scenario.it(
    "waits for the lagged head, not an end block beyond it",
    ~sources,
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      t.expect(await thresholdShortOfAndAt(~indexer, ~source, ~readyAt=800)).toEqual((["0"], ["1"]))
    },
  )

  openEnded->Scenario.it(
    "enters within the tolerance below the lagged head, not a block beyond it",
    ~sources,
    ~reorgThresholdReadyTolerance=100,
    async (~t, ~indexer, ~source) => {
      t.expect(await thresholdShortOfAndAt(~indexer, ~source, ~readyAt=700)).toEqual((["0"], ["1"]))
    },
  )

  endBlockBelowHead->Scenario.it(
    "waits for an end block below the lagged head exactly, without the tolerance",
    ~sources,
    // Ready from block 50 if the tolerance applied to the end block.
    ~reorgThresholdReadyTolerance=750,
    // The indexer exits once the chain reaches its end block.
    ~onExit=() => (),
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(1000)
      await respondUpTo(~indexer, ~mock, ~fromBlock=1, ~to=59)
      let beforeEndBlock = await inReorgThreshold(indexer)
      await respondUpTo(~indexer, ~mock, ~fromBlock=60, ~to=100)
      t.expect((beforeEndBlock, await inReorgThreshold(indexer))).toEqual((["0"], ["1"]))
    },
  )

  openEnded->Scenario.it(
    "waits for the items fetched at or below the frontier to be processed",
    ~sources,
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      let holdFirstBatch = MockSource.Gate.make()
      mock.resolveGetHeightOrThrow(1000)
      await mock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [
              {blockNumber: 798, logIndex: 0, handler: _ => holdFirstBatch.wait()},
              {blockNumber: 799, logIndex: 0},
            ],
            latestFetchedBlockNumber: 800,
          }),
        },
      ])
      // Real time: handlers run off the clock.
      await Scenario.waitUntil(
        () => holdFirstBatch.entered.contents > 0,
        ~message="the batch taking the first item",
      )
      let withAnItemLeft = await inReorgThreshold(indexer)
      holdFirstBatch.release()
      await indexer.getBatchWritePromise()
      t.expect((withAnItemLeft, await inReorgThreshold(indexer))).toEqual((["0"], ["1"]))
    },
  )

  twoPartitions->Scenario.it(
    "does not wait for items above the frontier a lagging partition holds back",
    ~sources,
    ~maxAddrInPartition=1,
    ~reorgThresholdReadyTolerance=100,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(1000)
      await mock.expectItemsQueries([
        {
          address: "0x0000000000000000000000000000000000000001",
          reply: Respond({items: [{blockNumber: 750, logIndex: 0}], latestFetchedBlockNumber: 800}),
        },
        {
          address: "0x0000000000000000000000000000000000000002",
          reply: Respond({items: [], latestFetchedBlockNumber: 720}),
        },
      ])
      await indexer.getBatchWritePromise()
      t.expect(await inReorgThreshold(indexer)).toEqual(["1"])
    },
  )

  openEnded->Scenario.it(
    "enters at once when the head is within the depth of the start",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect((
        await inReorgThreshold(indexer),
        mock.pendingItemsQueries->Array.map(
          query => (query.toBlock, query->MockSource.reorgableFrom),
        ),
      )).toEqual((["1"], [(MockSource.Unbounded, Some(0))]))
    },
  )
})
