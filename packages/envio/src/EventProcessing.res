let allChainsEventsProcessedToEndblock = (chainStates: dict<ChainState.t>) => {
  chainStates
  ->Dict.valuesToArray
  ->Array.every(cs => cs->ChainState.hasProcessedToEndblock)
}

let computeChainsState = (chainStates: dict<ChainState.t>): Internal.chains => {
  let chains = Dict.make()

  let values = chainStates->Dict.valuesToArray
  let isRealtime = values->Array.every(cs => cs->ChainState.isReady)

  values->Array.forEach(cs => {
    let chainId = (cs->ChainState.chainConfig).id
    chains->Dict.set(
      chainId->Int.toString,
      {
        Internal.id: chainId,
        isRealtime,
      },
    )
  })

  chains
}

exception ProcessingError({message: string, exn: exn, item: Internal.item})

let runEventHandlerOrThrow = async (
  item: Internal.item,
  ~checkpointId,
  ~handler,
  ~indexerState,
  ~loadManager,
  ~persistence,
  ~chains: Internal.chains,
  ~config: Config.t,
) => {
  let eventItem = item->Internal.castUnsafeEventItem

  //Include the load in time before handler
  let timeBeforeHandler = Performance.now()

  try {
    let contextParams: UserContext.contextParams = {
      item,
      checkpointId,
      indexerState,
      loadManager,
      persistence,
      isPreload: false,
      chains,
      config,
      isResolved: false,
    }
    await handler(
      (
        {
          event: item->Ecosystem.getItemEvent(~ecosystem=config.ecosystem),
          context: UserContext.getHandlerContext(contextParams),
        }: Internal.handlerArgs
      ),
    )
    contextParams.isResolved = true
  } catch {
  | exn =>
    throw(
      ProcessingError({
        message: "Unexpected error in the event handler. Please handle the error to keep the indexer running smoothly.",
        item,
        exn,
      }),
    )
  }
  let handlerDuration = timeBeforeHandler->Performance.secondsSince
  Prometheus.ProcessingHandler.increment(
    ~contract=eventItem.eventConfig.contractName,
    ~event=eventItem.eventConfig.name,
    ~duration=handlerDuration,
  )
}

let runHandlerOrThrow = async (
  item: Internal.item,
  ~checkpointId,
  ~indexerState,
  ~loadManager,
  ~persistence: Persistence.t,
  ~config: Config.t,
  ~chains: Internal.chains,
) => {
  switch item {
  | Block({onBlockConfig: {handler}, blockNumber}) =>
    try {
      let contextParams: UserContext.contextParams = {
        item,
        indexerState,
        loadManager,
        persistence,
        checkpointId,
        isPreload: false,
        chains,
        config,
        isResolved: false,
      }
      await handler(
        Ecosystem.makeOnBlockArgs(
          ~blockNumber,
          ~ecosystem=config.ecosystem,
          ~context=UserContext.getHandlerContext(contextParams),
        ),
      )
      contextParams.isResolved = true
    } catch {
    | exn =>
      throw(
        ProcessingError({
          message: "Unexpected error in the block handler. Please handle the error to keep the indexer running smoothly.",
          item,
          exn,
        }),
      )
    }
  | Event({eventConfig}) =>
    switch eventConfig.handler {
    | Some(handler) =>
      await item->runEventHandlerOrThrow(
        ~handler,
        ~checkpointId,
        ~indexerState,
        ~loadManager,
        ~persistence,
        ~chains,
        ~config,
      )
    | None => ()
    }
  }
}

let preloadBatchOrThrow = async (
  batch: Batch.t,
  ~loadManager,
  ~persistence,
  ~config: Config.t,
  ~indexerState,
  ~chains: Internal.chains,
) => {
  // On the first run of loaders, we don't care about the result,
  // whether it's an error or a return type.
  // We'll rerun the loader again right before the handler run,
  // to avoid having a stale data returned from the loader.

  let promises = []
  let itemIdx = ref(0)

  for checkpointIdx in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Array.getUnsafe(checkpointIdx)
    let checkpointEventsProcessed = batch.checkpointEventsProcessed->Array.getUnsafe(checkpointIdx)

    for idx in 0 to checkpointEventsProcessed - 1 {
      let item = batch.items->Array.getUnsafe(itemIdx.contents + idx)
      switch item {
      | Event({eventConfig: {handler, contractName, name: eventName}}) =>
        switch handler {
        | None => ()
        | Some(handler) =>
          try {
            let timerRef = Prometheus.PreloadHandler.startOperation(
              ~contract=contractName,
              ~event=eventName,
            )
            promises->Array.push(
              handler({
                event: item->Ecosystem.getItemEvent(~ecosystem=config.ecosystem),
                context: UserContext.getHandlerContext({
                  item,
                  indexerState,
                  loadManager,
                  persistence,
                  checkpointId,
                  isPreload: true,
                  chains,
                  isResolved: false,
                  config,
                }),
              })
              ->Promise.thenResolve(_ => {
                timerRef->Prometheus.PreloadHandler.endOperation(
                  ~contract=contractName,
                  ~event=eventName,
                )
              })
              ->Utils.Promise.silentCatch,
              // Must have Promise.catch as well as normal catch,
              // because if user throws an error before await in the handler,
              // it won't create a rejected promise
            )
          } catch {
          | _ => ()
          }
        }
      | Block({onBlockConfig: {handler}, blockNumber}) =>
        try {
          promises->Array.push(
            handler({
              Ecosystem.makeOnBlockArgs(
                ~blockNumber,
                ~ecosystem=config.ecosystem,
                ~context=UserContext.getHandlerContext({
                  item,
                  indexerState,
                  loadManager,
                  persistence,
                  checkpointId,
                  isPreload: true,
                  chains,
                  isResolved: false,
                  config,
                }),
              )
            })->Utils.Promise.silentCatch,
          )
        } catch {
        | _ => ()
        }
      }
    }

    itemIdx := itemIdx.contents + checkpointEventsProcessed
  }

  let _ = await Promise.all(promises)
}

