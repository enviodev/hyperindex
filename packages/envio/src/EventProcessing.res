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

// What a pass shares across its handler runs: one context serves them all, and
// each run is told apart by the frame it's entered with.
type pass = {
  context: Internal.handlerContext,
  isPreload: bool,
  loggerFor: Internal.item => Logger.t,
  config: Config.t,
  indexerState: IndexerState.t,
  stats: Utils.Map.t<Internal.eventConfig, IndexerState.handlerStat>,
}

let makePass = (params: UserContext.batchParams) => {
  context: UserContext.makeHandlerContext(params),
  isPreload: params.isPreload,
  loggerFor: item => params.indexerState->IndexerState.loggerForItem(item),
  config: params.config,
  indexerState: params.indexerState,
  stats: Utils.Map.make(),
}

let handlerStatFor = (pass: pass, eventConfig: Internal.eventConfig) =>
  switch pass.stats->Utils.Map.get(eventConfig) {
  | Some(stat) => stat
  | None =>
    let stat =
      pass.indexerState->IndexerState.getHandlerStat(
        ~contract=eventConfig.contractName,
        ~event=eventConfig.name,
      )
    pass.stats->Utils.Map.set(eventConfig, stat)->ignore
    stat
  }

let makeFrame = (pass: pass, ~item, ~checkpointId): ConsoleScope.handlerFrame => {
  item,
  checkpointId,
  isPreload: pass.isPreload,
  isResolved: false,
  loggerFor: pass.loggerFor,
}

let invokeHandler = (pass: pass, item: Internal.item) =>
  switch item {
  | Block({onBlockRegistration: {handler}, blockNumber}) =>
    handler(
      Ecosystem.makeOnBlockArgs(
        ~blockNumber,
        ~ecosystem=pass.config.ecosystem,
        ~context=pass.context,
      ),
    )
  | Event(_) =>
    switch (item->Internal.castUnsafeEventItem).onEventRegistration.handler {
    | Some(handler) =>
      handler({
        event: item->Ecosystem.getItemEvent(~ecosystem=pass.config.ecosystem),
        context: pass.context,
      })
    | None => Promise.resolve()
    }
  }

// Throws whatever the handler throws, even before its first await.
let enterFrame = (pass: pass, frame: ConsoleScope.handlerFrame) =>
  ConsoleScope.run2(Handler(frame), invokeHandler, pass, frame.item)

let runHandlerOrThrow = async (item: Internal.item, ~checkpointId, ~pass) => {
  let frame = pass->makeFrame(~item, ~checkpointId)
  switch item {
  | Block(_) =>
    try {
      await pass->enterFrame(frame)
      frame.isResolved = true
    } catch {
    | exn =>
      frame.isResolved = true
      throw(
        ProcessingError({
          message: "Unexpected error in the block handler. Please handle the error to keep the indexer running smoothly.",
          item,
          exn,
        }),
      )
    }
  | Event(_) =>
    let {?handler, eventConfig} = (item->Internal.castUnsafeEventItem).onEventRegistration
    if handler !== None {
      //Include the load in time before handler
      let timeBeforeHandler = Performance.now()
      try {
        await pass->enterFrame(frame)
        frame.isResolved = true
      } catch {
      | exn =>
        frame.isResolved = true
        throw(
          ProcessingError({
            message: "Unexpected error in the event handler. Please handle the error to keep the indexer running smoothly.",
            item,
            exn,
          }),
        )
      }
      pass
      ->handlerStatFor(eventConfig)
      ->IndexerState.recordHandlerDuration(~duration=timeBeforeHandler->Performance.secondsSince)
    }
  }
}

// A preload run's errors are dropped: the run proper reports them.
let startPreload = (pass: pass, ~item, ~checkpointId, ~onResolved) => {
  let frame = pass->makeFrame(~item, ~checkpointId)
  let promise = try pass->enterFrame(frame) catch {
  | exn => Promise.reject(exn)
  }
  promise
  ->Promise.thenResolve(_ => {
    frame.isResolved = true
    onResolved()
  })
  ->Promise.catch(_ => {
    frame.isResolved = true
    Promise.resolve()
  })
}

let preloadBatchOrThrow = async (batch: Batch.t, ~pass) => {
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
      switch item {
      | Event(_) =>
        let {?handler, eventConfig} = (item->Internal.castUnsafeEventItem).onEventRegistration
        if handler !== None {
          let stat = pass->handlerStatFor(eventConfig)
          let timerRef = stat->IndexerState.startPreloadHandler
          promises->Array.push(
            pass->startPreload(~item, ~checkpointId, ~onResolved=() =>
              stat->IndexerState.endPreloadHandler(timerRef)
            ),
          )
        }
      | Block(_) =>
        promises->Array.push(pass->startPreload(~item, ~checkpointId, ~onResolved=() => ()))
      }
    }

    itemIdx := itemIdx.contents + checkpointItemsCount
  }

  let _ = await Promise.all(promises)
}

let runBatchHandlersOrThrow = async (batch: Batch.t, ~pass) => {
  let itemIdx = ref(0)

  for checkpointIdx in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Array.getUnsafe(checkpointIdx)
    let checkpointItemsCount = batch.checkpointItemsCount->Array.getUnsafe(checkpointIdx)

    for idx in 0 to checkpointItemsCount - 1 {
      let item = batch.items->Array.getUnsafe(itemIdx.contents + idx)
      await runHandlerOrThrow(item, ~checkpointId, ~pass)
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

    let makePass = isPreload =>
      makePass({indexerState, loadManager, persistence, isPreload, chains, config})

    if batch.items->Utils.Array.notEmpty {
      // Materialise store-backed transactions onto payloads before any handler
      // (preload or execute) reads them.
      await materializeBatchEvents(batch, ~chainStates)
      await batch->preloadBatchOrThrow(~pass=makePass(true))
    }

    let elapsedTimeAfterLoaders = timeRef->Performance.secondsSince

    if batch.items->Utils.Array.notEmpty {
      await batch->runBatchHandlersOrThrow(~pass=makePass(false))
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
