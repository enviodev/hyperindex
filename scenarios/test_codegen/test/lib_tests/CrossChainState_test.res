open Vitest

let baseChainConfig = Config.load().chainMap->ChainMap.values->Utils.Array.firstUnsafe

let mockEvent = (~blockNumber): Internal.item =>
  Internal.Event({
    chain: ChainMap.Chain.makeUnsafe(~chainId=1),
    blockNumber,
    onEventRegistration:
      "Mock onEventRegistration in CrossChainState test"->(
        Utils.magic: string => Internal.onEventRegistration
      ),
    logIndex: 0,
    transactionIndex: 0,
    payload: "Mock event in CrossChainState test"->(Utils.magic: string => Internal.eventPayload),
  })

// A chain state with no partitions, so bufferBlockNumber is latestOnBlockBlockNumber
// (the fetch frontier) and every derived value used by the scheduler is set directly.
let makeChainState = (
  ~chainId,
  ~knownHeight,
  ~frontier,
  ~firstEventBlock,
  ~bufferBlocks=[],
  ~isProgressAtHead=false,
  ~onEventRegistrations=[],
) => {
  let addresses = []
  let contractConfigs = IndexingAddresses.makeContractConfigs(~onEventRegistrations)
  let indexingAddresses = IndexingAddresses.make(~contractConfigs, ~addresses)
  let base = FetchState.make(
    // An onBlock config (no address partition) satisfies "something to fetch"
    // while keeping bufferBlockNumber tied to latestOnBlockBlockNumber.
    ~onEventRegistrations,
    ~contractConfigs,
    ~addresses,
    ~onBlockRegistrations=[
      {
        Internal.index: 0,
        name: "scheduler-test",
        chainId,
        startBlock: None,
        endBlock: None,
        interval: 1,
        handler: "mock onBlock handler"->(Utils.magic: string => Internal.onBlockArgs => promise<unit>),
      },
    ],
    ~startBlock=0,
    ~endBlock=None,
    ~maxAddrInPartition=3,
    ~maxOnBlockBufferSize=10000,
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
    ~onEventRegistrations,
    ~indexingAddresses,
    ~sourceManager=SourceManager.make(~sources=[mockSource.source], ~isRealtime=false),
    ~reorgDetection=ReorgDetection.make(
      ~chainReorgCheckpoints=[],
      ~maxReorgDepth=200,
      ~shouldRollbackOnReorg=false,
    ),
    ~committedProgressBlockNumber=-1,
    ~isProgressAtHead,
    ~logger=Logging.getLogger(),
  )
}

