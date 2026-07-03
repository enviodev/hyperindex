open Vitest

let baseChainConfig = Config.loadWithoutRegistrations().chainMap->ChainMap.values->Utils.Array.firstUnsafe

let mockEvent = (~blockNumber): Internal.item =>
  Internal.Event({
    timestamp: blockNumber * 15,
    chain: ChainMap.Chain.makeUnsafe(~chainId=1),
    blockNumber,
    blockHash: `0x${blockNumber->Int.toString}`,
    eventConfig: "Mock eventConfig in CrossChainState test"->(Utils.magic: string => Internal.eventConfig),
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
  let eventConfigs = []
  let addresses = []
  let contractConfigs = IndexingAddresses.makeContractConfigs(~eventConfigs)
  let indexingAddresses = IndexingAddresses.make(~contractConfigs, ~addresses)
  let base = FetchState.make(
    // An onBlock config (no address partition) satisfies "something to fetch"
    // while keeping bufferBlockNumber tied to latestOnBlockBlockNumber.
    ~eventConfigs,
    ~contractConfigs,
    ~addresses,
    ~onBlockConfigs=[
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
let makeFetchingChainState = (
  ~chainId,
  ~knownHeight,
  ~latestFetchedBlock,
  ~bufferBlocks=[],
  // The partition's own frontier, when it fetched ahead of the chain frontier
  // (latestFetchedBlock keeps holding latestOnBlockBlockNumber back).
  ~partitionFetchedBlock=?,
) => {
  let normalSelection = {FetchState.dependsOnAddresses: false, eventConfigs: []}
  let address = "0x1234567890123456789012345678901234567890"->Address.unsafeFromString
  let partition: FetchState.partition = {
    id: "0",
    latestFetchedBlock: {
      blockNumber: partitionFetchedBlock->Option.getOr(latestFetchedBlock),
      blockTimestamp: 0,
    },
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
    buffer: bufferBlocks->Array.map(blockNumber => mockEvent(~blockNumber)),
    normalSelection,
    latestOnBlockBlockNumber: latestFetchedBlock,
    maxOnBlockBufferSize: 10000,
    chainId,
    contractConfigs: Dict.make(),
    blockLag: 0,
    onBlockConfigs: [],
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

let makeCrossChainState = (
  ~chainStatesList,
  ~isRealtime=false,
  ~isInReorgThreshold=false,
  ~targetBufferSize=100,
) => {
  let chainStates = Dict.make()
  chainStatesList->Array.forEach(cs =>
    chainStates->Utils.Dict.setByInt((cs->ChainState.chainConfig).id, cs)
  )
  CrossChainState.make(~chainStates, ~isInReorgThreshold, ~isRealtime, ~targetBufferSize)
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

describe("CrossChainState buffer prune", () => {
  // knownHeight 10000, firstEventBlock 0 (from the helper) → progress% == block/10000.
  // maxReorgDepth defaults to 200, so the reorg floor is 9800 — all the blocks
  // below stay prunable. Both chains hold the frontier at block 100 with 40
  // buffered-ahead items each.
  let makeStuck = (~chainId, ~fromBlock) =>
    makeFetchingChainState(
      ~chainId,
      ~knownHeight=10000,
      ~latestFetchedBlock=100,
      ~bufferBlocks=Array.fromInitializer(~length=40, i => fromBlock + i),
    )

  Async.it("prunes the closest-to-head items across chains down to the low-water mark", async t => {
    // targetBufferSize 20 → prune when the buffer exceeds 3x (60), down to 2x
    // (40). Chain 1's items sit at ~0.8 progress, chain 2's at ~0.2, so dropping
    // the head-closest chain 1 entirely frees exactly the 40 items needed and
    // chain 2 is untouched — only the pruned chain records a hold-back target.
    let cs1 = makeStuck(~chainId=1, ~fromBlock=8000)
    let cs2 = makeStuck(~chainId=2, ~fromBlock=2000)
    let cm = makeCrossChainState(~chainStatesList=[cs1, cs2], ~targetBufferSize=20)

    await cm->CrossChainState.checkAndFetch(
      ~dispatchChain=(~chain as _, ~action as _) => Promise.resolve(),
    )

    t.expect({
      "chain1Buffer": cs1->ChainState.bufferSize,
      "chain2Buffer": cs2->ChainState.bufferSize,
      "chain1PruneTarget": cs1->ChainState.lastPruneTarget,
      "chain2PruneTarget": cs2->ChainState.lastPruneTarget,
    }).toEqual({
      "chain1Buffer": 0,
      "chain2Buffer": 40,
      "chain1PruneTarget": Some(7999),
      "chain2PruneTarget": None,
    })
  })

  Async.it("leaves the buffer untouched below the high-water mark", async t => {
    // 80 items total but targetBufferSize 100 → high-water 300, so no prune.
    let cs1 = makeStuck(~chainId=1, ~fromBlock=8000)
    let cs2 = makeStuck(~chainId=2, ~fromBlock=2000)
    let cm = makeCrossChainState(~chainStatesList=[cs1, cs2], ~targetBufferSize=100)

    await cm->CrossChainState.checkAndFetch(
      ~dispatchChain=(~chain as _, ~action as _) => Promise.resolve(),
    )

    t.expect({
      "chain1Buffer": cs1->ChainState.bufferSize,
      "chain2Buffer": cs2->ChainState.bufferSize,
      "chain1PruneTarget": cs1->ChainState.lastPruneTarget,
      "chain2PruneTarget": cs2->ChainState.lastPruneTarget,
    }).toEqual({
      "chain1Buffer": 40,
      "chain2Buffer": 40,
      "chain1PruneTarget": None,
      "chain2PruneTarget": None,
    })
  })

  Async.it("holds back the pruned range instead of refetching it in the same tick", async t => {
    // One partition fetched ahead to 8039 while the chain frontier sits at 100,
    // so all 40 buffered items are stuck. targetBufferSize 10 → prune at 3x (30)
    // down to 2x (20): target lands at 8019. The rolled-back partition
    // immediately re-proposes 8020+, but the buffer (20) is still above the
    // target (10), so admission holds the range back and nothing is dispatched.
    let cs = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=10000,
      ~latestFetchedBlock=100,
      ~partitionFetchedBlock=8039,
      ~bufferBlocks=Array.fromInitializer(~length=40, i => 8000 + i),
    )
    let cm = makeCrossChainState(~chainStatesList=[cs], ~targetBufferSize=10)

    let dispatched = []
    await cm->CrossChainState.checkAndFetch(
      ~dispatchChain=(~chain, ~action as _) => {
        dispatched->Array.push(chain->ChainMap.Chain.toChainId)->ignore
        Promise.resolve()
      },
    )

    t.expect({
      "buffer": cs->ChainState.bufferSize,
      "pruneTarget": cs->ChainState.lastPruneTarget,
      "dispatched": dispatched,
    }).toEqual({
      "buffer": 20,
      "pruneTarget": Some(8019),
      "dispatched": [],
    })
  })

  Async.it("prunes inside the reorg threshold too", async t => {
    // The indexer-wide threshold flag is sticky and set on restart if any chain
    // resumed near its head, so a far-behind chain must still get its buffer
    // bounded while the flag is on.
    let cs = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=10000,
      ~latestFetchedBlock=100,
      ~partitionFetchedBlock=8039,
      ~bufferBlocks=Array.fromInitializer(~length=40, i => 8000 + i),
    )
    let cm = makeCrossChainState(
      ~chainStatesList=[cs],
      ~targetBufferSize=10,
      ~isInReorgThreshold=true,
    )

    await cm->CrossChainState.checkAndFetch(
      ~dispatchChain=(~chain as _, ~action as _) => Promise.resolve(),
    )

    t.expect({
      "buffer": cs->ChainState.bufferSize,
      "pruneTarget": cs->ChainState.lastPruneTarget,
    }).toEqual({
      "buffer": 20,
      "pruneTarget": Some(8019),
    })
  })

  it("keeps the lower prune target when pruned again with a higher one", t => {
    // A second prune in the same above-target episode must not release the
    // range parked at the first, lower target.
    let cs = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=10000,
      ~latestFetchedBlock=100,
      ~partitionFetchedBlock=8039,
      ~bufferBlocks=Array.fromInitializer(~length=40, i => 8000 + i),
    )
    cs->ChainState.pruneBuffer(~targetBlockNumber=5000)
    cs->ChainState.pruneBuffer(~targetBlockNumber=8000)

    t.expect(cs->ChainState.lastPruneTarget).toEqual(Some(5000))
  })

  Async.it("clears the prune target and refetches once the buffer drains", async t => {
    // Same shape, but pruned directly and with the buffer already drained below
    // targetBufferSize: the tick clears the target and re-admits the range.
    let cs = makeFetchingChainState(
      ~chainId=1,
      ~knownHeight=10000,
      ~latestFetchedBlock=100,
      ~partitionFetchedBlock=8039,
      ~bufferBlocks=Array.fromInitializer(~length=40, i => 8000 + i),
    )
    cs->ChainState.pruneBuffer(~targetBlockNumber=8004)
    let cm = makeCrossChainState(~chainStatesList=[cs], ~targetBufferSize=100)

    let dispatched = []
    await cm->CrossChainState.checkAndFetch(
      ~dispatchChain=(~chain, ~action) => {
        dispatched
        ->Array.push((
          chain->ChainMap.Chain.toChainId,
          switch action {
          | Ready(queries) => queries->Array.map(q => q.fromBlock)
          | _ => []
          },
        ))
        ->ignore
        Promise.resolve()
      },
    )

    t.expect({
      "buffer": cs->ChainState.bufferSize,
      "pruneTarget": cs->ChainState.lastPruneTarget,
      "dispatched": dispatched,
    }).toEqual({
      "buffer": 5,
      "pruneTarget": None,
      "dispatched": [(1, [8005])],
    })
  })
})

