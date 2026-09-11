open Vitest

// A chain added to a schema whose others were already synced is the one case
// where the indexer resumes with some chains ready and some not. The ready ones
// hold: the fetch pool belongs to the newcomer until it catches up.

let {TestConfig.config: config} = TestConfig.multiChain(~chains=[(1, "Gravatar"), (137, "Poster")])

let readyAt = Date.fromTime(1_700_000_000_000.)

// An onBlock registration per chain, so each has something to index without
// real event configs behind it.
let registrationsByChainId: HandlerRegister.registrationsByChainId = {
  let registrations = Dict.make()
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig =>
    registrations->Dict.set(
      chainConfig.id->ChainId.toString,
      (
        {
          onEventRegistrations: [],
          onBlockRegistrations: [
            {
              Internal.index: 0,
              name: "freeze-test",
              chainId: chainConfig.id,
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
  )
  registrations
}

// Chain 1 resumes synced to the head it last saw; chain 137 resumes as the
// migration left it, at its start block with no `ready_at`.
let makeChain = (~id, ~isReady): Persistence.initialChainState => {
  let chainId = id->ChainId.normalizeOrThrow
  let chainConfig = config.chainMap->ChainMap.get(config->Config.getChain(~chainId))
  {
    id: chainId,
    startBlock: 1,
    endBlock: None,
    maxReorgDepth: 200,
    progressBlockNumber: isReady ? 1000 : -1,
    numEventsProcessed: 0.,
    firstEventBlockNumber: None,
    timestampCaughtUpToHeadOrEndblock: isReady ? Some(readyAt) : None,
    addressRows: chainConfig
    ->ChainState.configStorageRows(~ecosystem=Evm, ~contractMapping=config.contractMapping)
    ->AddressRows.seedRowsOf,
    sourceBlockNumber: isReady ? 1000 : 0,
  }
}

let makeState = (~chains) => {
  let initialState: Persistence.initialState = {
    cleanRun: false,
    contractMapping: config.contractMapping,
    envioInfo: None,
    chains,
    cache: Dict.make(),
    reorgCheckpoints: [],
    checkpointFrontier: Frontier.empty(),
  }
  IndexerState.makeFromDbState(
    ~config,
    ~persistence=PgStorage.makePersistenceFromConfig(~config),
    ~initialState,
    ~registrationsByChainId,
    ~onError=_ => (),
  )
}

// Which chains a fetch tick would actually reach.
let dispatchedChains = async state => {
  let dispatched = []
  await state
  ->IndexerState.crossChainState
  ->CrossChainState.checkAndFetch(~dispatchChain=async (~chainId, ~action as _) => {
    dispatched->Array.push(chainId->ChainId.toString)->ignore
  })
  dispatched->Array.toSorted(String.compare)
}

describe("A chain added to an already-synced indexer", () => {
  Async.it("holds the ready chains and leaves the run below the reorg threshold", async t => {
    let state = makeState(
      ~chains=[makeChain(~id=1, ~isReady=true), makeChain(~id=137, ~isReady=false)],
    )

    t.expect({
      "isRealtime": state->IndexerState.isRealtime,
      // Chain 1 sits at its head, but counting it would put chain 137 in the
      // threshold from its first block and make it save history all the way.
      "isInReorgThreshold": state->IndexerState.isInReorgThreshold,
      "dispatched": await dispatchedChains(state),
    }).toEqual({
      "isRealtime": false,
      "isInReorgThreshold": false,
      "dispatched": ["137"],
    })
  })

  Async.it("releases them once every chain is stamped ready", async t => {
    let state = makeState(
      ~chains=[makeChain(~id=1, ~isReady=true), makeChain(~id=137, ~isReady=false)],
    )
    state->IndexerState.markReady(~readyAt)

    t.expect({
      "isRealtime": state->IndexerState.isRealtime,
      "dispatched": await dispatchedChains(state),
    }).toEqual({
      "isRealtime": true,
      "dispatched": ["1", "137"],
    })
  })

  Async.it("holds nothing when every chain resumes ready", async t => {
    let state = makeState(
      ~chains=[makeChain(~id=1, ~isReady=true), makeChain(~id=137, ~isReady=true)],
    )

    t.expect({
      "isRealtime": state->IndexerState.isRealtime,
      // Both chains sit within maxReorgDepth of the head they last saw, and with
      // nothing backfilling there is no reason to drop out of the threshold.
      "isInReorgThreshold": state->IndexerState.isInReorgThreshold,
      "dispatched": await dispatchedChains(state),
    }).toEqual({
      "isRealtime": true,
      "isInReorgThreshold": true,
      "dispatched": ["1", "137"],
    })
  })
})
