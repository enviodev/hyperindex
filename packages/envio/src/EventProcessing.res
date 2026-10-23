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
      chainId->ChainId.toString,
      {
        Internal.id: chainId,
        isRealtime,
      },
    )
  })

  chains
}

exception ProcessingError({message: string, exn: exn, item: Internal.item})

// What every handler run of an indexer shares: one context for both passes,
// each run told apart by the RunScope it's entered with. Built on the
// indexer's first batch, so a batch allocates no functions of its own.
type runner = {
  params: UserContext.params,
  invokeHandler: Internal.item => promise<unit>,
  loggerFor: Internal.item => Logger.t,
}

let runners: Utils.WeakMap.t<IndexerState.t, runner> = Utils.WeakMap.make()

let runnerFor = (indexerState, ~loadManager, ~persistence, ~config: Config.t, ~chains) =>
  switch runners->Utils.WeakMap.get(indexerState) {
  | Some(runner) =>
    runner.params.chains = chains
    runner
  | None =>
    let params: UserContext.params = {indexerState, loadManager, persistence, config, chains}
    let context = UserContext.makeHandlerContext(params)
    let ecosystem = config.ecosystem
    let runner = {
      params,
      invokeHandler: item =>
        switch item {
        | Block({onBlockRegistration: {handler}, blockNumber}) =>
          handler(Ecosystem.makeOnBlockArgs(~blockNumber, ~ecosystem, ~context))
        | Event(_) =>
          let handler =
            (item->Internal.castUnsafeEventItem).onEventRegistration.handler->Option.getUnsafe
          handler({event: item->Ecosystem.getItemEvent(~ecosystem), context})
        },
      loggerFor: item => indexerState->IndexerState.loggerForItem(item),
    }
    runners->Utils.WeakMap.set(indexerState, runner)->ignore
    runner
  }

// An event registered only for its contract register has no handler to run.
let hasHandler = (item: Internal.item) =>
  switch item {
  | Block(_) => true
  | Event(_) => (item->Internal.castUnsafeEventItem).onEventRegistration.handler !== None
  }

let eventStat = (runner: runner, item: Internal.item) =>
  switch item {
  | Event(_) =>
    Some(
      runner.params.indexerState->IndexerState.handlerStatFor(
        (item->Internal.castUnsafeEventItem).onEventRegistration.eventConfig,
      ),
    )
  | Block(_) => None
  }

let runOf = (runner: runner, ~kind, ~item, ~checkpointId) =>
  RunScope.run(~kind, ~item, ~checkpointId, ~loggerFor=runner.loggerFor, runner.invokeHandler, item)

let handlerErrorMessage = (item: Internal.item) =>
  `Unexpected error in the ${switch item {
    | Block(_) => "block"
    | Event(_) => "event"
    }} handler. Please handle the error to keep the indexer running smoothly.`

let runHandlerOrThrow = async (item: Internal.item, ~checkpointId, ~runner) =>
  if item->hasHandler {
    //Include the load in time before handler
    let timeBeforeHandler = Performance.now()
    switch await runner->runOf(~kind=Handler, ~item, ~checkpointId) {
    | exception exn => throw(ProcessingError({message: item->handlerErrorMessage, item, exn}))
    | () =>
      switch runner->eventStat(item) {
      | Some(stat) =>
        stat->IndexerState.recordHandlerDuration(
          ~duration=timeBeforeHandler->Performance.secondsSince,
        )
      | None => ()
      }
    }
  }

// A preload run's errors are dropped: the run proper reports them. It is still
// timed either way, so one that throws doesn't leave its handler's timing open.
let preload = async (runner, ~item, ~checkpointId) =>
  switch runner->eventStat(item) {
  | Some(stat) =>
    let timerRef = stat->IndexerState.startPreloadHandler
    try await runner->runOf(~kind=Preload, ~item, ~checkpointId) catch {
    | _ => ()
    }
    stat->IndexerState.endPreloadHandler(timerRef)
  | None =>
    try await runner->runOf(~kind=Preload, ~item, ~checkpointId) catch {
    | _ => ()
    }
  }

let preloadBatchOrThrow = async (batch: Batch.t, ~runner) => {
  // On the first run of loaders, we don't care about the result,
  // whether it's an error or a return type.
  // We'll rerun the loader again right before the handler run,
  // to avoid having a stale data returned from the loader.

  let promises = []
  let itemIdx = ref(0)

  for checkpointIdx in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Array.getUnsafe(checkpointIdx)
    let checkpointItemsCount = batch.checkpointItemsCount->Array.getUnsafe(checkpointIdx)

    for idx in 0 to checkpointItemsCount - 1 {
      let item = batch.items->Array.getUnsafe(itemIdx.contents + idx)
      if item->hasHandler {
        promises->Array.push(runner->preload(~item, ~checkpointId))
      }
    }

    itemIdx := itemIdx.contents + checkpointItemsCount
  }

  let _ = await Promise.all(promises)
}

