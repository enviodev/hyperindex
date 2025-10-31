open Belt

let allChainsEventsProcessedToEndblock = (chainFetchers: ChainMap.t<ChainFetcher.t>) => {
  chainFetchers
  ->ChainMap.values
  ->Array.every(cf => cf->ChainFetcher.hasProcessedToEndblock)
}

let computeChainsState = (chainFetchers: ChainMap.t<ChainFetcher.t>): Internal.chains => {
  let chains = Js.Dict.empty()

  chainFetchers
  ->ChainMap.entries
  ->Array.forEach(((chain, chainFetcher)) => {
    let chainId = chain->ChainMap.Chain.toChainId->Int.toString
    let isReady = chainFetcher.timestampCaughtUpToHeadOrEndblock !== None

    chains->Js.Dict.set(
      chainId,
      {
        Internal.isReady: isReady,
      },
    )
  })

  chains
}

let convertFieldsToJson = (fields: option<dict<unknown>>) => {
  switch fields {
  | None => %raw(`{}`)
  | Some(fields) => {
      let keys = fields->Js.Dict.keys
      let new = Js.Dict.empty()
      for i in 0 to keys->Js.Array2.length - 1 {
        let key = keys->Js.Array2.unsafe_get(i)
        let value = fields->Js.Dict.unsafeGet(key)
        // Skip `undefined` values and convert bigint fields to string
        // There are not fields with nested bigints, so this is safe
        new->Js.Dict.set(
          key,
          Js.typeof(value) === "bigint" ? value->Utils.magic->BigInt.toString->Utils.magic : value,
        )
      }
      new->(Utils.magic: dict<unknown> => Js.Json.t)
    }
  }
}

let addItemToRawEvents = (eventItem: Internal.eventItem, ~inMemoryStore: InMemoryStore.t) => {
  let {event, eventConfig, chain, blockNumber, timestamp: blockTimestamp} = eventItem
  let {block, transaction, params, logIndex, srcAddress} = event
  let chainId = chain->ChainMap.Chain.toChainId
  let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
  let blockFields =
    block
    ->(Utils.magic: Internal.eventBlock => option<dict<unknown>>)
    ->convertFieldsToJson
  let transactionFields =
    transaction
    ->(Utils.magic: Internal.eventTransaction => option<dict<unknown>>)
    ->convertFieldsToJson

  blockFields->Types.Block.cleanUpRawEventFieldsInPlace

  // Serialize to unknown, because serializing to Js.Json.t fails for Bytes Fuel type, since it has unknown schema
  let params =
    params
    ->S.reverseConvertOrThrow(eventConfig.paramsRawEventSchema)
    ->(Utils.magic: unknown => Js.Json.t)
  let params = if params === %raw(`null`) {
    // Should probably make the params field nullable
    // But this is currently needed to make events
    // with empty params work
    %raw(`"null"`)
  } else {
    params
  }

  let rawEvent: InternalTable.RawEvents.t = {
    chainId,
    eventId,
    eventName: eventConfig.name,
    contractName: eventConfig.contractName,
    blockNumber,
    logIndex,
    srcAddress,
    blockHash: block->Types.Block.getId,
    blockTimestamp,
    blockFields,
    transactionFields,
    params,
  }

  let eventIdStr = eventId->BigInt.toString

  inMemoryStore.rawEvents->InMemoryTable.set({chainId, eventId: eventIdStr}, rawEvent)
}

exception ProcessingError({message: string, exn: exn, item: Internal.item})

let runEventHandlerOrThrow = async (
  item: Internal.item,
  ~checkpointId,
  ~handler,
  ~inMemoryStore,
  ~loadManager,
  ~persistence,
  ~shouldSaveHistory,
  ~shouldBenchmark,
  ~chains: Internal.chains,
) => {
  let eventItem = item->Internal.castUnsafeEventItem

  //Include the load in time before handler
  let timeBeforeHandler = Hrtime.makeTimer()

  try {
    let contextParams: UserContext.contextParams = {
      item,
      checkpointId,
      inMemoryStore,
      loadManager,
      persistence,
      shouldSaveHistory,
      isPreload: false,
      chains,
      isResolved: false,
    }
    await handler(
      (
        {
          event: eventItem.event,
          context: UserContext.getHandlerContext(contextParams),
        }: Internal.handlerArgs
      ),
    )
    contextParams.isResolved = true
  } catch {
  | exn =>
    raise(
      ProcessingError({
        message: "Unexpected error in the event handler. Please handle the error to keep the indexer running smoothly.",
        item,
        exn,
      }),
    )
  }
  if shouldBenchmark {
    let timeEnd = timeBeforeHandler->Hrtime.timeSince->Hrtime.toMillis->Hrtime.floatFromMillis
    Benchmark.addSummaryData(
      ~group="Handlers Per Event",
      ~label=`${eventItem.eventConfig.contractName} ${eventItem.eventConfig.name} Handler (ms)`,
      ~value=timeEnd,
      ~decimalPlaces=4,
    )
  }
}

