open Vitest

let chainId = 1
let baseChainConfig = {...Config.load().chainMap->ChainMap.values->Utils.Array.firstUnsafe, id: chainId}

// A registrations map with an onBlock config (no address partition) so
// FetchState.make has something to index without needing real event configs.
let registrationsByChainId: HandlerRegister.registrationsByChainId = {
  let d = Dict.make()
  d->Dict.set(
    chainId->Int.toString,
    ({
      onEventRegistrations: [],
      onBlockRegistrations: [
        {
          Internal.index: 0,
          name: "chain-density-test",
          chainId,
          startBlock: None,
          endBlock: None,
          interval: 1,
          handler: "mock onBlock handler"->(Utils.magic: string => Internal.onBlockArgs => promise<unit>),
        },
      ],
    }: HandlerRegister.chainRegistrations),
  )
  d
}

let makeResumedChainState = (
  ~progressBlockNumber,
  ~numEventsProcessed,
  ~firstEventBlockNumber,
): Persistence.initialChainState => {
  id: chainId,
  startBlock: 0,
  endBlock: None,
  maxReorgDepth: 200,
  progressBlockNumber,
  numEventsProcessed,
  firstEventBlockNumber,
  timestampCaughtUpToHeadOrEndblock: None,
  indexingAddresses: [],
  sourceBlockNumber: 1000,
}

let makeChainState = resumedChainState =>
  ChainState.makeFromDbState(
    baseChainConfig,
    ~resumedChainState,
    ~reorgCheckpoints=[],
    ~isInReorgThreshold=false,
    ~isRealtime=false,
    ~config=Config.load(),
    ~registrationsByChainId,
  )

describe("ChainState chain density seed (on resume)", () => {
  it("seeds from cumulative resumed progress when there's a first event block", t => {
    let cs = makeChainState(
      makeResumedChainState(
        ~progressBlockNumber=110,
        ~numEventsProcessed=500.,
        ~firstEventBlockNumber=Some(10),
      ),
    )
    // 500 events over (110 - 10) = 100 blocks -> 5 events/block
    t.expect(cs->ChainState.chainDensity).toEqual(Some(5.))
  })

  it("is None on a fresh chain with no resumed progress", t => {
    let cs = makeChainState(
      makeResumedChainState(~progressBlockNumber=-1, ~numEventsProcessed=0., ~firstEventBlockNumber=None),
    )
    t.expect(cs->ChainState.chainDensity).toEqual(None)
  })

  it("is None when no event has been found yet, even with resumed progress", t => {
    let cs = makeChainState(
      makeResumedChainState(
        ~progressBlockNumber=110,
        ~numEventsProcessed=0.,
        ~firstEventBlockNumber=None,
      ),
    )
    t.expect(cs->ChainState.chainDensity).toEqual(None)
  })
})