// A chain state with one fresh address partition behind the head, so
// getNextQuery actually produces a Ready query (unlike the onBlock-only helper
// above). The partition has no response yet, so each query estimates at the
// default size.
let makeFetchingChainState = (
  ~chainId,
  ~knownHeight,
  ~latestFetchedBlock,
  ~endBlock=None,
  ~chainDensity=None,
  ~caughtUpOnce=false,
  ~bufferBlocks=[],
) => {
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}
  let address = "0x1234567890123456789012345678901234567890"->Address.unsafeFromString
  let partition: FetchState.partition = {
    id: "0",
    latestFetchedBlock: {blockNumber: latestFetchedBlock, blockTimestamp: 0},
    selection: normalSelection,
    addressesByContractName: Dict.fromArray([("MockContract", [address])]),
    mergeBlock: None,
    dynamicContract: None,
    mutPendingQueries: [],
    prevQueryRange: 0,
    prevPrevQueryRange: 0,
    prevRangeSize: 0,
    latestBlockRangeUpdateBlock: 0,
  }
  let indexingAddresses =
    Dict.fromArray([
      (
        address->Address.toString,
        ({contractName: "MockContract", address, registrationBlock: -1, effectiveStartBlock: 0}: Internal.indexingContract),
      ),
    ])->(Utils.magic: dict<Internal.indexingContract> => IndexingAddresses.t)
  let fetchState: FetchState.t = {
    optimizedPartitions: FetchState.OptimizedPartitions.make(
      ~partitions=[partition],
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=1,
      ~dynamicContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock,
    buffer: bufferBlocks->Array.map(blockNumber => mockEvent(~blockNumber)),
    normalSelection,
    latestOnBlockBlockNumber: latestFetchedBlock,
    maxOnBlockBufferSize: 10000,
    chainId,
    contractConfigs: Dict.make(),
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight,
    firstEventBlock: Some(0),
  }
  let mockSource = MockIndexer.Source.make([], ~chain=#1)
  ChainState.make(
    ~chainConfig={...baseChainConfig, id: chainId},
    ~fetchState,
    ~indexingAddresses,
    ~sourceManager=SourceManager.make(~sources=[mockSource.source], ~isRealtime=false),
    ~reorgDetection=ReorgDetection.make(
      ~chainReorgCheckpoints=[],
      ~maxReorgDepth=200,
      ~shouldRollbackOnReorg=false,
    ),
    ~committedProgressBlockNumber=-1,
    ~chainDensity,
    ~timestampCaughtUpToHeadOrEndblock=caughtUpOnce ? Some(Date.make()) : None,
    ~logger=Logging.getLogger(),
  )
}

let emptyBatch: Batch.t = {
  totalBatchSize: 0,
  items: [],
  progressedChainsById: Dict.make(),
  isInReorgThreshold: false,
  checkpointIds: [],
  checkpointChainIds: [],
  checkpointBlockNumbers: [],
  checkpointBlockHashes: [],
  checkpointEventsProcessed: [],
}

let makeCrossChainState = (~chainStatesList, ~isRealtime=false, ~targetBufferSize=100) => {
  let chainStates = Dict.make()
  chainStatesList->Array.forEach(cs =>
    chainStates->Utils.Dict.setByInt((cs->ChainState.chainConfig).id, cs)
  )
  CrossChainState.make(~chainStates, ~isInReorgThreshold=false, ~isRealtime, ~targetBufferSize)
}

let makeRegistration = (~contractName, ~index): Internal.onEventRegistration =>
  ({
    ...MockIndexer.evmOnEventRegistration(~contractName),
    index,
  }: Internal.evmOnEventRegistration :> Internal.onEventRegistration)

describe("ChainState event registration ownership", () => {
  it("rejects a registration whose index differs from its ChainState position", t => {
    t.expect(() =>
      makeChainState(
        ~chainId=1,
        ~knownHeight=10,
        ~frontier=10,
        ~firstEventBlock=0,
        ~onEventRegistrations=[makeRegistration(~contractName="ContractA", ~index=4)],
      )->ignore
    ).toThrowError(
      "Invalid onEvent registration index for chain 1: ContractA.EventWithoutFields has index 4, but its ChainState position is 0.",
    )
  })
})

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

  Async.it("checkAndFetch dispatches every chain that has work, skipping idle ones", async t => {
    // Chains at head (onBlock-only, frontier == knownHeight) wait for a new
    // block, so they're dispatched with that action. A chain whose buffer is
    // already full of ready items (>= targetBufferSize) gets no budget, so it
    // isn't dispatched.
    let a = makeChainState(~chainId=1, ~knownHeight=1000, ~frontier=1000, ~firstEventBlock=0)
    let b = makeChainState(~chainId=2, ~knownHeight=1000, ~frontier=1000, ~firstEventBlock=0)

    let cm = makeCrossChainState(~chainStatesList=[a, b], ~isRealtime=true)

    let dispatched = []
    await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
      dispatched->Array.push((chain->ChainMap.Chain.toChainId, action))->ignore
      Promise.resolve()
    })

    t.expect(
      dispatched->Array.map(((chainId, action)) => (chainId, action === WaitingForNewBlock)),
    ).toEqual([(1, true), (2, true)])
  })

  Async.it("checkAndFetch doesn't dispatch when the buffer pool is full", async t => {
    // Both chains are backfilling with onBlock-only frontiers, so they have no
    // partitions to fetch; the pool being full leaves nothing to do.
    let a = makeChainState(
      ~chainId=1,
      ~knownHeight=1000,
      ~frontier=100,
      ~firstEventBlock=0,
      ~bufferBlocks=Array.make(~length=60, 100),
    )
    let b = makeChainState(
      ~chainId=2,
      ~knownHeight=1000,
      ~frontier=100,
      ~firstEventBlock=0,
      ~bufferBlocks=Array.make(~length=60, 100),
    )
    let cm = makeCrossChainState(~chainStatesList=[a, b], ~targetBufferSize=100)

    let dispatched = []
    await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action as _) => {
      dispatched->Array.push(chain->ChainMap.Chain.toChainId)->ignore
      Promise.resolve()
    })

    t.expect(dispatched).toEqual([])
  })

  Async.it("checkAndFetch still dispatches when the only query exceeds the budget", async t => {
    // Fresh partition behind the head: its query estimates at the default
    // (10000), far above the tiny remaining budget (1). Admission must still let
    // one query through, otherwise the chain would never make progress.
    let cs = makeFetchingChainState(~chainId=1, ~knownHeight=1000, ~latestFetchedBlock=0)
    let cm = makeCrossChainState(~chainStatesList=[cs], ~targetBufferSize=1)

    let dispatched = []
    await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
      dispatched
      ->Array.push((
        chain->ChainMap.Chain.toChainId,
        switch action {
        | Ready(queries) => queries->Array.length
        | _ => 0
        },
      ))
      ->ignore
      Promise.resolve()
    })

    t.expect(dispatched).toEqual([(1, 1)])
  })

  // Chain 1 (furthest behind, so priorityOrder visits it first): a single
  // known-density partition with a short remaining range (endBlock=20 at
  // density 10 items/block -> 200 items across 2 chunks, reserved at the
  // chunk headroom multiplier: 1.5x backfill, 3x realtime). Its real
  // consumption is capped by that range, far below whatever share of the
  // 3000-item pool the waterfall would otherwise hand it. Returns each
  // chain's dispatched itemsTarget total and pendingBudget.
  let runShortRangeWaterfall = async (~isRealtime) => {
      let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}
      let address1 = "0x1111111111111111111111111111111111111111"->Address.unsafeFromString
      let partition1: FetchState.partition = {
        id: "0",
        latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
        selection: normalSelection,
        addressesByContractName: Dict.fromArray([("MockContract", [address1])]),
        mergeBlock: None,
        dynamicContract: None,
        mutPendingQueries: [],
        prevQueryRange: 10,
        prevPrevQueryRange: 10,
        prevRangeSize: 100, // density = 100 / 10 = 10 items/block
        latestBlockRangeUpdateBlock: 0,
      }
      let indexingAddresses1 =
        Dict.fromArray([
          (
            address1->Address.toString,
            ({
              contractName: "MockContract",
              address: address1,
              registrationBlock: -1,
              effectiveStartBlock: 0,
            }: Internal.indexingContract),
          ),
        ])->(Utils.magic: dict<Internal.indexingContract> => IndexingAddresses.t)
      let fetchState1: FetchState.t = {
        optimizedPartitions: FetchState.OptimizedPartitions.make(
          ~partitions=[partition1],
          ~maxAddrInPartition=2,
          ~nextPartitionIndex=1,
          ~dynamicContracts=Utils.Set.make(),
        ),
        startBlock: 0,
        endBlock: Some(20),
        buffer: [],
        normalSelection,
        latestOnBlockBlockNumber: 0,
        maxOnBlockBufferSize: 10000,
        chainId: 1,
        contractConfigs: Dict.make(),
        blockLag: 0,
        onBlockRegistrations: [],
        knownHeight: 1000,
        firstEventBlock: Some(0),
      }
      let mockSource1 = MockIndexer.Source.make([], ~chain=#1)
      let a = ChainState.make(
        ~chainConfig={...baseChainConfig, id: 1},
        ~fetchState=fetchState1,
        ~indexingAddresses=indexingAddresses1,
        ~sourceManager=SourceManager.make(~sources=[mockSource1.source], ~isRealtime=false),
        ~reorgDetection=ReorgDetection.make(
          ~chainReorgCheckpoints=[],
          ~maxReorgDepth=200,
          ~shouldRollbackOnReorg=false,
        ),
        ~committedProgressBlockNumber=-1,
        ~logger=Logging.getLogger(),
      )

      // Chain 2 (less behind, visited second): a fresh unknown-density
      // partition — sizes exactly to whatever budget it's given, so it
      // directly reflects what chain 1 left behind.
      let b = makeFetchingChainState(~chainId=2, ~knownHeight=1000, ~latestFetchedBlock=500)

      let cm = makeCrossChainState(~chainStatesList=[a, b], ~isRealtime, ~targetBufferSize=3000)

      let dispatchedItemsByChain = Dict.make()
      await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
        dispatchedItemsByChain->Utils.Dict.setByInt(
          chain->ChainMap.Chain.toChainId,
          switch action {
          | Ready(queries) =>
            queries->Array.reduce(0., (acc, q: FetchState.query) => acc +. q.itemsTarget->Int.toFloat)
          | _ => 0.
          },
        )
        Promise.resolve()
      })

      (
        dispatchedItemsByChain->Utils.Dict.dangerouslyGetByIntNonOption(1),
        dispatchedItemsByChain->Utils.Dict.dangerouslyGetByIntNonOption(2),
        a->ChainState.pendingBudget,
        b->ChainState.pendingBudget,
      )
  }

  Async.it(
    "checkAndFetch's waterfall lets the furthest-behind chain drain only what it can use, flowing the remainder to the next chain",
    async t => {
      t.expect(
        await runShortRangeWaterfall(~isRealtime=false),
        ~message="Chain 1's real range caps it at 200 items regardless of its share of the 3000-item pool (itemsTarget carries the 1.5x headroom = 300, but only the 200 estimate is reserved); chain 2 gets the rest",
      ).toEqual((Some(300.), Some(2800.), 200., 2800.))
    },
  )

  Async.it("checkAndFetch sizes realtime chunk caps with 3x headroom but reserves the estimate", async t => {
    t.expect(
      await runShortRangeWaterfall(~isRealtime=true),
      ~message="Chain 1's itemsTarget carries the 3x realtime headroom = 600, but pendingBudget still reserves the honest 200-item estimate; chain 2 gets the rest",
    ).toEqual((Some(600.), Some(2800.), 200., 2800.))
  })

  Async.it(
    "checkAndFetch skips a chain with no known height without claiming leadership or budget",
    async t => {
      // Chain 1 has no height yet (its source hasn't reported): it must wait
      // for a new block instead of setting the alignment line from a
      // degenerate progress range and letting every other chain run
      // unconstrained on a stale line.
      let a = makeFetchingChainState(~chainId=1, ~knownHeight=0, ~latestFetchedBlock=0)
      let b = makeFetchingChainState(~chainId=2, ~knownHeight=1000, ~latestFetchedBlock=500)
      let cm = makeCrossChainState(~chainStatesList=[a, b], ~targetBufferSize=3000)

      let actionsByChain = Dict.make()
      await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
        actionsByChain->Utils.Dict.setByInt(
          chain->ChainMap.Chain.toChainId,
          switch action {
          | WaitingForNewBlock => "waitingForNewBlock"
          | NothingToQuery => "nothingToQuery"
          | Ready(queries) =>
            "ready:" ++
            queries
            ->Array.reduce(0., (acc, q: FetchState.query) => acc +. q.itemsTarget->Int.toFloat)
            ->Float.toString
          },
        )
        Promise.resolve()
      })

      t.expect(
        actionsByChain,
        ~message="Chain 1 waits for its first block; chain 2 becomes the leader and gets the full pool",
      ).toEqual(Dict.fromArray([("1", "waitingForNewBlock"), ("2", "ready:3000")]))
    },
  )

  Async.it(
    "checkAndFetch aligns progress against the currently reachable end block",
    async t => {
      let leader = makeFetchingChainState(
        ~chainId=1,
        ~knownHeight=1000,
        ~latestFetchedBlock=0,
        ~endBlock=Some(1_000_000_000),
        ~chainDensity=Some(1.),
      )
      let follower = makeFetchingChainState(
        ~chainId=2,
        ~knownHeight=1000,
        ~latestFetchedBlock=0,
        ~chainDensity=Some(1.),
      )
      let cm = makeCrossChainState(
        ~chainStatesList=[leader, follower],
        ~targetBufferSize=3000,
      )

      let estimatesByChain = Dict.make()
      await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
        estimatesByChain->Utils.Dict.setByInt(
          chain->ChainMap.Chain.toChainId,
          switch action {
          | Ready(queries) =>
            queries->Array.reduce(0, (total, query: FetchState.query) => total + query.itemsEst)
          | _ => 0
          },
        )
        Promise.resolve()
      })

      t.expect(
        estimatesByChain,
        ~message="A future endBlock must not clamp the follower near its starting frontier",
      ).toEqual(Dict.fromArray([("1", 1000), ("2", 1000)]))
    },
  )

  it("getNextQuery caps the budget at the plain range cost regardless of caught-up status", t => {
    let makeChain = (~caughtUpOnce) =>
      makeFetchingChainState(
        ~chainId=1,
        ~knownHeight=1000,
        ~latestFetchedBlock=0,
        ~endBlock=Some(20),
        ~chainDensity=Some(10.),
        ~caughtUpOnce,
      )
    let itemsTarget = cs =>
      switch cs->ChainState.getNextQuery(~chainTargetItems=3000.) {
      | Ready([q]) => q.itemsTarget
      | _ => JsError.throwWithMessage("expected a single ready query")
      }

    // Range cost to the 20-block endBlock ceiling at density 10 = 200 items.
    // No extra headroom on the budget cap: truncation safety lives in the
    // itemsTarget server cap via chunkItemsMultiplier, not in the reservation.
    t.expect(
      (makeChain(~caughtUpOnce=false)->itemsTarget, makeChain(~caughtUpOnce=true)->itemsTarget),
      ~message="Both are capped at the plain range cost",
    ).toEqual((200, 200))
  })
})

