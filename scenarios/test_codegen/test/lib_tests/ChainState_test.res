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

  it("blends with the previous density as (old + new) / 2 on later batches", t => {
    let cs = makeChainState(
      makeResumedChainState(~progressBlockNumber=0, ~numEventsProcessed=0., ~firstEventBlockNumber=None),
    )
    let fetchState = dummyFetchState()
    cs->ChainState.applyBatchProgress(
      ~batch=makeBatch(~progressBlockNumber=10, ~totalEventsProcessed=100., ~fetchState),
      ~blockTimestampName="timestamp",
    )
    t.expect(cs->ChainState.chainDensity, ~message="seeded at 10 events/block").toEqual(Some(10.))

    // Second batch: (300 - 100) events over (20 - 10) blocks = 20 events/block.
    // EMA: (old=10 + new=20) / 2 = 15.
    cs->ChainState.applyBatchProgress(
      ~batch=makeBatch(~progressBlockNumber=20, ~totalEventsProcessed=300., ~fetchState),
      ~blockTimestampName="timestamp",
    )
    t.expect(cs->ChainState.chainDensity).toEqual(Some(15.))
  })
})