let runHandlerOrThrow = async (
  item: Internal.item,
  ~checkpointId,
  ~inMemoryStore,
  ~loadManager,
  ~indexer: Indexer.t,
  ~shouldSaveHistory,
  ~shouldBenchmark,
  ~chains: Internal.chains,
) => {
  switch item {
  | Block({onBlockConfig: {handler, chainId}, blockNumber}) =>
    try {
      let contextParams: UserContext.contextParams = {
        item,
        inMemoryStore,
        loadManager,
        persistence: indexer.persistence,
        shouldSaveHistory,
        checkpointId,
        isPreload: false,
        chains,
        isResolved: false,
      }
      await handler(
        (
          {
            block: {
              number: blockNumber,
              chainId,
            },
            context: UserContext.getHandlerContext(contextParams),
          }: Internal.onBlockArgs
        ),
      )
      contextParams.isResolved = true
    } catch {
    | exn =>
      raise(
        ProcessingError({
          message: "Unexpected error in the block handler. Please handle the error to keep the indexer running smoothly.",
          item,
          exn,
        }),
      )
    }
  | Event({eventConfig}) => {
      switch eventConfig.handler {
      | Some(handler) =>
        await item->runEventHandlerOrThrow(
          ~handler,
          ~checkpointId,
          ~inMemoryStore,
          ~loadManager,
          ~persistence=indexer.persistence,
          ~shouldSaveHistory,
          ~shouldBenchmark,
          ~chains,
        )
      | None => ()
      }

      if indexer.config.enableRawEvents {
        item->Internal.castUnsafeEventItem->addItemToRawEvents(~inMemoryStore)
      }
    }
  }
}

