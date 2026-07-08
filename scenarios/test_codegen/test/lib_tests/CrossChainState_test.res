open Vitest

let baseChainConfig = Config.load().chainMap->ChainMap.values->Utils.Array.firstUnsafe

let mockEvent = (~blockNumber): Internal.item =>
  Internal.Event({
    timestamp: blockNumber * 15,
    chain: ChainMap.Chain.makeUnsafe(~chainId=1),
    blockNumber,
    blockHash: `0x${blockNumber->Int.toString}`,
    onEventRegistration: "Mock onEventRegistration in CrossChainState test"->(Utils.magic: string => Internal.onEventRegistration),
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
) => {
  let onEventRegistrations = []
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
let makeFetchingChainState = (~chainId, ~knownHeight, ~latestFetchedBlock) => {
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
    endBlock: None,
    buffer: [],
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

    cm->CrossChainState.applyBatchProgress(~batch=emptyBatch)

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

    cm->CrossChainState.applyBatchProgress(~batch=emptyBatch)

    t.expect({
      "aReady": a->ChainState.isReady,
      "bReady": b->ChainState.isReady,
      "isRealtime": cm->CrossChainState.isRealtime,
    }).toEqual({"aReady": true, "bReady": true, "isRealtime": true})
  })
})


describe("CrossChainState two-budget scheduling", () => {
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}
  let addrOf = id =>
    ("0x123456789012345678901234567890123456789" ++ id)->Address.unsafeFromString

  let mkPartition = (~id, ~lfb): FetchState.partition => {
    id,
    latestFetchedBlock: {blockNumber: lfb, blockTimestamp: 0},
    selection: normalSelection,
    addressesByContractName: Dict.fromArray([("MockContract", [addrOf(id)])]),
    mergeBlock: None,
    dynamicContract: None,
    mutPendingQueries: [],
    prevQueryRange: 0,
    prevPrevQueryRange: 0,
    prevRangeSize: 0,
    latestBlockRangeUpdateBlock: 0,
  }

  // Density lives on ChainState now (one EMA per chain, not per partition). Passing
  // ~density seeds it the same way ChainState.make does for a resumed chain:
  // numEventsProcessed over blocks processed since firstEventBlock (0). Omitting it
  // leaves committedProgressBlockNumber at -1 (no progress yet), so the chain reads
  // as cold and falls back to a fixed reach, same as before density existed.
  let makeChain = (~chainId, ~knownHeight, ~partitions, ~buffer=[], ~density=?) => {
    let fetchState: FetchState.t = {
      optimizedPartitions: FetchState.OptimizedPartitions.make(
        ~partitions,
        ~maxAddrInPartition=2,
        ~nextPartitionIndex=partitions->Array.length,
        ~dynamicContracts=Utils.Set.make(),
      ),
      startBlock: 0,
      endBlock: None,
      buffer,
      normalSelection,
      latestOnBlockBlockNumber: knownHeight,
      maxOnBlockBufferSize: 10000,
      chainId,
      contractConfigs: Dict.make(),
      blockLag: 0,
      onBlockRegistrations: [],
      knownHeight,
      firstEventBlock: Some(0),
    }
    let (committedProgressBlockNumber, numEventsProcessed) = switch density {
    | Some(d) => (100, d *. 100.)
    | None => (-1, 0.)
    }
    let mockSource = MockIndexer.Source.make([], ~chain=#1)
    ChainState.make(
      ~chainConfig={...baseChainConfig, id: chainId},
      ~fetchState,
      ~indexingAddresses=Dict.make()->(
        Utils.magic: dict<Internal.indexingContract> => IndexingAddresses.t
      ),
      ~sourceManager=SourceManager.make(~sources=[mockSource.source], ~isRealtime=false),
      ~reorgDetection=ReorgDetection.make(
        ~chainReorgCheckpoints=[],
        ~maxReorgDepth=200,
        ~shouldRollbackOnReorg=false,
      ),
      ~committedProgressBlockNumber,
      ~numEventsProcessed,
      ~logger=Logging.getLogger(),
    )
  }

  let dispatchedQueries = async cm => {
    let queries = []
    await cm->CrossChainState.checkAndFetch(~dispatchChain=(~chain as _, ~action) => {
      switch action {
      | Ready(qs) => qs->Array.forEach(q => queries->Array.push(q)->ignore)
      | _ => ()
      }
      Promise.resolve()
    })
    queries
  }

  Async.it("keeps advancing the frontier when the buffer is full of stuck items", async t => {
    // Warm chain (density 1.0), single partition far behind head. 150 buffered
    // items sit at block 200 (above the frontier) → all stuck, readyCount 0
    // (readyBudget open), prefetchBudget 0 (total buffered already exceeds
    // target). The gap-closer must still go out — a stuck-full buffer must not
    // stall frontier progress.
    let stuck = Belt.Array.make(150, 0)->Array.map(_ => mockEvent(~blockNumber=200))
    let cs = makeChain(
      ~chainId=1,
      ~knownHeight=100000,
      ~partitions=[mkPartition(~id="0", ~lfb=100)],
      ~buffer=stuck,
      ~density=1.0,
    )
    let cm = makeCrossChainState(~chainStatesList=[cs], ~targetBufferSize=100)
    let queries = await dispatchedQueries(cm)
    t.expect(queries->Array.map(q => (q.partitionId, q.isPrefetch))).toEqual([("0", false)])
  })

  Async.it("classifies a far-ahead partition as prefetch, the frontier one as gap-closer", async t => {
    // p0 at the frontier (block 100) → gap-closer; p1 parked >20k ahead (block
    // 100000) → prefetch, drawn from the separate prefetch budget. Classification
    // is by block distance from the frontier, not density, so a single chain-wide
    // density covering both partitions doesn't affect it.
    let cs = makeChain(
      ~chainId=1,
      ~knownHeight=1000000,
      ~partitions=[mkPartition(~id="0", ~lfb=100), mkPartition(~id="1", ~lfb=100000)],
      ~density=1.0,
    )
    let cm = makeCrossChainState(~chainStatesList=[cs], ~targetBufferSize=1000)
    let queries = await dispatchedQueries(cm)
    // Both partitions get queries (each may chunk); every p0 query is a gap-closer
    // and every p1 query is a prefetch.
    t.expect({
      "p0AllGapClosers": queries->Array.every(q => q.partitionId != "0" || !q.isPrefetch),
      "p1AllPrefetch": queries->Array.every(q => q.partitionId != "1" || q.isPrefetch),
      "p0Dispatched": queries->Array.some(q => q.partitionId == "0"),
      "p1Dispatched": queries->Array.some(q => q.partitionId == "1"),
    }).toEqual({
      "p0AllGapClosers": true,
      "p1AllPrefetch": true,
      "p0Dispatched": true,
      "p1Dispatched": true,
    })
  })

  Async.it("still prefetches parked-ahead partitions when the ready buffer is full", async t => {
    // The buffer already holds `target` ready items at block 50 (<= frontier 100),
    // so the ready budget is 0 and the frontier gap-closer (p0) is skipped. The
    // prefetch budget is independent, so the far-ahead partition (p1) is still
    // warmed — prefetch is not coupled to the ready budget.
    let ready = Belt.Array.make(5, 0)->Array.map(_ => mockEvent(~blockNumber=50))
    let cs = makeChain(
      ~chainId=1,
      ~knownHeight=1000000,
      ~partitions=[mkPartition(~id="0", ~lfb=100), mkPartition(~id="1", ~lfb=100000)],
      ~buffer=ready,
      ~density=1.0,
    )
    let cm = makeCrossChainState(~chainStatesList=[cs], ~targetBufferSize=5)
    let queries = await dispatchedQueries(cm)
    t.expect({
      "gapCloserDispatched": queries->Array.some(q => q.partitionId == "0"),
      "prefetchDispatched": queries->Array.some(q => q.partitionId == "1" && q.isPrefetch),
    }).toEqual({"gapCloserDispatched": false, "prefetchDispatched": true})
  })
})
