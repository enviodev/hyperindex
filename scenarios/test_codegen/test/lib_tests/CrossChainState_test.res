open Vitest

let baseChainConfig = Config.load().chainMap->ChainMap.values->Utils.Array.firstUnsafe

let mockEvent = (~blockNumber): Internal.item =>
  Internal.Event({
    chain: ChainMap.Chain.makeUnsafe(~chainId=1),
    blockNumber,
    // Carries an `index` so the buffer's dedup key resolves; the rest of the
    // registration is unused by these tests.
    onEventRegistration: {"index": 0}->(
      Utils.magic: {"index": int} => Internal.onEventRegistration
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
    ~logger=Env.logger,
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
  ~firstEventBlock=Some(0),
  ~blockLag=0,
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
    sourceRangeCapacity: 0,
    prevSourceRangeCapacity: 0,
    eventDensity: None,
    latestSourceRangeCapacityUpdateBlock: 0,
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
    blockLag,
    onBlockRegistrations: [],
    knownHeight,
    firstEventBlock,
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
    ~logger=Env.logger,
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

  it("priorityOrder ranks by frontier progress, not event-based progress", t => {
    // Chain 1 has found no events yet (firstEventBlock=None), so
    // getProgressPercentage reports it at 0% even though its fetch frontier
    // (900) is far ahead of chain 2's (300). Ordering by frontier progress must
    // put the genuinely-behind chain 2 first, so it draws budget and anchors
    // the line before the ahead-but-eventless chain 1.
    let ahead = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=1000,
      ~latestFetchedBlock=900,
      ~firstEventBlock=None,
    )
    let behind = makeFetchingChainState(~chainId=2, ~knownHeight=1000, ~latestFetchedBlock=300)
    let cm = makeCrossChainState(~chainStatesList=[ahead, behind])

    t.expect(
      cm->CrossChainState.priorityOrder->Array.map(cs => (cs->ChainState.chainConfig).id),
    ).toEqual([2, 1])
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

  let queryWithFreeBudget = async (~freeBudget) => {
    let targetBufferSize = 100
    let buffered = makeChainState(
      ~chainId=1,
      ~knownHeight=1000,
      ~frontier=900,
      ~firstEventBlock=0,
      ~bufferBlocks=Array.make(~length=targetBufferSize - freeBudget, 900),
    )
    let fetching = makeFetchingChainState(~chainId=2, ~knownHeight=1000, ~latestFetchedBlock=0)
    let cm = makeCrossChainState(~chainStatesList=[buffered, fetching], ~targetBufferSize)
    let admitted = []

    await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
      switch action {
      | Ready(queries) =>
        admitted
        ->Array.push((
          chain->ChainMap.Chain.toChainId,
          queries->Array.reduce(0, (sum, query: FetchState.query) => sum + query.itemsEst),
        ))
        ->ignore
      | _ => ()
      }
      Promise.resolve()
    })

    admitted
  }

  Async.it("admits new queries at 10% free budget, but not below it", async t => {
    t.expect(
      (await queryWithFreeBudget(~freeBudget=9), await queryWithFreeBudget(~freeBudget=10)),
      ~message="A 100-item target waits with 9 free items and admits a 10-item cold probe with 10 free",
    ).toEqual(([], [(2, 10)]))
  })

  Async.it("starts no polls below the admission floor, except for height discovery", async t => {
    let atHead = makeChainState(
      ~chainId=1,
      ~knownHeight=1000,
      ~frontier=1000,
      ~firstEventBlock=0,
      ~bufferBlocks=Array.make(~length=91, 1000),
    )
    let behind = makeFetchingChainState(~chainId=2, ~knownHeight=1000, ~latestFetchedBlock=0)
    let waitingForHeight = makeFetchingChainState(~chainId=3, ~knownHeight=0, ~latestFetchedBlock=0)
    let cm = makeCrossChainState(
      ~chainStatesList=[atHead, behind, waitingForHeight],
      ~targetBufferSize=100,
    )
    let dispatched = []

    await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
      dispatched->Array.push((chain->ChainMap.Chain.toChainId, action))->ignore
      Promise.resolve()
    })

    t.expect(
      dispatched,
      ~message="At 9% free, no chain starts a query or a head poll — a saturated pool guarantees a ready-item batch or landing response re-ticks the scheduler. Only the chain without a known height keeps polling, since height discovery is its sole way in",
    ).toEqual([(3, FetchState.WaitingForNewBlock)])
  })

  Async.it("waits below the admission unit and retries after a response releases budget", async t => {
    let first = makeFetchingChainState(~chainId=1, ~knownHeight=1000, ~latestFetchedBlock=0)
    let second = makeFetchingChainState(~chainId=2, ~knownHeight=1000, ~latestFetchedBlock=500)
    let buffered = makeChainState(
      ~chainId=3,
      ~knownHeight=1000,
      ~frontier=900,
      ~firstEventBlock=0,
      ~bufferBlocks=Array.make(~length=85, 900),
    )
    let cm = makeCrossChainState(~chainStatesList=[first, second, buffered], ~targetBufferSize=100)
    let firstTickQueries = []

    await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
      switch action {
      | Ready(queries) =>
        firstTickQueries->Array.push((chain->ChainMap.Chain.toChainId, queries))->ignore
      | _ => ()
      }
      Promise.resolve()
    })

    t.expect(firstTickQueries->Array.map(((chainId, _)) => chainId)).toEqual([1])

    let (_, releasedQueries) = firstTickQueries->Utils.Array.firstUnsafe
    let releasedQuery = releasedQueries->Utils.Array.firstUnsafe
    first->ChainState.handleQueryResult(
      ~query=releasedQuery,
      ~newItems=[],
      ~newItemsWithDcs=[],
      ~latestFetchedBlock={blockNumber: 1000, blockTimestamp: 0},
      ~knownHeight=1000,
      ~transactionStore=None,
      ~blockStore=None,
    )

    let secondTickChains = []
    await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
      switch action {
      | Ready(_) => secondTickChains->Array.push(chain->ChainMap.Chain.toChainId)->ignore
      | _ => ()
      }
      Promise.resolve()
    })

    t.expect(
      secondTickChains,
      ~message="The second chain waits at 5% free, then starts after the first query releases its 10% reservation",
    ).toEqual([2])
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
        sourceRangeCapacity: 10,
        prevSourceRangeCapacity: 10,
        eventDensity: Some(10.), // density = 100 / 10 = 10 items/block
        latestSourceRangeCapacityUpdateBlock: 0,
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
        ~logger=Env.logger,
      )

      // Chain 2 (less behind, visited second): its density-bearing partition
      // sizes exactly to whatever budget it's given, so it directly reflects
      // what chain 1 left behind.
      let b = makeFetchingChainState(
        ~chainId=2,
        ~knownHeight=1000,
        ~latestFetchedBlock=500,
        ~chainDensity=Some(10.),
      )

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
    "checkAndFetch's waterfall clamps the next chain to the most-behind chain's frontier during backfill",
    async t => {
      t.expect(
        await runShortRangeWaterfall(~isRealtime=false),
        ~message="Chain 1's real range caps it at 200 items (itemsTarget carries the 1.5x headroom = 300, only the 200 estimate is reserved); chain 2's frontier is already past the alignment line anchored at chain 1's frontier, so it waits instead of draining the pool",
      ).toEqual((Some(300.), Some(0.), 200., 0.))
    },
  )

  Async.it("checkAndFetch drops the alignment clamp in realtime and sizes chunk caps with 3x headroom", async t => {
    t.expect(
      await runShortRangeWaterfall(~isRealtime=true),
      ~message="Chain 1's itemsTarget carries the 3x realtime headroom = 600, but pendingBudget still reserves the honest 200-item estimate; chain 2 is unclamped at realtime and gets the rest",
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
        ~message="Chain 1 waits for its first block; cold chain 2 gets one admission unit without being constrained by chain 1",
      ).toEqual(Dict.fromArray([("1", "waitingForNewBlock"), ("2", "ready:300")]))
    },
  )

  Async.it(
    "checkAndFetch aligns progress against the currently reachable end block",
    async t => {
      // The anchor's endBlock (1e9) is far past its head (1000). Its frontier
      // progress must be measured against the reachable range (500/1000 = 50%),
      // not the raw endBlock (500/1e9 ≈ 0%) — the latter would clamp the
      // follower below its own frontier and stall it.
      let anchor = makeFetchingChainState(
        ~chainId=1,
        ~knownHeight=1000,
        ~latestFetchedBlock=500,
        ~endBlock=Some(1_000_000_000),
        ~chainDensity=Some(1.),
      )
      let follower = makeFetchingChainState(
        ~chainId=2,
        ~knownHeight=1000,
        ~latestFetchedBlock=520,
        ~chainDensity=Some(1.),
      )
      let cm = makeCrossChainState(
        ~chainStatesList=[anchor, follower],
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
        ~message="The follower fetches up to the anchor's 50% line (+10% margin = block 600), not to nothing",
      ).toEqual(Dict.fromArray([("1", 500), ("2", 80)]))
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

  Async.it("cold most-behind chain still anchors the alignment line at its frontier", async t => {
    // Chain 1 is cold and most behind. Its target is a guess, but its frontier
    // is a real measurement — chain 2 must not run ahead of it just because
    // chain 1 hasn't produced a density signal yet.
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
      ~message="Cold chain 1 gets its bounded probe; chain 2 (already past the line anchored at chain 1's 0% frontier) waits",
    ).toEqual(Dict.fromArray([("1", 1000.), ("2", 0.)]))
  })

  Async.it("most-behind chain anchors the alignment line even when it emits no query", async t => {
    // Chain 1 is most behind but produces no new query this tick (its buffer
    // holds a ready item that batch processing will drain). Before frontier
    // anchoring, such a tick left the line unset and chain 2 ran unclamped to
    // its head; now chain 2 stays held at chain 1's frontier (+10% margin).
    let a = makeChainState(
      ~chainId=1,
      ~knownHeight=1000,
      ~frontier=100,
      ~firstEventBlock=0,
      ~bufferBlocks=[100],
    )
    let b = makeFetchingChainState(
      ~chainId=2,
      ~knownHeight=1000,
      ~latestFetchedBlock=500,
      ~chainDensity=Some(10.),
    )
    let cm = makeCrossChainState(~chainStatesList=[a, b], ~targetBufferSize=10_000)

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
      actionsByChain->Dict.get("2"),
      ~message="Chain 2's frontier (500) is past chain 1's line (10% + 10% margin = block 200), so it waits instead of fetching to head",
    ).toEqual(Some("waitingForNewBlock"))
  })

  Async.it("realtime indexer drops the alignment clamp", async t => {
    // Same shape as the anchoring test above, but the indexer is realtime:
    // chain 2 must be free to fetch to its head regardless of chain 1.
    let a = makeChainState(
      ~chainId=1,
      ~knownHeight=1000,
      ~frontier=100,
      ~firstEventBlock=0,
      ~bufferBlocks=[100],
    )
    let b = makeFetchingChainState(
      ~chainId=2,
      ~knownHeight=1000,
      ~latestFetchedBlock=500,
      ~chainDensity=Some(10.),
    )
    let cm = makeCrossChainState(
      ~chainStatesList=[a, b],
      ~isRealtime=true,
      ~targetBufferSize=10_000,
    )

    let dispatchedItemsByChain = Dict.make()
    await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
      dispatchedItemsByChain->Utils.Dict.setByInt(
        chain->ChainMap.Chain.toChainId,
        switch action {
        | Ready(queries) =>
          queries->Array.reduce(0, (acc, q: FetchState.query) => acc + q.itemsEst)
        | _ => 0
        },
      )
      Promise.resolve()
    })

    t.expect(
      dispatchedItemsByChain->Dict.get("2"),
      ~message="Chain 2 fetches its full 500-block range to head at density 10",
    ).toEqual(Some(5000))
  })

  Async.it("gives a cold chain one 10% admission unit", async t => {
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
      ~message="The cold probe scales with the configured target buffer",
    ).toEqual((1000., 200.))
  })

  it("frontierProgress reads 100% at the lagged head", t => {
    // knownHeight 1000 held back by blockLag 200 -> the fetchable head is 800.
    // A chain fetched to 800 is fully caught up and must read 1.0, not 0.8, so
    // it never looks behind against blocks it can't fetch yet.
    let cs = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=1000,
      ~latestFetchedBlock=800,
      ~blockLag=200,
    )
    t.expect(cs->ChainState.frontierProgress).toBe(1.)
  })

  Async.it("a chain with no discovered first event never becomes a dead anchor", async t => {
    // Chain 1 has found no events yet (firstEventBlock=None) but has already
    // scanned to 90% of its range. FetchState.getProgressPercentage reports it
    // at 0% (its priority rank), yet its fetch frontier is far ahead. The
    // alignment anchor must be chain 2 (furthest behind by frontier progress),
    // so chain 3 (just ahead of chain 2) is held near chain 2's line instead of
    // racing to head on chain 1's non-clamping frontier.
    let scanning = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=1000,
      ~latestFetchedBlock=900,
      ~chainDensity=Some(10.),
      ~firstEventBlock=None,
    )
    let behind = makeFetchingChainState(
      ~chainId=2,
      ~knownHeight=1000,
      ~latestFetchedBlock=300,
      ~chainDensity=Some(10.),
    )
    let slightlyAhead = makeFetchingChainState(
      ~chainId=3,
      ~knownHeight=1000,
      ~latestFetchedBlock=310,
      ~chainDensity=Some(10.),
    )
    let cm = makeCrossChainState(
      ~chainStatesList=[scanning, behind, slightlyAhead],
      ~targetBufferSize=100_000,
    )

    let itemsByChain = Dict.make()
    await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) => {
      itemsByChain->Utils.Dict.setByInt(
        chain->ChainMap.Chain.toChainId,
        switch action {
        | Ready(queries) => queries->Array.reduce(0, (acc, q: FetchState.query) => acc + q.itemsEst)
        | _ => 0
        },
      )
      Promise.resolve()
    })

    let items = chainId => itemsByChain->Utils.Dict.dangerouslyGetByIntNonOption(chainId)->Option.getOr(0)
    // Structural, not exact: chain 1 (scanning, firstEventBlock=None) must set
    // no line and idle; chain 2 (lowest frontier progress) anchors and fetches
    // freely; chain 3 stays clamped near chain 2's line — far below what it
    // would fetch if chain 1's near-head frontier were the anchor.
    t.expect(
      {
        "scanningChainIdle": items(1) == 0,
        "anchorFetchesFreely": items(2) > items(3),
        "followerHeldFarBelowAnchor": items(3) > 0 && items(3) * 3 < items(2),
      },
      ~message="The genuinely-behind chain 2 anchors the line; chain 3 is held near it instead of racing to head on the scanning chain's non-clamping frontier",
    ).toEqual({
      "scanningChainIdle": true,
      "anchorFetchesFreely": true,
      "followerHeldFarBelowAnchor": true,
    })
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
