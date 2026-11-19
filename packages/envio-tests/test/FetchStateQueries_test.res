open Vitest

let staticAddress = "0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3"

let configYaml = (~extra="") =>
  `
name: fetch-state-queries
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 0${extra}
    contracts:
      - name: Gravatar
        address: "${staticAddress}"
        events:
          - event: "TestEvent()"
`
let schema = `
type Seen {
  id: ID!
}
`

type queryShape = {
  partitionId: string,
  fromBlock: int,
  toBlock: MockSource.toBlock,
  addresses: array<string>,
}

let shapeOf = (query: MockSource.pendingItemsQuery) => {
  partitionId: query.partitionId,
  fromBlock: query.fromBlock,
  toBlock: query.toBlock,
  addresses: query->MockSource.addresses->Array.map(Address.toString),
}

let pendingShapes = (source: MockSource.t) => source.pendingItemsQueries->Array.map(shapeOf)

let scenario = Scenario.make(~configYaml=configYaml(), ~schema)

describe("FetchState queries over the indexer loop", () => {
  scenario->Scenario.it(
    "Waits for a height, queries once per partition, then waits for a new block at the head",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      await sync.expectNewHeightCalls(1)
      await indexer.advanceTime(10)
      let beforeHeight = sync->pendingShapes

      sync.resolveGetHeightOrThrow(10)
      await sync.expectItemsQueries([{reply: LeavePending}])
      await indexer.advanceTime(100)
      await sync.expectNewHeightCalls(0)
      let firstQuery = sync->pendingShapes

      await sync.expectItemsQueries([
        {
          partitionId: "0",
          reply: Respond({
            items: [{blockNumber: 2, logIndex: 0}, {blockNumber: 1, logIndex: 0}],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      await sync.expectNewHeightCalls(1)
      let atHead = sync->pendingShapes

      sync.resolveGetHeightOrThrow(11)
      await sync.expectItemsQueries([{reply: LeavePending}])
      t.expect((beforeHeight, firstQuery, atHead, sync->pendingShapes)).toEqual((
        [],
        [
          {
            partitionId: "0",
            fromBlock: 0,
            toBlock: Unbounded,
            addresses: [staticAddress],
          },
        ],
        [],
        [
          {
            partitionId: "0",
            fromBlock: 11,
            toBlock: Unbounded,
            addresses: [staticAddress],
          },
        ],
      ))
    },
  )

  let endBlockScenario = endBlock =>
    Scenario.make(
      ~configYaml=configYaml(~extra=`\n    end_block: ${endBlock->Int.toString}`),
      ~schema,
    )
  let endBlock10 = endBlockScenario(10)
  let endBlock11 = endBlockScenario(11)
  let endBlock9 = endBlockScenario(9)

  let exited = ref(false)
  endBlock10->Scenario.it(
    "Exits without polling for new blocks once the end block is fetched",
    ~sources=[{chain: 1337}],
    ~onExit=() => exited := true,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      await sync.expectNewHeightCalls(1)
      sync.resolveGetHeightOrThrow(10)
      await sync.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 0,
          toBlock: Bounded(10),
          reply: Respond({items: [{blockNumber: 1, logIndex: 0}]}),
        },
      ])
      await indexer.getBatchWritePromise()
      await indexer.advanceTime(100_000)
      await sync.expectNewHeightCalls(0)
      t.expect((exited.contents, sync->pendingShapes)).toEqual((true, []))
    },
  )

  endBlock11->Scenario.it(
    "Waits for a new block while the end block is above the head",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      await sync.expectNewHeightCalls(1)
      sync.resolveGetHeightOrThrow(10)
      await sync.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 0,
          toBlock: Bounded(11),
          reply: Respond({items: [{blockNumber: 1, logIndex: 0}], latestFetchedBlockNumber: 10}),
        },
      ])
      await indexer.getBatchWritePromise()
      await sync.expectNewHeightCalls(1)
      sync.resolveGetHeightOrThrow(20)
      await sync.expectItemsQueries([{reply: LeavePending}])
      t.expect(sync->pendingShapes).toEqual([
        {
          partitionId: "0",
          fromBlock: 11,
          toBlock: Bounded(11),
          addresses: [staticAddress],
        },
      ])
    },
  )

  endBlock9->Scenario.it(
    "Bounds the query at an end block below the head",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10)
      await sync.expectItemsQueries([{reply: LeavePending}])
      t.expect(sync->pendingShapes).toEqual([
        {
          partitionId: "0",
          fromBlock: 0,
          toBlock: Bounded(9),
          addresses: [staticAddress],
        },
      ])
    },
  )

  let blockLagScenario = endBlock =>
    Scenario.make(
      ~configYaml=configYaml(~extra=`\n    block_lag: 2\n    end_block: ${endBlock->Int.toString}`),
      ~schema,
    )
  let lagWithEndBlock10 = blockLagScenario(10)
  let lagWithEndBlock8 = blockLagScenario(8)

  lagWithEndBlock10->Scenario.it(
    "Holds the query back by the block lag, even with the end block at the head",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      await sync.expectNewHeightCalls(1)
      sync.resolveGetHeightOrThrow(1)
      await indexer.advanceTime(1000)
      await sync.expectNewHeightCalls(1)
      let belowLag = sync->pendingShapes

      sync.resolveGetHeightOrThrow(10)
      await sync.expectItemsQueries([{reply: LeavePending}])
      let lagged = sync->pendingShapes
      await sync.expectItemsQueries([
        {reply: Respond({items: [{blockNumber: 1, logIndex: 0}, {blockNumber: 2, logIndex: 0}]})},
      ])
      await indexer.getBatchWritePromise()
      await sync.expectNewHeightCalls(1)
      t.expect((belowLag, lagged, sync->pendingShapes)).toEqual((
        [],
        [
          {
            partitionId: "0",
            fromBlock: 0,
            toBlock: Bounded(8),
            addresses: [staticAddress],
          },
        ],
        [],
      ))
    },
  )

  lagWithEndBlock8->Scenario.it(
    "Fetches up to an end block that sits within the block lag of the head",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10)
      await sync.expectItemsQueries([{reply: LeavePending}])
      t.expect(sync->pendingShapes).toEqual([
        {
          partitionId: "0",
          fromBlock: 0,
          toBlock: Bounded(8),
          addresses: [staticAddress],
        },
      ])
    },
  )

  let secondAddress = "0x1111111111111111111111111111111111111111"
  let twoPartitions = (~endBlock) =>
    Scenario.make(
      ~configYaml=`
name: fetch-state-queries-ceiling
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 0${endBlock}
    contracts:
      - name: Gravatar
        address:
          - "${staticAddress}"
          - "${secondAddress}"
        events:
          - event: "TestEvent()"
`,
      ~schema,
    )

  // Partition "0" holds the second address, so its 15 buffered items stay
  // unprocessable until partition "1" catches up to them.
  let proposesPastFullBuffer = async (~source: int => MockSource.t, ~toBlock) => {
    let sync = source(1337)
    sync.resolveGetHeightOrThrow(30)
    await sync.expectItemsQueries([
      {
        partitionId: "0",
        fromBlock: 0,
        toBlock,
        reply: Respond({
          items: Array.fromInitializer(~length=15, i => {
            MockSource.blockNumber: 20 - i,
            logIndex: 0,
          }),
          latestFetchedBlockNumber: 20,
        }),
      },
    ])
    await sync.expectItemsQueries([{partitionId: "1", reply: LeavePending}])
    sync->pendingShapes
  }

  twoPartitions(
    ~endBlock="\n    end_block: 25",
  )->Scenario.it(
    "Proposes a query up to the end block while the buffer is past its target",
    ~sources=[{chain: 1337}],
    ~targetBufferSize=10,
    ~maxAddrInPartition=1,
    async (~t, ~indexer as _, ~source) => {
      t.expect(
        await proposesPastFullBuffer(~source=chain => source(chain), ~toBlock=Bounded(25)),
      ).toEqual([
        {
          partitionId: "1",
          fromBlock: 0,
          toBlock: Bounded(25),
          addresses: [staticAddress],
        },
      ])
    },
  )

  twoPartitions(
    ~endBlock="",
  )->Scenario.it(
    "Proposes an open-ended query while the buffer is past its target",
    ~sources=[{chain: 1337}],
    ~targetBufferSize=10,
    ~maxAddrInPartition=1,
    async (~t, ~indexer as _, ~source) => {
      t.expect(
        await proposesPastFullBuffer(~source=chain => source(chain), ~toBlock=Unbounded),
      ).toEqual([
        {
          partitionId: "1",
          fromBlock: 0,
          toBlock: Unbounded,
          addresses: [staticAddress],
        },
      ])
    },
  )
})