let runBatchHandlersOrThrow = async (
  batch: Batch.t,
  ~indexerState,
  ~loadManager,
  ~persistence,
  ~config,
  ~chains: Internal.chains,
) => {
  let itemIdx = ref(0)

  for checkpointIdx in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Array.getUnsafe(checkpointIdx)
    let checkpointEventsProcessed = batch.checkpointEventsProcessed->Array.getUnsafe(checkpointIdx)

    for idx in 0 to checkpointEventsProcessed - 1 {
      let item = batch.items->Array.getUnsafe(itemIdx.contents + idx)

      await runHandlerOrThrow(
        item,
        ~checkpointId,
        ~indexerState,
        ~loadManager,
        ~persistence,
        ~config,
        ~chains,
      )
    }
    itemIdx := itemIdx.contents + checkpointEventsProcessed
  }
}

let registerProcessEventBatchMetrics = (
  ~logger,
  ~batch: Batch.t,
  ~loadDuration,
  ~handlerDuration,
) => {
  batch.progressedChainsById->Dict.forEachWithKey((chainAfterBatch, chainId) => {
    logger->Logging.childTrace({
      "msg": "Finished processing",
      "chainId": chainId->Int.fromString->Option.getUnsafe,
      "batchSize": chainAfterBatch.batchSize,
      "progress": chainAfterBatch.progressBlockNumber,
    })
  })

  Prometheus.ProcessingBatch.registerMetrics(~loadDuration, ~handlerDuration)
}

type logPartitionInfo = {
  batchSize: int,
  firstItemTimestamp: option<int>,
  firstItemBlockNumber?: int,
  lastItemBlockNumber?: int,
}

// Off the hot path: bulk-materialise the selected transaction fields for the
// batch's store-backed (HyperSync) items and write them onto the payloads, so
// handlers read plain objects. A batch can span chains, each with its own store
// and field mask, so group items by chain before materialising.
let materializeBatchTransactions = async (batch: Batch.t, ~chainStates: dict<ChainState.t>) => {
  let itemsByChain: dict<array<Internal.item>> = Dict.make()
  batch.items->Array.forEach(item => {
    let chainId = item->Internal.getItemChainId->Int.toString
    switch itemsByChain->Utils.Dict.dangerouslyGetNonOption(chainId) {
    | Some(items) => items->Array.push(item)
    | None => itemsByChain->Dict.set(chainId, [item])
    }
  })

  let _ = await itemsByChain
  ->Dict.toArray
  ->Array.map(async ((chainId, items)) => {
    let cs = chainStates->Dict.getUnsafe(chainId)
    await cs->ChainState.materializeBatchItems(~items)
  })
  ->Promise.all
}

let processEventBatch = async (
  ~batch: Batch.t,
  ~indexerState: IndexerState.t,
  ~loadManager,
  ~persistence: Persistence.t,
  ~config: Config.t,
  ~chainStates: dict<ChainState.t>,
) => {
  // Compute chains state for this batch
  let chains: Internal.chains = chainStates->computeChainsState

  let logger = Logging.getLogger()

  batch.progressedChainsById->Dict.forEachWithKey((chainAfterBatch, chainId) => {
    logger->Logging.childTrace({
      "msg": "Started processing",
      "chainId": chainId->Int.fromString->Option.getUnsafe,
      "batchSize": chainAfterBatch.batchSize,
    })
  })

  try {
    // Backpressure: keep processing within keepLatestChangesLimit of the cycle.
    await indexerState->Writing.awaitCapacity

    let timeRef = Performance.now()

    if batch.items->Utils.Array.notEmpty {
      // Materialise store-backed transactions onto payloads before any handler
      // (preload or execute) reads them.
      await materializeBatchTransactions(batch, ~chainStates)
      await batch->preloadBatchOrThrow(~loadManager, ~persistence, ~indexerState, ~chains, ~config)
    }

    let elapsedTimeAfterLoaders = timeRef->Performance.secondsSince

    if batch.items->Utils.Array.notEmpty {
      await batch->runBatchHandlersOrThrow(
        ~indexerState,
        ~loadManager,
        ~persistence,
        ~config,
        ~chains,
      )
    }

    let elapsedTimeAfterProcessing = timeRef->Performance.secondsSince

    indexerState->Writing.commitBatch(~batch)

    let loaderDuration = elapsedTimeAfterLoaders
    let handlerDuration = elapsedTimeAfterProcessing -. loaderDuration
    registerProcessEventBatchMetrics(
      ~logger,
      ~batch,
      ~loadDuration=loaderDuration,
      ~handlerDuration,
    )
    Ok()
  } catch {
  | Persistence.StorageError({message, reason}) =>
    reason->ErrorHandling.make(~msg=message, ~logger)->Error
  | ProcessingError({message, exn, item}) =>
    exn
    ->ErrorHandling.make(
      ~msg=message,
      ~logger=Ecosystem.getItemLogger(item, ~ecosystem=config.ecosystem),
    )
    ->Error
  | exn => exn->ErrorHandling.make(~msg="Failed processing batch", ~logger)->Error
  }
}