let preloadBatchOrThrow = async (
  batch: Batch.t,
  ~loadManager,
  ~persistence,
  ~inMemoryStore,
  ~chains: Internal.chains,
) => {
  // On the first run of loaders, we don't care about the result,
  // whether it's an error or a return type.
  // We'll rerun the loader again right before the handler run,
  // to avoid having a stale data returned from the loader.

  let promises = []
  let itemIdx = ref(0)

  for checkpointIdx in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Js.Array2.unsafe_get(checkpointIdx)
    let checkpointEventsProcessed =
      batch.checkpointEventsProcessed->Js.Array2.unsafe_get(checkpointIdx)

    for idx in 0 to checkpointEventsProcessed - 1 {
      let item = batch.items->Js.Array2.unsafe_get(itemIdx.contents + idx)
      switch item {
      | Event({eventConfig: {handler}, event}) =>
        switch handler {
        | None => ()
        | Some(handler) =>
          try {
            promises->Array.push(
              handler({
                event,
                context: UserContext.getHandlerContext({
                  item,
                  inMemoryStore,
                  loadManager,
                  persistence,
                  checkpointId,
                  isPreload: true,
                  shouldSaveHistory: false,
                  chains,
                  isResolved: false,
                }),
              })->Promise.silentCatch,
              // Must have Promise.catch as well as normal catch,
              // because if user throws an error before await in the handler,
              // it won't create a rejected promise
            )
          } catch {
          | _ => ()
          }
        }
      | Block({onBlockConfig: {handler, chainId}, blockNumber}) =>
        try {
          promises->Array.push(
            handler({
              block: {
                number: blockNumber,
                chainId,
              },
              context: UserContext.getHandlerContext({
                item,
                inMemoryStore,
                loadManager,
                persistence,
                checkpointId,
                isPreload: true,
                shouldSaveHistory: false,
                chains,
                isResolved: false,
              }),
            })->Promise.silentCatch,
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
  ~inMemoryStore,
  ~loadManager,
  ~indexer,
  ~shouldSaveHistory,
  ~shouldBenchmark,
  ~chains: Internal.chains,
) => {
  let itemIdx = ref(0)

  for checkpointIdx in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Js.Array2.unsafe_get(checkpointIdx)
    let checkpointEventsProcessed =
      batch.checkpointEventsProcessed->Js.Array2.unsafe_get(checkpointIdx)

    for idx in 0 to checkpointEventsProcessed - 1 {
      let item = batch.items->Js.Array2.unsafe_get(itemIdx.contents + idx)

      await runHandlerOrThrow(
        item,
        ~checkpointId,
        ~inMemoryStore,
        ~loadManager,
        ~indexer,
        ~shouldSaveHistory,
        ~shouldBenchmark,
        ~chains,
      )
    }
    itemIdx := itemIdx.contents + checkpointEventsProcessed
  }
}

let registerProcessEventBatchMetrics = (
  ~logger,
  ~loadDuration,
  ~handlerDuration,
  ~dbWriteDuration,
) => {
  logger->Logging.childTrace({
    "msg": "Finished processing batch",
    "loader_time_elapsed": loadDuration,
    "handlers_time_elapsed": handlerDuration,
    "write_time_elapsed": dbWriteDuration,
  })

  Prometheus.incrementLoadEntityDurationCounter(~duration=loadDuration)
  Prometheus.incrementEventRouterDurationCounter(~duration=handlerDuration)
  Prometheus.incrementExecuteBatchDurationCounter(~duration=dbWriteDuration)
}

type logPartitionInfo = {
  batchSize: int,
  firstItemTimestamp: option<int>,
  firstItemBlockNumber?: int,
  lastItemBlockNumber?: int,
}

let processEventBatch = async (
  ~batch: Batch.t,
  ~inMemoryStore: InMemoryStore.t,
  ~isInReorgThreshold,
  ~loadManager,
  ~indexer: Indexer.t,
  ~chainFetchers: ChainMap.t<ChainFetcher.t>,
) => {
  let totalBatchSize = batch.totalBatchSize
  // Compute chains state for this batch
  let chains: Internal.chains = chainFetchers->computeChainsState

  let logger = Logging.getLogger()
  logger->Logging.childTrace({
    "msg": "Started processing batch",
    "totalBatchSize": totalBatchSize,
    "chains": batch.progressedChainsById->Utils.Dict.mapValues(chainAfterBatch => {
      {
        "batchSize": chainAfterBatch.batchSize,
        "progress": chainAfterBatch.progressBlockNumber,
      }
    }),
  })

  try {
    let timeRef = Hrtime.makeTimer()

    if batch.items->Utils.Array.notEmpty {
      await batch->preloadBatchOrThrow(
        ~loadManager,
        ~persistence=indexer.persistence,
        ~inMemoryStore,
        ~chains,
      )
    }

    let elapsedTimeAfterLoaders = timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    if batch.items->Utils.Array.notEmpty {
      await batch->runBatchHandlersOrThrow(
        ~inMemoryStore,
        ~loadManager,
        ~indexer,
        ~shouldSaveHistory=indexer.config->Config.shouldSaveHistory(~isInReorgThreshold),
        ~shouldBenchmark=Env.Benchmark.shouldSaveData,
        ~chains,
      )
    }

    let elapsedTimeAfterProcessing =
      timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    let rec executeBatch = async (~escapeTables=?) => {
      switch await indexer.persistence.sql->IO.executeBatch(
        ~batch,
        ~inMemoryStore,
        ~isInReorgThreshold,
        ~indexer,
        ~escapeTables?,
      ) {
      | exception Persistence.StorageError({message, reason}) =>
        reason->ErrorHandling.make(~msg=message, ~logger)->Error

      | exception PgStorage.PgEncodingError({table}) =>
        let escapeTables = switch escapeTables {
        | Some(set) => set
        | None => Utils.Set.make()
        }
        let _ = escapeTables->Utils.Set.add(table)
        // Retry with specifying which tables to escape.
        await executeBatch(~escapeTables)
      | exception exn =>
        exn->ErrorHandling.make(~msg="Failed writing batch to database", ~logger)->Error
      | () => {
          let elapsedTimeAfterDbWrite =
            timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis
          let loaderDuration = elapsedTimeAfterLoaders
          let handlerDuration = elapsedTimeAfterProcessing - loaderDuration
          let dbWriteDuration = elapsedTimeAfterDbWrite - elapsedTimeAfterProcessing
          registerProcessEventBatchMetrics(
            ~logger,
            ~loadDuration=loaderDuration,
            ~handlerDuration,
            ~dbWriteDuration,
          )
          if Env.Benchmark.shouldSaveData {
            Benchmark.addEventProcessing(
              ~batchSize=totalBatchSize,
              ~loadDuration=loaderDuration,
              ~handlerDuration,
              ~dbWriteDuration,
              ~totalTimeElapsed=elapsedTimeAfterDbWrite,
            )
          }
          Ok()
        }
      }
    }

    await executeBatch()
  } catch {
  | ProcessingError({message, exn, item}) =>
    exn
    ->ErrorHandling.make(~msg=message, ~logger=item->Logging.getItemLogger)
    ->Error
  }
}
