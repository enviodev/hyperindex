open Belt

let allChainsEventsProcessedToEndblock = (chainFetchers: ChainMap.t<ChainFetcher.t>) => {
  chainFetchers
  ->ChainMap.values
  ->Array.reduce(true, (accum, cf) => cf->ChainFetcher.hasProcessedToEndblock && accum)
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

let runEventLoader = async (
  ~eventItem,
  ~loader: Internal.loader,
  ~inMemoryStore,
  ~loadLayer,
  ~shouldGroup=false,
) => {
  switch await loader(
    UserContext.getLoaderArgs({
      eventItem,
      inMemoryStore,
      loadLayer,
      shouldGroup,
    }),
  ) {
  | exception exn =>
    exn
    ->ErrorHandling.make(
      ~msg="Event pre loader failed, please fix the error to keep the indexer running smoothly",
      ~logger=eventItem->Logging.getEventLogger,
    )
    ->Error
  | loadReturn => loadReturn->Ok
  }
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

let runEventHandler = (
  eventItem: Internal.eventItem,
  ~loader,
  ~handler,
  ~inMemoryStore,
  ~loadLayer,
  ~shouldSaveHistory,
) => {
  open ErrorHandling.ResultPropogateEnv
  runAsyncEnv(async () => {
    //Include the load in time before handler
    let timeBeforeHandler = Hrtime.makeTimer()

    let loaderReturn = switch loader {
    | Some(loader) =>
      (await runEventLoader(~eventItem, ~loader, ~inMemoryStore, ~loadLayer))->propogate
    | None => (%raw(`undefined`): Internal.loaderReturn)
    }

    switch await handler(
      UserContext.getHandlerArgs(
        {
          eventItem,
          inMemoryStore,
          loadLayer,
          shouldSaveHistory,
          shouldGroup: false,
        },
        ~loaderReturn,
      ),
    ) {
    | exception exn =>
      exn
      ->ErrorHandling.make(
        ~msg="Event Handler failed, please fix the error to keep the indexer running smoothly",
        ~logger=eventItem->Logging.getEventLogger,
      )
      ->Error
      ->propogate
    | () =>
      if Env.Benchmark.shouldSaveData {
        let timeEnd = timeBeforeHandler->Hrtime.timeSince->Hrtime.toMillis->Hrtime.floatFromMillis

        Benchmark.addSummaryData(
          ~group="Handlers Per Event",
          ~label=`${eventItem.eventConfig.contractName} ${eventItem.eventConfig.name} Handler (ms)`,
          ~value=timeEnd,
          ~decimalPlaces=4,
        )
      }
      Ok()
    }
  })
}

let runHandler = async (
  eventItem: Internal.eventItem,
  ~inMemoryStore,
  ~loadLayer,
  ~config: Config.t,
  ~isInReorgThreshold,
) => {
  let result = switch eventItem.eventConfig.handler {
  | None => Ok()
  | Some(handler) =>
    await eventItem->runEventHandler(
      ~loader=eventItem.eventConfig.loader,
      ~handler,
      ~inMemoryStore,
      ~loadLayer,
      ~shouldSaveHistory=config->Config.shouldSaveHistory(~isInReorgThreshold),
    )
  }

  result->Result.map(() => {
    eventItem->updateEventSyncState(~inMemoryStore)

    if config.enableRawEvents {
      eventItem->addEventToRawEvents(~inMemoryStore)
    }
  })
}

let runLoaders = (eventBatch: array<Internal.eventItem>, ~loadLayer, ~inMemoryStore) => {
  open ErrorHandling.ResultPropogateEnv
  runAsyncEnv(async () => {
    // We don't actually need loader returns,
    // since we'll need to rerun each loader separately
    // before the handler, to get the uptodate entities from the in memory store.
    // Still need to propogate the errors.
    let _: array<Internal.loaderReturn> =
      await eventBatch
      ->Array.keepMap(eventItem => {
        switch eventItem.eventConfig {
        | {loader: Some(loader)} =>
          runEventLoader(~eventItem, ~loader, ~inMemoryStore, ~loadLayer, ~shouldGroup=true)
          ->Promise.thenResolve(propogate)
          ->Some
        | _ => None
        }
      })
      ->Promise.all
    Ok()
  })
}

let runHandlers = (
  eventBatch: array<Internal.eventItem>,
  ~inMemoryStore,
  ~loadLayer,
  ~config,
  ~isInReorgThreshold,
) => {
  open ErrorHandling.ResultPropogateEnv
  runAsyncEnv(async () => {
    for i in 0 to eventBatch->Array.length - 1 {
      let eventItem = eventBatch->Js.Array2.unsafe_get(i)

      (
        await runHandler(eventItem, ~inMemoryStore, ~loadLayer, ~config, ~isInReorgThreshold)
      )->propogate
    }
    Ok()
  })
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

let processEventBatch = (
  ~items: array<Internal.eventItem>,
  ~processingMetricsByChainId: dict<ChainManager.processingChainMetrics>,
  ~inMemoryStore: InMemoryStore.t,
  ~isInReorgThreshold,
  ~loadLayer,
  ~config,
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

  let timeRef = Hrtime.makeTimer()

  open ErrorHandling.ResultPropogateEnv
  runAsyncEnv(async () => {
    (await items->runLoaders(~loadLayer, ~inMemoryStore))->propogate

    let elapsedTimeAfterLoaders = timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    (await items->runHandlers(~inMemoryStore, ~loadLayer, ~config, ~isInReorgThreshold))->propogate

    let elapsedTimeAfterProcessing =
      timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    switch await Db.sql->IO.executeBatch(~inMemoryStore, ~isInReorgThreshold, ~config) {
    | exception exn =>
      exn->ErrorHandling.make(~msg="Failed writing batch to database", ~logger)->Error->propogate
    | () => ()
    }

    let elapsedTimeAfterDbWrite = timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis
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
        ~contractRegisterDuration=0,
        ~loadDuration=loaderDuration,
        ~handlerDuration,
        ~dbWriteDuration,
        ~totalTimeElapsed=elapsedTimeAfterDbWrite,
      )
    }

    Ok()
  })
}
