open Vitest

let baseChainConfig = Config.loadWithoutRegistrations().chainMap->ChainMap.values->Utils.Array.firstUnsafe

let mockEvent = (~blockNumber): Internal.item =>
  Internal.Event({
    timestamp: blockNumber * 15,
    chain: ChainMap.Chain.makeUnsafe(~chainId=1),
    blockNumber,
    blockHash: `0x${blockNumber->Int.toString}`,
    eventConfig: Utils.magic("Mock eventConfig in CrossChainState test"),
    logIndex: 0,
    event: Utils.magic("Mock event in CrossChainState test"),
  })

// A chain state with no partitions, so bufferBlockNumber is latestOnBlockBlockNumber
// (the fetch frontier) and every derived value used by the scheduler is set directly.
let makeChainState = (~chainId, ~knownHeight, ~frontier, ~firstEventBlock, ~bufferBlocks=[]) => {
  let base = FetchState.make(
    // An onBlock config (no address partition) satisfies "something to fetch"
    // while keeping bufferBlockNumber tied to latestOnBlockBlockNumber.
    ~eventConfigs=[],
    ~addresses=[],
    ~onBlockConfigs=[
      {
        Internal.index: 0,
        name: "scheduler-test",
        chainId,
        startBlock: None,
        endBlock: None,
        interval: 1,
        handler: Utils.magic("mock onBlock handler"),
      },
    ],
    ~startBlock=0,
    ~endBlock=None,
    ~maxAddrInPartition=3,
    ~targetBufferSize=10000,
    ~chainId,
    ~knownHeight=0,
  )
  let fetchState = {
    ...base,
    knownHeight,
    latestOnBlockBlockNumber: frontier,
    firstEventBlock: Some(firstEventBlock),
    buffer: bufferBlocks->Array.map(blockNumber => mockEvent(~blockNumber)),
  }
  let mockSource = MockIndexer.Source.make([], ~chain=#1)
  ChainState.make(
    ~chainConfig={...baseChainConfig, id: chainId},
    ~fetchState,
    ~sourceManager=SourceManager.make(~sources=[mockSource.source], ~isRealtime=false),
    ~reorgDetection=ReorgDetection.make(
      ~chainReorgCheckpoints=[],
      ~maxReorgDepth=200,
      ~shouldRollbackOnReorg=false,
    ),
    ~committedProgressBlockNumber=-1,
    ~logger=Logging.getLogger(),
  )
}

let makeCrossChainState = (
  ~chainStatesList,
  ~isRealtime=false,
  ~maxBackfillConcurrency=30,
  ~maxRealtimeConcurrency=200,
  ~targetBufferSize=100,
) => {
  let chainStates = Dict.make()
  chainStatesList->Array.forEach(cs =>
    chainStates->Utils.Dict.setByInt((cs->ChainState.chainConfig).id, cs)
  )
  CrossChainState.make(
    ~chainStates,
    ~isInReorgThreshold=false,
    ~isRealtime,
    ~maxBackfillConcurrency,
    ~maxRealtimeConcurrency,
    ~targetBufferSize,
  )
}

describe("CrossChainState fetch control", () => {
  it("priorityOrder visits the furthest-behind chain first", t => {
    let a = makeChainState(~chainId=1, ~knownHeight=1000, ~frontier=100, ~firstEventBlock=0, ~bufferBlocks=[100])
    let b = makeChainState(~chainId=2, ~knownHeight=1000, ~frontier=500, ~firstEventBlock=0, ~bufferBlocks=[500])
    let cHead = makeChainState(~chainId=3, ~knownHeight=1000, ~frontier=1000, ~firstEventBlock=0, ~bufferBlocks=[950])

    let cm = makeCrossChainState(~chainStatesList=[cHead, a, b])

    t.expect(
      cm->CrossChainState.priorityOrder->Array.map(cs => (cs->ChainState.chainConfig).id),
    ).toEqual([1, 2, 3])
  })

  it("shouldPauseFetch only pauses an at-head chain while another is backfilling", t => {
    let atHead = makeChainState(~chainId=1, ~knownHeight=1000, ~frontier=1000, ~firstEventBlock=0)
    let behind = makeChainState(~chainId=2, ~knownHeight=1000, ~frontier=100, ~firstEventBlock=0)

    t.expect({
      "atHeadBackfillContention": atHead->CrossChainState.shouldPauseFetch(
        ~isRealtime=false,
        ~anyChainBackfilling=true,
      ),
      "atHeadNothingBackfilling": atHead->CrossChainState.shouldPauseFetch(
        ~isRealtime=false,
        ~anyChainBackfilling=false,
      ),
      "atHeadRealtime": atHead->CrossChainState.shouldPauseFetch(
        ~isRealtime=true,
        ~anyChainBackfilling=true,
      ),
      "behindBackfillContention": behind->CrossChainState.shouldPauseFetch(
        ~isRealtime=false,
        ~anyChainBackfilling=true,
      ),
    }).toEqual({
      "atHeadBackfillContention": true,
      "atHeadNothingBackfilling": false,
      "atHeadRealtime": false,
      "behindBackfillContention": false,
    })
  })

  Async.it(
    "checkAndFetch skips the paused chain and shares the buffer pool by priority",
    async t => {
      let a = makeChainState(
        ~chainId=1,
        ~knownHeight=1000,
        ~frontier=100,
        ~firstEventBlock=0,
        ~bufferBlocks=Array.make(~length=10, 100),
      )
      let b = makeChainState(
        ~chainId=2,
        ~knownHeight=1000,
        ~frontier=500,
        ~firstEventBlock=0,
        ~bufferBlocks=Array.make(~length=20, 500),
      )
      let cHead = makeChainState(
        ~chainId=3,
        ~knownHeight=1000,
        ~frontier=1000,
        ~firstEventBlock=0,
        ~bufferBlocks=Array.make(~length=5, 950),
      )

      let cm = makeCrossChainState(
        ~chainStatesList=[cHead, a, b],
        ~maxBackfillConcurrency=30,
        ~targetBufferSize=100,
      )

      let calls = []
      await cm->CrossChainState.checkAndFetch(~fetchChain=(~chain, ~concurrencyLimit, ~bufferLimit) => {
        calls
        ->Array.push({
          "chainId": chain->ChainMap.Chain.toChainId,
          "concurrencyLimit": concurrencyLimit,
          "bufferLimit": bufferLimit,
        })
        ->ignore
        Promise.resolve()
      })

      // Total buffered = 10 + 20 + 5 = 35. Chain 3 is at head while 1 and 2
      // backfill, so it is paused. The rest run furthest-behind first, each
      // allowed to grow into the pool the others leave free (100 - (35 - own)).
      t.expect(calls).toEqual([
        {"chainId": 1, "concurrencyLimit": 30, "bufferLimit": 75},
        {"chainId": 2, "concurrencyLimit": 30, "bufferLimit": 85},
      ])
    },
  )

  Async.it("checkAndFetch follows the head on every chain once realtime", async t => {
    let a = makeChainState(~chainId=1, ~knownHeight=1000, ~frontier=1000, ~firstEventBlock=0, ~bufferBlocks=[1000])
    let b = makeChainState(~chainId=2, ~knownHeight=1000, ~frontier=1000, ~firstEventBlock=0, ~bufferBlocks=[1000])

    let cm = makeCrossChainState(~chainStatesList=[a, b], ~isRealtime=true)

    let dispatchedChainIds = []
    await cm->CrossChainState.checkAndFetch(~fetchChain=(~chain, ~concurrencyLimit as _, ~bufferLimit as _) => {
      dispatchedChainIds->Array.push(chain->ChainMap.Chain.toChainId)->ignore
      Promise.resolve()
    })

    t.expect(dispatchedChainIds->Array.toSorted(Int.compare)).toEqual([1, 2])
  })
})

describe("CrossChainState shared concurrency (end to end)", () => {
  Async.it("Two backfilling chains share one concurrency slot", async t => {
    let sourceMockA = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~chain=#1337)
    let sourceMockB = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~chain=#100)

    let _indexerMock = await MockIndexer.Indexer.make(
      ~chains=[
        {MockIndexer.Indexer.chain: #1337, sourceConfig: Config.CustomSources([sourceMockA.source])},
        {MockIndexer.Indexer.chain: #100, sourceConfig: Config.CustomSources([sourceMockB.source])},
      ],
      ~maxBackfillConcurrency=1,
      ~shouldRollbackOnReorg=false,
    )
    await Utils.delay(0)

    // Both chains wait for a head first (waiting doesn't consume a slot).
    sourceMockA.resolveGetHeightOrThrow(1000)
    sourceMockB.resolveGetHeightOrThrow(1000)
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)

    // With a single shared slot, only one of the two backfilling chains may have
    // a query in flight at a time.
    t.expect(
      sourceMockA.getItemsOrThrowCalls->Array.length + sourceMockB.getItemsOrThrowCalls->Array.length,
      ~message="The indexer-wide concurrency budget of 1 must be shared across chains",
    ).toEqual(1)
  })
})
