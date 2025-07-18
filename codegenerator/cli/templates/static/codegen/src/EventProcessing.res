open Belt

let allChainsEventsProcessedToEndblock = (chainFetchers: ChainMap.t<ChainFetcher.t>) => {
  chainFetchers
  ->ChainMap.values
  ->Array.every(cf => cf->ChainFetcher.hasProcessedToEndblock)
}

let updateEventSyncState = (eventItem: Internal.eventItem, ~inMemoryStore: InMemoryStore.t) => {
  let {event, chain, blockNumber, timestamp: blockTimestamp} = eventItem
  let {logIndex} = event
  let chainId = chain->ChainMap.Chain.toChainId
  let _ = inMemoryStore.eventSyncState->InMemoryTable.set(
    chainId,
    {
      chainId,
      blockTimestamp,
      blockNumber,
      logIndex,
    },
  )
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

let addEventToRawEvents = (eventItem: Internal.eventItem, ~inMemoryStore: InMemoryStore.t) => {
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

  let rawEvent: TablesStatic.RawEvents.t = {
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

exception ProcessingError({message: string, exn: exn, eventItem: Internal.eventItem})

let runEventHandlerOrThrow = async (
  eventItem: Internal.eventItem,
  ~loader,
  ~handler,
  ~inMemoryStore,
  ~loadManager,
  ~persistence,
  ~shouldSaveHistory,
  ~shouldBenchmark,
) => {
  //Include the load in time before handler
  let timeBeforeHandler = Hrtime.makeTimer()

  let contextParams: UserContext.contextParams = {
    eventItem,
    inMemoryStore,
    loadManager,
    persistence,
    shouldSaveHistory,
    isPreload: false,
  }

  let loaderReturn = switch loader {
  | Some(loader) =>
    try {
      await loader(UserContext.getLoaderArgs(contextParams))
    } catch {
    | exn =>
      raise(
        ProcessingError({
          message: "Unexpected error in the event loader. Please handle the error to keep the indexer running smoothly.",
          eventItem,
          exn,
        }),
      )
    }
  | None => (%raw(`undefined`): Internal.loaderReturn)
  }

  try {
    await handler(UserContext.getHandlerArgs(contextParams, ~loaderReturn))
  } catch {
  | exn =>
    raise(
      ProcessingError({
        message: "Unexpected error in the event handler. Please handle the error to keep the indexer running smoothly.",
        eventItem,
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
  eventItem: Internal.eventItem,
  ~inMemoryStore,
  ~loadManager,
  ~config: Config.t,
  ~shouldSaveHistory,
  ~shouldBenchmark,
) => {
  switch eventItem.eventConfig.handler {
  | Some(handler) =>
    await eventItem->runEventHandlerOrThrow(
      ~loader=eventItem.eventConfig.loader,
      ~handler,
      ~inMemoryStore,
      ~loadManager,
      ~persistence=config.persistence,
      ~shouldSaveHistory,
      ~shouldBenchmark,
    )
  | None => ()
  }

  eventItem->updateEventSyncState(~inMemoryStore)

  if config.enableRawEvents {
    eventItem->addEventToRawEvents(~inMemoryStore)
  }
}

let runBatchLoadersOrThrow = async (
  eventBatch: array<Internal.eventItem>,
  ~loadManager,
  ~persistence,
  ~inMemoryStore,
) => {
  // On the first run of loaders, we don't care about the result,
  // whether it's an error or a return type.
  // We'll rerun the loader again right before the handler run,
  // to avoid having a stale data returned from the loader.
  let _ = await Promise.all(
    eventBatch->Array.keepMap(eventItem => {
      switch eventItem.eventConfig {
      | {loader: Some(loader)} =>
        try {
          Some(
            loader(
              UserContext.getLoaderArgs({
                eventItem,
                inMemoryStore,
                loadManager,
                persistence,
                isPreload: true,
                shouldSaveHistory: false,
              }),
              // Must have Promise.catch as well as normal catch,
              // because if user throws an error before await in the handler,
              // it won't create a rejected promise
            )->Promise.silentCatch,
          )
        } catch {
        | _ => None
        }
      | _ => None
      }
    }),
  )
}

let runBatchHandlersOrThrow = async (
  eventBatch: array<Internal.eventItem>,
  ~inMemoryStore,
  ~loadManager,
  ~config,
  ~shouldSaveHistory,
  ~shouldBenchmark,
) => {
  for i in 0 to eventBatch->Array.length - 1 {
    let eventItem = eventBatch->Js.Array2.unsafe_get(i)
    await runHandlerOrThrow(
      eventItem,
      ~inMemoryStore,
      ~loadManager,
      ~config,
      ~shouldSaveHistory,
      ~shouldBenchmark,
    )
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
  ~items: array<Internal.eventItem>,
  ~processingMetricsByChainId: dict<ChainManager.processingChainMetrics>,
  ~inMemoryStore: InMemoryStore.t,
  ~isInReorgThreshold,
  ~loadManager,
  ~config: Config.t,
) => {
  let batchSize = items->Array.length
  let logger = Logging.createChildFrom(
    ~logger=Logging.getLogger(),
    ~params={
      "totalBatchSize": batchSize,
      "byChain": processingMetricsByChainId->Utils.Dict.map(v => {
        {
          "batchSize": v.batchSize,
          "toBlockNumber": v.targetBlockNumber,
        }
      }),
    },
  )
  logger->Logging.childTrace("Started processing batch")

  try {
    let timeRef = Hrtime.makeTimer()

    await items->runBatchLoadersOrThrow(
      ~loadManager,
      ~persistence=config.persistence,
      ~inMemoryStore,
    )

    let elapsedTimeAfterLoaders = timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    await items->runBatchHandlersOrThrow(
      ~inMemoryStore,
      ~loadManager,
      ~config,
      ~shouldSaveHistory=config->Config.shouldSaveHistory(~isInReorgThreshold),
      ~shouldBenchmark=Env.Benchmark.shouldSaveData,
    )

    let elapsedTimeAfterProcessing =
      timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    let rec executeBatch = async (~escapeTables=?) => {
      switch await Db.sql->IO.executeBatch(~inMemoryStore, ~isInReorgThreshold, ~config, ~escapeTables?) {
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
              ~batchSize,
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
  | ProcessingError({message, exn, eventItem}) =>
    exn
    ->ErrorHandling.make(~msg=message, ~logger=eventItem->Logging.getEventLogger)
    ->Error
  }
}
