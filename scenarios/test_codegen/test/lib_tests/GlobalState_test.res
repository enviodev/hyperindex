open Vitest

let makeState = () => {
  let config = Config.loadWithoutRegistrations()

  let chainFetchers = config.chainMap->ChainMap.map(chainConfig => {
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
    let chainFetcher: ChainFetcher.t = {
      timestampCaughtUpToHeadOrEndblock: None,
      committedProgressBlockNumber: -1,
      numEventsProcessed: 0.,
      fetchState,
      logger: Logging.getLogger(),
      sourceManager: SourceManager.make(
        ~sources=[mockSource.source],
        ~maxPartitionConcurrency=Env.maxPartitionConcurrency,
        ~isRealtime=false,
      ),
      chainConfig,
      reorgDetection: ReorgDetection.make(
        ~chainReorgCheckpoints=[],
        ~maxReorgDepth=200,
        ~shouldRollbackOnReorg=false,
      ),
      safeCheckpointTracking: None,
      isProgressAtHead: false,
    }
    chainFetcher
  })

  let ctx: Ctx.t = {
    registrations: {onBlockByChainId: Dict.make()},
    config,
    persistence: MockIndexer.defaultPersistence,
    inMemoryStore: MockIndexer.InMemoryStore.make(),
  }

  GlobalState.make(
    ~ctx,
    ~chainManager={
      chainFetchers,
      isInReorgThreshold: false,
      isRealtime: false,
    },
    ~onError=errHandler => errHandler->ErrorHandling.raiseExn,
  )
}

describe("GlobalState scheduling", () => {
  Async.it("schedule discards work after a state id bump", async t => {
    let state = makeState()
    let runs = []

    state->GlobalState.schedule(async (~stateId) => runs->Array.push(stateId))
    state.id = state.id + 1
    state->GlobalState.schedule(async (~stateId) => runs->Array.push(stateId))

    await Utils.delay(1)

    t.expect(runs, ~message="Only the schedule after the bump should run").toEqual([1])
  })

  Async.it(
    "stale eventBatchProcessed during rollback prep releases the processing flag and continues rollback",
    async t => {
      let state = makeState()
      let inMemoryStore = state.ctx.inMemoryStore
      inMemoryStore.isProcessing = true

      let batch =
        state.chainManager->ChainManager.createBatch(
          ~processedCheckpointId=inMemoryStore.processedCheckpointId,
          ~batchSizeTarget=state.ctx.config.batchSize,
          ~isRollback=false,
        )

      let staleId = state.id
      state.id = state.id + 1
      // The scheduled rollback continuation is a no-op in this phase,
      // so the test can observe the flag release in isolation.
      state.rollbackState = FindingReorgDepth

      state->GlobalState.eventBatchProcessed(~batch, ~stateId=staleId)
      await Utils.delay(1)

      t.expect(
        {
          "isProcessing": inMemoryStore.isProcessing,
          "processedBatchesCount": inMemoryStore.processedBatchesCount,
          "rollbackState": state.rollbackState,
        },
        ~message="A discarded batch result must still release the processing flag",
      ).toEqual({
        "isProcessing": false,
        "processedBatchesCount": 1,
        "rollbackState": GlobalState.FindingReorgDepth,
      })
    },
  )

  Async.it("stale eventBatchProcessed without a pending rollback only releases the flag", async t => {
    let state = makeState()
    let inMemoryStore = state.ctx.inMemoryStore
    inMemoryStore.isProcessing = true
    let chainManagerBefore = state.chainManager

    let batch =
      state.chainManager->ChainManager.createBatch(
        ~processedCheckpointId=inMemoryStore.processedCheckpointId,
        ~batchSizeTarget=state.ctx.config.batchSize,
        ~isRollback=false,
      )

    let staleId = state.id
    state.id = state.id + 1

    state->GlobalState.eventBatchProcessed(~batch, ~stateId=staleId)
    await Utils.delay(1)

    t.expect(
      {
        "isProcessing": inMemoryStore.isProcessing,
        "processedBatchesCount": inMemoryStore.processedBatchesCount,
        "chainManagerUntouched": state.chainManager === chainManagerBefore,
      },
      ~message="A fully discarded batch result must not advance any state besides the flag",
    ).toEqual({
      "isProcessing": false,
      "processedBatchesCount": 1,
      "chainManagerUntouched": true,
    })
  })
})