describe("CrossChainState readiness", () => {
  it("does not mark a chain ready while another is still backfilling", t => {
    // Chain 1 reached head with an empty buffer; chain 2 is mid-backfill with
    // ready events left to process.
    let atHead = makeChainState(
      ~chainId=1,
      ~knownHeight=1000,
      ~frontier=1000,
      ~firstEventBlock=0,
      ~isProgressAtHead=true,
    )
    let backfilling = makeChainState(
      ~chainId=2,
      ~knownHeight=1000,
      ~frontier=300,
      ~firstEventBlock=0,
      ~bufferBlocks=[300],
    )
    let cm = makeCrossChainState(~chainStatesList=[atHead, backfilling])

    cm->CrossChainState.applyBatchProgress(~batch=emptyBatch, ~blockTimestampName="timestamp")

    t.expect({
      "atHeadReady": atHead->ChainState.isReady,
      "backfillingReady": backfilling->ChainState.isReady,
      "isRealtime": cm->CrossChainState.isRealtime,
    }).toEqual({"atHeadReady": false, "backfillingReady": false, "isRealtime": false})
  })

  it("marks every chain ready together once the whole indexer is caught up", t => {
    let a = makeChainState(
      ~chainId=1,
      ~knownHeight=1000,
      ~frontier=1000,
      ~firstEventBlock=0,
      ~isProgressAtHead=true,
    )
    let b = makeChainState(
      ~chainId=2,
      ~knownHeight=1000,
      ~frontier=1000,
      ~firstEventBlock=0,
      ~isProgressAtHead=true,
    )
    let cm = makeCrossChainState(~chainStatesList=[a, b])

    cm->CrossChainState.applyBatchProgress(~batch=emptyBatch, ~blockTimestampName="timestamp")

    t.expect({
      "aReady": a->ChainState.isReady,
      "bReady": b->ChainState.isReady,
      "isRealtime": cm->CrossChainState.isRealtime,
    }).toEqual({"aReady": true, "bReady": true, "isRealtime": true})
  })
})

