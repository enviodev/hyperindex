let allChainsEventsProcessedToEndblock = (chainStates: dict<ChainState.t>) => {
  chainStates
  ->Dict.valuesToArray
  ->Array.every(cs => cs->ChainState.hasProcessedToEndblock)
}

exception ProcessingError({message: string, exn: exn, item: Internal.item})

// An event registered only for its contract register has no handler to run.
let hasHandler = (item: Internal.item) =>
  switch item {
  | Block(_) => true
  | Event(_) => (item->Internal.castUnsafeEventItem).onEventRegistration.handler !== None
  }

let invokeHandler = (runtime: HandlerRuntime.t, item: Internal.item) => {
  let context = runtime.handlerContext
  let ecosystem = runtime->HandlerRuntime.ecosystem
  switch item {
  | Block({onBlockRegistration: {handler}, blockNumber, ?block}) =>
    handler(Ecosystem.makeOnBlockArgs(~blockNumber, ~block, ~ecosystem, ~context))
  | Event(_) =>
    let handler = (item->Internal.castUnsafeEventItem).onEventRegistration.handler->Option.getUnsafe
    handler({event: item->Ecosystem.getItemEvent(~ecosystem), context})
  }
}

let handlerScope = (
  runtime: HandlerRuntime.t,
  ~item,
  ~checkpointId,
  ~isPreload,
) => RunScope.Handler({
  item,
  checkpointId,
  isPreload,
  isResolved: false,
  chainLogger: runtime->HandlerRuntime.chainLoggerFor(item),
  ecosystem: runtime->HandlerRuntime.ecosystem,
})

let eventStat = (runtime: HandlerRuntime.t, item: Internal.item) =>
  switch item {
  | Event(_) =>
    Some(
      runtime.params.indexerState->IndexerState.handlerStatFor(
        (item->Internal.castUnsafeEventItem).onEventRegistration.eventConfig,
      ),
    )
  | Block(_) => None
  }

let handlerErrorMessage = (item: Internal.item) =>
  `Unexpected error in the ${switch item {
    | Block(_) => "block"
    | Event(_) => "event"
    }} handler. Please handle the error to keep the indexer running smoothly.`

let runHandlerOrThrow = async (item: Internal.item, ~checkpointId, ~runtime) =>
  if item->hasHandler {
    //Include the load in time before handler
    let timeBeforeHandler = Performance.now()
    let scope = runtime->handlerScope(~item, ~checkpointId, ~isPreload=false)
    switch await RunScope.enter(scope, invokeHandler, runtime, item) {
    | exception exn =>
      scope->RunScope.resolve
      throw(ProcessingError({message: item->handlerErrorMessage, item, exn}))
    | () =>
      scope->RunScope.resolve
      switch runtime->eventStat(item) {
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
let preload = async (runtime, ~item, ~checkpointId) => {
  let scope = runtime->handlerScope(~item, ~checkpointId, ~isPreload=true)
  switch runtime->eventStat(item) {
  | Some(stat) =>
    let timerRef = stat->IndexerState.startPreloadHandler
    try await RunScope.enter(scope, invokeHandler, runtime, item) catch {
    | _ => ()
    }
    scope->RunScope.resolve
    stat->IndexerState.endPreloadHandler(timerRef)
  | None =>
    try await RunScope.enter(scope, invokeHandler, runtime, item) catch {
    | _ => ()
    }
    scope->RunScope.resolve
  }
}

let preloadBatchOrThrow = async (batch: Batch.t, ~runtime) => {
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
        promises->Array.push(runtime->preload(~item, ~checkpointId))
      }
    }

    itemIdx := itemIdx.contents + checkpointItemsCount
  }

  let _ = await Promise.all(promises)
}

let runBatchHandlersOrThrow = async (batch: Batch.t, ~runtime) => {
  let itemIdx = ref(0)
  let lookahead = PreloadLookahead.active.contents
  // Settled before the batch ends: one finishing after a rollback would put a
  // value read before it back into memory.
  let lookaheadPreloads = []
  // Only read by the lookahead, which preloads items out of checkpoint order.
  let checkpointIdOf = switch lookahead {
  | Some(_) =>
    let ids = []
    batch.checkpointIds->Array.forEachWithIndex((checkpointId, checkpointIdx) => {
      for _ in 1 to batch.checkpointItemsCount->Array.getUnsafe(checkpointIdx) {
        ids->Array.push(checkpointId)
      }
    })
    ids
  | None => []
  }

  for checkpointIdx in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Array.getUnsafe(checkpointIdx)
    let checkpointItemsCount = batch.checkpointItemsCount->Array.getUnsafe(checkpointIdx)

    for idx in 0 to checkpointItemsCount - 1 {
      let index = itemIdx.contents + idx
      let item = batch.items->Array.getUnsafe(index)
      await runHandlerOrThrow(item, ~checkpointId, ~runtime)

      switch lookahead {
      | Some(lookahead) =>
        lookahead->PreloadLookahead.afterItem(~index, ~preload=(ahead, aheadIdx) =>
          if ahead->hasHandler {
            lookaheadPreloads
            ->Array.push(
              runtime->preload(
                ~item=ahead,
                ~checkpointId=checkpointIdOf->Array.getUnsafe(aheadIdx),
              ),
            )
            ->ignore
          }
        )
      | None => ()
      }
    }
    itemIdx := itemIdx.contents + checkpointItemsCount
  }
  let _ = await Promise.all(lookaheadPreloads)
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

let processEventBatch = async (~batch: Batch.t, ~runtime: HandlerRuntime.t) => {
  let indexerState = runtime.params.indexerState
  let chainStates = indexerState->IndexerState.chainStates
  runtime->HandlerRuntime.refreshChains

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

    if batch.items->Utils.Array.notEmpty {
      // Materialise store-backed transactions onto payloads before any handler
      // (preload or execute) reads them.
      await materializeBatchEvents(batch, ~chainStates)
      PreloadLookahead.start(~items=batch.items)
      await batch->preloadBatchOrThrow(~runtime)
    }

    let elapsedTimeAfterLoaders = timeRef->Performance.secondsSince

    if batch.items->Utils.Array.notEmpty {
      await batch->runBatchHandlersOrThrow(~runtime)
    }
    PreloadLookahead.stop()

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
