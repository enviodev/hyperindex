open Vitest

let chainId = 1->ChainId.fromInt
let baseChainConfig = {
  ...TestConfig.default.chainMap->ChainMap.values->Utils.Array.firstUnsafe,
  id: chainId,
}

// A registrations map with an onBlock config (no address partition) so
// FetchState.make has something to index without needing real event configs.
let registrationsByChainId: HandlerRegister.registrationsByChainId = {
  let d = Dict.make()
  d->Dict.set(
    chainId->ChainId.toString,
    (
      {
        onEventRegistrations: [],
        onBlockRegistrations: [
          {
            Internal.index: 0,
            name: "chain-density-test",
            chainId,
            startBlock: None,
            endBlock: None,
            interval: 1,
            handler: "mock onBlock handler"->(
              Utils.magic: string => Internal.onBlockArgs => promise<unit>
            ),
          },
        ],
      }: HandlerRegister.chainRegistrations
    ),
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
  addressRows: AddressRows.emptySeedRows(),
  sourceBlockNumber: 1000,
}

let makeChainState = (
  resumedChainState,
  ~reorgCheckpoints=[],
  ~config=TestConfig.default,
  ~isInReorgThreshold=false,
) =>
  ChainState.makeFromDbState(
    baseChainConfig,
    ~resumedChainState,
    ~reorgCheckpoints,
    ~isInReorgThreshold,
    ~isRealtime=false,
    ~config,
    ~contractMapping=config.contractMapping,
    ~registrationsByChainId,
  )

let resumed = (~maxReorgDepth) => {
  ...makeResumedChainState(
    ~progressBlockNumber=110,
    ~numEventsProcessed=0.,
    ~firstEventBlockNumber=None,
  ),
  maxReorgDepth,
}

describe("ChainState history reachability", () => {
  // A chain keeps history only for what a rollback could still reach: inside
  // its reorg threshold, with a reorg depth to be rolled back through, on a run
  // that rolls back at all.
  it("Keeps history only inside the threshold, and never without a reorg depth", t => {
    let inThreshold = makeChainState(resumed(~maxReorgDepth=200), ~isInReorgThreshold=true)
    let belowThreshold = makeChainState(resumed(~maxReorgDepth=200))
    let noDepth = makeChainState(resumed(~maxReorgDepth=0), ~isInReorgThreshold=true)
    t.expect((
      inThreshold->ChainState.keepsHistory,
      belowThreshold->ChainState.keepsHistory,
      noDepth->ChainState.keepsHistory,
    )).toEqual((true, false, false))
  })

  // Entering the threshold is what turns history on — but a chain no rollback
  // can reach stays where it is.
  it("Leaves a chain no rollback can reach alone when the threshold is entered", t => {
    let noDepth = makeChainState(resumed(~maxReorgDepth=0))
    let noRollback = makeChainState(
      resumed(~maxReorgDepth=200),
      ~config={...TestConfig.default, shouldRollbackOnReorg: false},
    )
    let entering = makeChainState(resumed(~maxReorgDepth=200))
    [noDepth, noRollback, entering]->Array.forEach(ChainState.enterReorgThreshold)
    t.expect((
      noDepth->ChainState.keepsHistory,
      noRollback->ChainState.keepsHistory,
      entering->ChainState.keepsHistory,
    )).toEqual((false, false, true))
  })
})

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
      makeResumedChainState(
        ~progressBlockNumber=-1,
        ~numEventsProcessed=0.,
        ~firstEventBlockNumber=None,
      ),
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
      ~addressStore=TestAddresses.makeStore(),
      ~addressRows=AddressRows.emptySeedRows(),
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
      d->ChainId.Dict.set(
        chainId,
        (
          {
            batchSize: 0,
            progressBlockNumber,
            sourceBlockNumber: 1000,
            totalEventsProcessed,
            fetchState,
            isProgressAtHeadWhenBatchCreated: false,
          }: Batch.chainAfterBatch
        ),
      )
      d
    },
    history: Shared(Skip),
    checkpointFrontier: Frontier.empty(),
    checkpointIds: [],
    checkpointChainIds: [],
    checkpointBlockNumbers: [],
    checkpointBlockHashes: [],
    checkpointEventsProcessed: [],
    registeredAddresses: [],
  }

  it("seeds density from the first batch's own events/block (no prior density to blend)", t => {
    let cs = makeChainState(
      makeResumedChainState(
        ~progressBlockNumber=0,
        ~numEventsProcessed=0.,
        ~firstEventBlockNumber=None,
      ),
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
      makeResumedChainState(
        ~progressBlockNumber=0,
        ~numEventsProcessed=0.,
        ~firstEventBlockNumber=None,
      ),
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
      makeResumedChainState(
        ~progressBlockNumber=0,
        ~numEventsProcessed=0.,
        ~firstEventBlockNumber=None,
      ),
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