describe("ChainState cold start", () => {
  it("targets frontier + 20k with no density signal", t => {
    let cs = makeFetchingChainState(~chainId=1, ~knownHeight=1_000_000, ~latestFetchedBlock=5_000)
    t.expect(cs->ChainState.targetBlock(~chainTargetItems=1000.)).toBe(25_000)
  })

  it("caps the cold target at an endBlock inside the horizon", t => {
    let cs = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=1_000_000,
      ~latestFetchedBlock=0,
      ~endBlock=Some(5_000),
    )
    t.expect(cs->ChainState.targetBlock(~chainTargetItems=1000.)).toBe(5_000)
  })

  Async.it("cold leader doesn't set the alignment line", async t => {
    // Chain 1 is cold and most behind: its 20k guess-window on a 1M-block
    // chain maps to ~2% progress, which would cap chain 2 near block 20 if a
    // cold chain could claim leadership. Instead chain 2 (density-bearing)
    // sets the line and drains the rest of the pool.
    let a = makeFetchingChainState(~chainId=1, ~knownHeight=1_000_000, ~latestFetchedBlock=0)
    let b = makeFetchingChainState(
      ~chainId=2,
      ~knownHeight=1000,
      ~latestFetchedBlock=500,
      ~chainDensity=Some(10.),
    )
    let cm = makeCrossChainState(~chainStatesList=[a, b], ~targetBufferSize=10_000)

    let dispatchedItemsByChain = Dict.make()
    await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
      dispatchedItemsByChain->Utils.Dict.setByInt(
        chain->ChainMap.Chain.toChainId,
        switch action {
        | Ready(queries) =>
          queries->Array.reduce(0., (acc, q: FetchState.query) => acc +. q.itemsTarget->Int.toFloat)
        | _ => 0.
        },
      )
      Promise.resolve()
    })

    t.expect(
      dispatchedItemsByChain,
      ~message="Cold chain 1 gets its bounded probe; chain 2 is unconstrained by chain 1's guess",
    ).toEqual(Dict.fromArray([("1", 5000.), ("2", 5000.)]))
  })

  Async.it("clamps a cold chain to min(5k, targetBufferSize)", async t => {
    let probeSize = async (~targetBufferSize) => {
      let cs = makeFetchingChainState(~chainId=1, ~knownHeight=1_000_000, ~latestFetchedBlock=0)
      let cm = makeCrossChainState(~chainStatesList=[cs], ~targetBufferSize)
      let dispatched = ref(0.)
      await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain as _, ~action) => {
        switch action {
        | Ready(queries) =>
          dispatched :=
            queries->Array.reduce(0., (acc, q: FetchState.query) =>
              acc +. q.itemsTarget->Int.toFloat
            )
        | _ => ()
        }
        Promise.resolve()
      })
      dispatched.contents
    }
    t.expect(
      (await probeSize(~targetBufferSize=10_000), await probeSize(~targetBufferSize=2_000)),
      ~message="The cold probe never exceeds 5k, nor the whole pool when it's smaller",
    ).toEqual((5000., 2000.))
  })
})

