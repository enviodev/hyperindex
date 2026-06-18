open Vitest

let makeState = (~onError=errHandler => errHandler->ErrorHandling.raiseExn, ()) => {
  let config = Config.loadWithoutRegistrations()

  let chainStates = Dict.make()
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    let fetchState = FetchState.make(
      ~maxAddrInPartition=Env.maxAddrInPartition,
      ~endBlock=None,
      ~eventConfigs=[
        (MockIndexer.evmEventConfig(
          ~id="0",
          ~contractName="Gravatar",
          ~isWildcard=true,
        ) :> Internal.eventConfig),
      ],
      ~addresses=[],
      ~startBlock=0,
      ~targetBufferSize=5000,
      ~chainId=chainConfig.id,
      ~knownHeight=0,
    )
    let mockSource = MockIndexer.Source.make([], ~chain=#1)
    let chainState = ChainState.make(
      ~chainConfig,
      ~fetchState,
      ~sourceManager=SourceManager.make(
        ~sources=[mockSource.source],
        ~isRealtime=false,
      ),
      ~reorgDetection=ReorgDetection.make(
        ~chainReorgCheckpoints=[],
        ~maxReorgDepth=200,
        ~shouldRollbackOnReorg=false,
      ),
      ~committedProgressBlockNumber=-1,
      ~logger=Logging.getLogger(),
    )
    chainStates->Utils.Dict.setByInt(chainConfig.id, chainState)
  })

  IndexerState.make(
    ~config,
    ~persistence=MockIndexer.defaultPersistence,
    ~chainStates,
    // isInReorgThreshold avoids triggering a fetch on the mock source (which
    // implements no methods) when the processing loop runs to its empty exit.
    ~isInReorgThreshold=true,
    ~isRealtime=false,
    ~onError,
  )
}

describe("Indexer loop", () => {
  Async.it("launch runs work, then skips it once the state is stopped", async t => {
    let state = makeState()
    let runs = []

    state->IndexerLoop.launch(async () => runs->Array.push(1))
    state->IndexerState.stop
    state->IndexerLoop.launch(async () => runs->Array.push(2))

    t.expect(runs, ~message="A stopped state must not launch new work").toEqual([1])
  })

  Async.it("startProcessing releases the flag once there is no work", async t => {
    let state = makeState()

    await BatchProcessing.startProcessing(state, ~scheduleFetch=() => (), ~scheduleRollback=() => ())

    t.expect(
      state->IndexerState.isProcessing,
      ~message="An idle loop must release the processing flag on exit",
    ).toEqual(false)
  })

  Async.it("startProcessing is a no-op while a loop already owns the flag", async t => {
    let state = makeState()
    // Simulate an in-flight loop instance.
    state->IndexerState.beginProcessing

    await BatchProcessing.startProcessing(state, ~scheduleFetch=() => (), ~scheduleRollback=() => ())

    t.expect(
      state->IndexerState.isProcessing,
      ~message="A second instance must not steal or clear the existing loop's flag",
    ).toEqual(true)
  })

  Async.it("errorExit stops the state and reports through onError", async t => {
    let reportedErrors = ref(0)
    let state = makeState(~onError=_ => reportedErrors := reportedErrors.contents + 1, ())

    state->IndexerState.errorExit(ErrorHandling.make(Utils.Error.make("boom")))

    t.expect(
      {"isStopped": state->IndexerState.isStopped, "reportedErrors": reportedErrors.contents},
      ~message="errorExit must stop every loop and report exactly once",
    ).toEqual({"isStopped": true, "reportedErrors": 1})
  })
})