describe("ChainState chain density EMA (per batch)", () => {
  // applyBatchProgress doesn't read chainAfterBatch.fetchState, so any valid
  // value works here — a fresh, minimal one, independent of the chain state
  // under test.
  let dummyFetchState = () =>
    FetchState.make(
      ~onEventRegistrations=[],
      ~contractConfigs=Dict.make(),
      ~addresses=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=1,
      ~maxOnBlockBufferSize=10,
      ~chainId,
      ~knownHeight=0,
      ~onBlockRegistrations=[
        {
          Internal.index: 0,
          name: "dummy",
          chainId,
          startBlock: None,
          endBlock: None,
          interval: 1,
          handler: "mock"->(Utils.magic: string => Internal.onBlockArgs => promise<unit>),
        },
      ],
    )

  let makeBatch = (~progressBlockNumber, ~totalEventsProcessed, ~fetchState): Batch.t => {
    totalBatchSize: 0,
    items: [],
    progressedChainsById: {
      let d = Dict.make()
      d->Utils.Dict.setByInt(
        chainId,
        ({
          batchSize: 0,
          progressBlockNumber,
          sourceBlockNumber: 1000,
          totalEventsProcessed,
          fetchState,
          isProgressAtHeadWhenBatchCreated: false,
        }: Batch.chainAfterBatch),
      )
      d
    },
    isInReorgThreshold: false,
    checkpointIds: [],
    checkpointChainIds: [],
    checkpointBlockNumbers: [],
    checkpointBlockHashes: [],
    checkpointEventsProcessed: [],
  }

  it("seeds density from the first batch's own events/block (no prior density to blend)", t => {
    let cs = makeChainState(
      makeResumedChainState(~progressBlockNumber=0, ~numEventsProcessed=0., ~firstEventBlockNumber=None),
    )
    let fetchState = dummyFetchState()
    cs->ChainState.applyBatchProgress(
      ~batch=makeBatch(~progressBlockNumber=10, ~totalEventsProcessed=100., ~fetchState),
      ~blockTimestampName="timestamp",
    )
    // (100 - 0) events over (10 - 0) blocks = 10 events/block
    t.expect(cs->ChainState.chainDensity).toEqual(Some(10.))
  })

  it("stays None after a progress-only batch with no events", t => {
    let cs = makeChainState(
      makeResumedChainState(~progressBlockNumber=0, ~numEventsProcessed=0., ~firstEventBlockNumber=None),
    )
    let fetchState = dummyFetchState()
    // Progressed 10 blocks but processed 0 events — must not seed a 0 density.
    cs->ChainState.applyBatchProgress(
      ~batch=makeBatch(~progressBlockNumber=10, ~totalEventsProcessed=0., ~fetchState),
      ~blockTimestampName="timestamp",
    )
    t.expect(cs->ChainState.chainDensity).toEqual(None)
  })

  it("blends with the previous density weighted by the batch's block span", t => {
    let cs = makeChainState(
      makeResumedChainState(~progressBlockNumber=0, ~numEventsProcessed=0., ~firstEventBlockNumber=None),
    )
    let fetchState = dummyFetchState()
    cs->ChainState.applyBatchProgress(
      ~batch=makeBatch(~progressBlockNumber=10, ~totalEventsProcessed=100., ~fetchState),
      ~blockTimestampName="timestamp",
    )
    t.expect(cs->ChainState.chainDensity, ~message="seeded at 10 events/block").toEqual(Some(10.))

    // Second batch: 1_000 events over 50 blocks = 20 events/block. Half a
    // densityBlendWindow -> alpha 0.5: 10 * 0.5 + 20 * 0.5 = 15.
    cs->ChainState.applyBatchProgress(
      ~batch=makeBatch(~progressBlockNumber=60, ~totalEventsProcessed=1_100., ~fetchState),
      ~blockTimestampName="timestamp",
    )
    t.expect(cs->ChainState.chainDensity, ~message="half-window batch blends 50/50").toEqual(
      Some(15.),
    )

    // Third batch: 2_500 events over 100 blocks = 25 events/block. A full
    // densityBlendWindow -> alpha 1: replaces the old density entirely.
    cs->ChainState.applyBatchProgress(
      ~batch=makeBatch(~progressBlockNumber=160, ~totalEventsProcessed=3_600., ~fetchState),
      ~blockTimestampName="timestamp",
    )
    t.expect(cs->ChainState.chainDensity, ~message="full-window batch replaces").toEqual(Some(25.))
  })
})

describe("ChainState reorg-threshold readiness latch", () => {
  // A chain with no address partitions, so bufferBlockNumber follows
  // latestOnBlockBlockNumber (the fetch frontier) and readiness can be set
  // directly. blockLag defaults to 0, so the lagged head is knownHeight.
  let makeAtFrontier = (~knownHeight, ~frontier) => {
    let base = FetchState.make(
      ~onEventRegistrations=[],
      ~contractConfigs=Dict.make(),
      ~addresses=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~maxOnBlockBufferSize=10000,
      ~chainId,
      ~knownHeight=0,
      ~onBlockRegistrations=[
        {
          Internal.index: 0,
          name: "latch-test",
          chainId,
          startBlock: None,
          endBlock: None,
          interval: 1,
          handler: "mock onBlock handler"->(
            Utils.magic: string => Internal.onBlockArgs => promise<unit>
          ),
        },
      ],
    )
    let fetchState = {...base, knownHeight, latestOnBlockBlockNumber: frontier, buffer: []}
    ChainState.make(
      ~chainConfig={...baseChainConfig, id: chainId},
      ~fetchState,
      ~indexingAddresses=IndexingAddresses.make(~contractConfigs=Dict.make(), ~addresses=[]),
      ~sourceManager=SourceManager.make(
        ~sources=[MockIndexer.Source.make([], ~chain=#1).source],
        ~isRealtime=false,
      ),
      ~reorgDetection=ReorgDetection.make(
        ~chainReorgCheckpoints=[],
        ~maxReorgDepth=200,
        ~shouldRollbackOnReorg=true,
      ),
      ~committedProgressBlockNumber=-1,
      ~logger=Logging.getLogger(),
    )
  }

  it("is not ready below the head, and stays ready after the head advances", t => {
    let belowHead = makeAtFrontier(~knownHeight=1000, ~frontier=990)

    let atHead = makeAtFrontier(~knownHeight=1000, ~frontier=1000)
    let readyAtHead = atHead->ChainState.isReadyToEnterReorgThreshold
    // New block after the chain reached its head: without the latch this would
    // retract readiness (frontier 1000 < head 1001).
    atHead->ChainState.updateKnownHeight(~knownHeight=1001)

    t.expect(
      (
        belowHead->ChainState.isReadyToEnterReorgThreshold,
        readyAtHead,
        atHead->ChainState.isReadyToEnterReorgThreshold,
      ),
      ~message="readiness latches on reaching the head and survives a later head advance",
    ).toEqual((false, true, true))
  })
})
