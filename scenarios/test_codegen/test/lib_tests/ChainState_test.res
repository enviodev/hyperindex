open Vitest

let baseChainConfig = Config.load().chainMap->ChainMap.values->Utils.Array.firstUnsafe

// Minimal fetchState with no partitions - only firstEventBlock matters for density.
let makeFetchState = (~firstEventBlock): FetchState.t => {
  optimizedPartitions: FetchState.OptimizedPartitions.make(
    ~partitions=[],
    ~maxAddrInPartition=1,
    ~nextPartitionIndex=0,
    ~dynamicContracts=Utils.Set.make(),
  ),
  startBlock: 0,
  endBlock: None,
  buffer: [],
  normalSelection: {FetchState.dependsOnAddresses: false, onEventRegistrations: []},
  latestOnBlockBlockNumber: 0,
  maxOnBlockBufferSize: 10000,
  chainId: 1,
  contractConfigs: Dict.make(),
  blockLag: 0,
  onBlockRegistrations: [],
  knownHeight: 0,
  firstEventBlock,
}

let makeChainState = (~firstEventBlock, ~committedProgressBlockNumber=-1, ~numEventsProcessed=0.) => {
  let mockSource = MockIndexer.Source.make([], ~chain=#1)
  ChainState.make(
    ~chainConfig=baseChainConfig,
    ~fetchState=makeFetchState(~firstEventBlock),
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

// A batch that only carries the progress/event-count fields applyBatchProgress
// reads for density - no items, so firstEventBlock must already be set on the
// chain for the blend to run (mirrors a chain past its first-event batch).
let makeProgressBatch = (~chainId, ~progressBlockNumber, ~totalEventsProcessed): Batch.t => {
  let progressedChainsById = Dict.make()
  progressedChainsById->Utils.Dict.setByInt(
    chainId,
    {
      Batch.batchSize: 0,
      progressBlockNumber,
      sourceBlockNumber: progressBlockNumber,
      totalEventsProcessed,
      fetchState: makeFetchState(~firstEventBlock=None),
      isProgressAtHeadWhenBatchCreated: false,
    },
  )
  {
    totalBatchSize: 0,
    items: [],
    progressedChainsById,
    isInReorgThreshold: false,
    checkpointIds: [],
    checkpointChainIds: [],
    checkpointBlockNumbers: [],
    checkpointBlockHashes: [],
    checkpointEventsProcessed: [],
  }
}

describe("ChainState density", () => {
  it("is None before firstEventBlock is known", t => {
    let cs = makeChainState(~firstEventBlock=None, ~committedProgressBlockNumber=500, ~numEventsProcessed=1000.)
    t.expect(cs->ChainState.density).toEqual(None)
  })

  it("seeds from lifetime progress at construction", t => {
    // 200 events over blocks 10..110 (100 blocks) -> 2 items/block.
    let cs = makeChainState(
      ~firstEventBlock=Some(10),
      ~committedProgressBlockNumber=110,
      ~numEventsProcessed=200.,
    )
    t.expect(cs->ChainState.density).toEqual(Some(2.))
  })

  it("blends a batch's rate into the running EMA 2:1 new:old", t => {
    // Seeded at 2.0 (200 events / 100 blocks). Next batch advances 50 blocks
    // (110 -> 160) with 200 more events -> this batch's rate is 4.0.
    // Blended: (2*4 + 2) / 3 = 3.3333...
    let cs = makeChainState(
      ~firstEventBlock=Some(10),
      ~committedProgressBlockNumber=110,
      ~numEventsProcessed=200.,
    )
    cs->ChainState.applyBatchProgress(
      ~batch=makeProgressBatch(
        ~chainId=(cs->ChainState.chainConfig).id,
        ~progressBlockNumber=160,
        ~totalEventsProcessed=400.,
      ),
    )
    t.expect(cs->ChainState.density).toEqual(Some(10. /. 3.))
  })

  it("takes the whole lifetime as its first sample when unseeded", t => {
    // No progress committed yet (-1 sentinel) and no firstEventBlock at
    // construction; the first batch both discovers firstEventBlock (from the
    // batch, not exercised here since we set it directly for simplicity) and
    // supplies the first density sample directly, with no prior estimate to blend.
    let cs = makeChainState(~firstEventBlock=Some(5))
    cs->ChainState.applyBatchProgress(
      ~batch=makeProgressBatch(~chainId=(cs->ChainState.chainConfig).id, ~progressBlockNumber=55, ~totalEventsProcessed=500.),
    )
    // 500 events over blocks 5..55 (50 blocks) -> 10 items/block, unblended.
    t.expect(cs->ChainState.density).toEqual(Some(10.))
  })
})