describe("ChainState density from the ready buffer", () => {
  it("a dense ready buffer overrides a stale-low processing EMA", t => {
    // 100 ready items over the 101-block span (-1 committed progress ->
    // frontier 100) prove ~1 item/block even though the EMA says 0.001.
    let cs = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=1_000_000,
      ~latestFetchedBlock=100,
      ~chainDensity=Some(0.001),
      ~bufferBlocks=Array.make(~length=100, 50),
    )
    t.expect(cs->ChainState.effectiveDensity).toEqual(Some(100. /. 101.))
  })

  it("falls back to the processing EMA when the buffer is empty", t => {
    let cs = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=1_000_000,
      ~latestFetchedBlock=100,
      ~chainDensity=Some(0.5),
    )
    t.expect(cs->ChainState.effectiveDensity).toEqual(Some(0.5))
  })

  it("mid-batch, the span starts at the processing block, not the committed one", t => {
    // A batch was created up to block 100, consuming the buffer's head; its
    // progress commits only after processing. The remaining 2 ready items span
    // the 100 blocks since the batch's progress — not the 201 since the still
    // uncommitted progress (-1).
    let cs = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=1_000_000,
      ~latestFetchedBlock=200,
      ~bufferBlocks=[150, 160],
    )
    let progressedChainsById = Dict.make()
    progressedChainsById->Utils.Dict.setByInt(
      1,
      (
        {
          batchSize: 5,
          progressBlockNumber: 100,
          sourceBlockNumber: 1_000_000,
          totalEventsProcessed: 5.,
          fetchState: (cs->ChainState.toChainBeforeBatch).fetchState,
          isProgressAtHeadWhenBatchCreated: false,
        }: Batch.chainAfterBatch
      ),
    )
    cs->ChainState.advanceAfterBatch(
      ~batch={...emptyBatch, progressedChainsById},
      ~enteringReorgThreshold=false,
    )
    t.expect(cs->ChainState.effectiveDensity).toEqual(Some(2. /. 100.))
  })

  it("ready items alone take the chain out of cold mode before the first batch commits", t => {
    let cs = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=1_000_000,
      ~latestFetchedBlock=100,
      ~bufferBlocks=[50],
    )
    t.expect(cs->ChainState.effectiveDensity).toEqual(Some(1. /. 101.))
  })
})