let runBatchHandlersOrThrow = async (batch: Batch.t, ~runner) => {
  let itemIdx = ref(0)

  for checkpointIdx in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Array.getUnsafe(checkpointIdx)
    let checkpointItemsCount = batch.checkpointItemsCount->Array.getUnsafe(checkpointIdx)

    for idx in 0 to checkpointItemsCount - 1 {
      let item = batch.items->Array.getUnsafe(itemIdx.contents + idx)
      await runHandlerOrThrow(item, ~checkpointId, ~runner)
    }
    itemIdx := itemIdx.contents + checkpointItemsCount
  }
}

let registerProcessEventBatchMetrics = (
  ~logger,
  ~batch: Batch.t,
  ~indexerState,
  ~loadDuration,
  ~handlerDuration,
) => {
  batch.progressedChainsById->Dict.forEachWithKey((chainAfterBatch, chainId) => {
    logger->Logger.trace(
      "Finished processing",
      ~params={
        "chainId": chainId,
        "batchSize": chainAfterBatch.batchSize,
        "progress": chainAfterBatch.progressBlockNumber,
      },
    )
  })

  indexerState->IndexerState.recordBatchDurations(~loadDuration, ~handlerDuration)
}

type logPartitionInfo = {
  batchSize: int,
  firstItemTimestamp: option<int>,
  firstItemBlockNumber?: int,
  lastItemBlockNumber?: int,
}

// Off the hot path: bulk-materialise the selected transaction and block fields
// for the batch's store-backed (HyperSync) items and write them onto the
// payloads, so handlers read plain objects. A batch can span chains, each with
// its own stores and field masks, so group items by chain before materialising.
let materializeBatchEvents = async (batch: Batch.t, ~chainStates: dict<ChainState.t>) => {
  switch chainStates->Dict.valuesToArray {
  // Single-chain indexers (the common case): every item belongs to the one
  // chain, so skip the per-chain grouping and its allocations.
  | [cs] => await cs->ChainState.materializeBatchItems(~items=batch.items)
  | _ =>
    let itemsByChain: dict<array<Internal.item>> = Dict.make()
    batch.items->Array.forEach(item => {
      let chainId = item->Internal.getItemChainId->ChainId.toString
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

  let logger = indexerState->IndexerState.logger

  batch.progressedChainsById->Dict.forEachWithKey((chainAfterBatch, chainId) => {
    logger->Logger.trace(
      "Started processing",
      ~params={"chainId": chainId, "batchSize": chainAfterBatch.batchSize},
    )
  })

  try {
    // Backpressure: keep processing within keepLatestChangesLimit of the cycle.
    await indexerState->Writing.awaitCapacity

    let timeRef = Performance.now()

    let runner = runnerFor(indexerState, ~loadManager, ~persistence, ~config, ~chains)

    if batch.items->Utils.Array.notEmpty {
      // Materialise store-backed transactions onto payloads before any handler
      // (preload or execute) reads them.
      await materializeBatchEvents(batch, ~chainStates)
      await batch->preloadBatchOrThrow(~runner)
    }

    let elapsedTimeAfterLoaders = timeRef->Performance.secondsSince

    if batch.items->Utils.Array.notEmpty {
      await batch->runBatchHandlersOrThrow(~runner)
    }

    let elapsedTimeAfterProcessing = timeRef->Performance.secondsSince

    indexerState->Writing.commitBatch(~batch)

    let loaderDuration = elapsedTimeAfterLoaders
    let handlerDuration = elapsedTimeAfterProcessing -. loaderDuration
    registerProcessEventBatchMetrics(
      ~logger,
      ~batch,
      ~indexerState,
      ~loadDuration=loaderDuration,
      ~handlerDuration,
    )
    Ok()
  } catch {
  | Persistence.StorageError({message, reason}) =>
    reason->ErrorHandling.make(~msg=message, ~logger)->Error
  | ProcessingError({message, exn, item}) =>
    exn
    ->ErrorHandling.make(~msg=message, ~logger=indexerState->IndexerState.loggerForItem(item))
    ->Error
  | exn => exn->ErrorHandling.make(~msg="Failed processing batch", ~logger)->Error
  }
}
