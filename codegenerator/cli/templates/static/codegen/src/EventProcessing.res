open Belt

module EventsProcessed = {
  type eventsProcessed = {
    numEventsProcessed: int,
    latestProcessedBlock: option<int>,
  }
  type t = ChainMap.t<eventsProcessed>

  let makeEmpty = (~config: Config.t) => {
    config.chainMap->ChainMap.map(_ => {
      numEventsProcessed: 0,
      latestProcessedBlock: None,
    })
  }

  let allChainsEventsProcessedToEndblock = (chainFetchers: ChainMap.t<ChainFetcher.t>) => {
    chainFetchers
    ->ChainMap.values
    ->Array.reduce(true, (accum, cf) => cf->ChainFetcher.hasProcessedToEndblock && accum)
  }

  let makeFromChainManager = (cm: ChainManager.t): t => {
    cm.chainFetchers->ChainMap.map(({numEventsProcessed, latestProcessedBlock}) => {
      numEventsProcessed,
      latestProcessedBlock,
    })
  }

  let updateEventsProcessed = (self: t, ~chain, ~blockNumber) => {
    self->ChainMap.update(chain, ({numEventsProcessed}) => {
      numEventsProcessed: numEventsProcessed + 1,
      latestProcessedBlock: Some(blockNumber),
    })
  }
}

let updateEventSyncState = (
  eventBatchQueueItem: Types.eventBatchQueueItem,
  ~inMemoryStore: InMemoryStore.t,
  ~isPreRegisteringDynamicContracts,
) => {
  let {event, chain, blockNumber, timestamp: blockTimestamp} = eventBatchQueueItem
  let {logIndex} = event
  let chainId = chain->ChainMap.Chain.toChainId
  let _ = inMemoryStore.eventSyncState->InMemoryTable.set(
    chainId,
    {
      chainId,
      blockTimestamp,
      blockNumber,
      logIndex,
      isPreRegisteringDynamicContracts,
    },
  )
}

type dynamicContractRegistration = FetchState.dynamicContractRegistration

type dynamicContractRegistrations = {
  registrations: array<dynamicContractRegistration>,
  unprocessedBatch: array<Types.eventBatchQueueItem>,
}

let addToDynamicContractRegistrations = (
  eventBatchQueueItem: Types.eventBatchQueueItem,
  ~dynamicContracts,
  ~registeringEventBlockNumber,
  ~registeringEventLogIndex,
  ~registrations,
  ~unprocessedBatch,
) => {
  //If there are any dynamic contract registrations, put this item in the unprocessedBatch flagged
  //with "hasRegisteredDynamicContracts" and return the same list of entitiesToLoad without the
  //current item
  let unprocessedBatch = [
    ...unprocessedBatch,
    {
      ...eventBatchQueueItem,
      hasRegisteredDynamicContracts: true,
    },
  ]

  let dynamicContractRegistration = {
    FetchState.dynamicContracts,
    registeringEventBlockNumber,
    registeringEventLogIndex,
    registeringEventChain: eventBatchQueueItem.chain,
  }

  {
    unprocessedBatch,
    registrations: [...registrations, dynamicContractRegistration],
  }
}

let checkContractIsInCurrentRegistrations = (
  ~dynamicContractRegistrations: option<dynamicContractRegistrations>,
  ~chain,
  ~contractAddress,
  ~contractType,
) => {
  switch dynamicContractRegistrations {
  | Some(dynamicContracts) =>
    dynamicContracts.registrations->Array.some(d =>
      d.dynamicContracts->Array.some(d =>
        d.chainId == chain->ChainMap.Chain.toChainId &&
        d.contractType == contractType &&
        d.contractAddress == contractAddress
      )
    )
  | None => false
  }
}

let runEventContractRegister = (
  contractRegister: Types.HandlerTypes.args<_> => unit,
  ~eventBatchQueueItem: Types.eventBatchQueueItem,
  ~logger,
  ~checkContractIsRegistered,
  ~dynamicContractRegistrations: option<dynamicContractRegistrations>,
  ~inMemoryStore,
  ~preRegisterLatestProcessedBlocks=?,
  ~shouldSaveHistory,
) => {
  let {chain, event, blockNumber} = eventBatchQueueItem

  let contextEnv = ContextEnv.make(~eventBatchQueueItem, ~logger)

  switch contractRegister(
    contextEnv->ContextEnv.getContractRegisterArgs(~inMemoryStore, ~shouldSaveHistory),
  ) {
  | exception exn =>
    exn
    ->ErrorHandling.make(
      ~msg="Event contractRegister failed, please fix the error to keep the indexer running smoothly",
      ~logger=contextEnv.logger,
    )
    ->Error
  | () =>
    let dynamicContracts =
      contextEnv
      ->ContextEnv.getAddedDynamicContractRegistrations
      ->Array.keep(({contractAddress, contractType}) =>
        !checkContractIsRegistered(~chain, ~contractAddress, ~contractName=contractType) &&
        !checkContractIsInCurrentRegistrations(
          ~dynamicContractRegistrations,
          ~chain,
          ~contractAddress,
          ~contractType,
        )
      )

    let addToDynamicContractRegistrations =
      eventBatchQueueItem->(
        addToDynamicContractRegistrations(
          ~registeringEventBlockNumber=blockNumber,
          ~registeringEventLogIndex=event.logIndex,
          ...
        )
      )

    let val = switch (dynamicContracts, dynamicContractRegistrations) {
    | ([], None) => None
    | (dynamicContracts, Some({registrations, unprocessedBatch})) =>
      addToDynamicContractRegistrations(~dynamicContracts, ~registrations, ~unprocessedBatch)->Some
    | (dynamicContracts, None) =>
      addToDynamicContractRegistrations(
        ~dynamicContracts,
        ~registrations=[],
        ~unprocessedBatch=[],
      )->Some
    }

    switch preRegisterLatestProcessedBlocks {
    | Some(latestProcessedBlocks) =>
      eventBatchQueueItem->updateEventSyncState(
        ~inMemoryStore,
        ~isPreRegisteringDynamicContracts=true,
      )
      latestProcessedBlocks :=
        latestProcessedBlocks.contents->EventsProcessed.updateEventsProcessed(
          ~chain=eventBatchQueueItem.chain,
          ~blockNumber=eventBatchQueueItem.blockNumber,
        )
    | None => ()
    }

    val->Ok
  }
}

let runEventLoader = async (
  ~contextEnv,
  ~loader: Types.HandlerTypes.loader<_>,
  ~inMemoryStore,
  ~loadLayer,
) => {
  switch await loader(contextEnv->ContextEnv.getLoaderArgs(~inMemoryStore, ~loadLayer)) {
  | exception exn =>
    exn
    ->ErrorHandling.make(
      ~msg="Event pre loader failed, please fix the error to keep the indexer running smoothly",
      ~logger=contextEnv.logger,
    )
    ->Error
  | loadReturn => loadReturn->Ok
  }
}

let addEventToRawEvents = (
  eventBatchQueueItem: Types.eventBatchQueueItem,
  ~inMemoryStore: InMemoryStore.t,
) => {
  let {
    event,
    eventName,
    contractName,
    chain,
    blockNumber,
    paramsRawEventSchema,
    timestamp: blockTimestamp,
  } = eventBatchQueueItem
  let {block, transaction, params, logIndex, srcAddress} = event
  let chainId = chain->ChainMap.Chain.toChainId
  let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
  let blockFields =
    (block :> Types.Block.rawEventFields)->S.serializeOrRaiseWith(Types.Block.rawEventSchema)
  let transactionFields = transaction->S.serializeOrRaiseWith(Types.Transaction.schema)
  // Serialize to unknown, because serializing to Js.Json.t fails for Bytes Fuel type, since it has unknown schema
  let params =
    params
    ->S.serializeToUnknownOrRaiseWith(paramsRawEventSchema)
    ->(Utils.magic: unknown => Js.Json.t)

  let rawEvent: TablesStatic.RawEvents.t = {
    chainId,
    eventId: eventId->BigInt.toString,
    eventName,
    contractName,
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
  eventBatchQueueItem: Types.eventBatchQueueItem,
  ~loaderHandler: Types.HandlerTypes.loaderHandler<_>,
  ~inMemoryStore,
  ~logger,
  ~loadLayer,
  ~shouldSaveHistory,
) => {
  open ErrorHandling.ResultPropogateEnv
  runAsyncEnv(async () => {
    let contextEnv = ContextEnv.make(~eventBatchQueueItem, ~logger)
    let {loader, handler} = loaderHandler

    //Include the load in time before handler
    let timeBeforeHandler = Hrtime.makeTimer()

    let loaderReturn =
      (await runEventLoader(~contextEnv, ~loader, ~inMemoryStore, ~loadLayer))->propogate

    switch await handler(
      contextEnv->ContextEnv.getHandlerArgs(
        ~loaderReturn,
        ~inMemoryStore,
        ~loadLayer,
        ~shouldSaveHistory,
      ),
    ) {
    | exception exn =>
      exn
      ->ErrorHandling.make(
        ~msg="Event Handler failed, please fix the error to keep the indexer running smoothly",
        ~logger=contextEnv.logger,
      )
      ->Error
      ->propogate
    | () =>
      if Env.Benchmark.shouldSaveData {
        let timeEnd = timeBeforeHandler->Hrtime.timeSince->Hrtime.toMillis->Hrtime.floatFromMillis

        Benchmark.addSummaryData(
          ~group="Handlers Per Event",
          ~label=`${eventBatchQueueItem.contractName} ${eventBatchQueueItem.eventName} Handler (ms)`,
          ~value=timeEnd,
          ~decimalPlaces=4,
        )
      }
      Ok()
    }
  })
}

let runHandler = async (
  eventBatchQueueItem: Types.eventBatchQueueItem,
  ~latestProcessedBlocks,
  ~inMemoryStore,
  ~logger,
  ~loadLayer,
  ~config: Config.t,
  ~isInReorgThreshold,
) => {
  let result = switch eventBatchQueueItem.handlerRegister->Types.HandlerTypes.Register.getLoaderHandler {
  | Some(loaderHandler) =>
    await eventBatchQueueItem->runEventHandler(
      ~loaderHandler,
      ~inMemoryStore,
      ~logger,
      ~loadLayer,
      ~shouldSaveHistory=config->Config.shouldSaveHistory(~isInReorgThreshold),
    )
  | None => Ok()
  }

  result->Result.map(() => {
    eventBatchQueueItem->updateEventSyncState(
      ~inMemoryStore,
      ~isPreRegisteringDynamicContracts=false,
    )

    if config.enableRawEvents {
      eventBatchQueueItem->addEventToRawEvents(~inMemoryStore)
    }

    latestProcessedBlocks->EventsProcessed.updateEventsProcessed(
      ~chain=eventBatchQueueItem.chain,
      ~blockNumber=eventBatchQueueItem.blockNumber,
    )
  })
}

let addToUnprocessedBatch = (
  eventBatchQueueItem: Types.eventBatchQueueItem,
  dynamicContractRegistrations,
) => {
  {
    ...dynamicContractRegistrations,
    unprocessedBatch: [...dynamicContractRegistrations.unprocessedBatch, eventBatchQueueItem],
  }
}

let rec registerDynamicContracts = (
  eventBatch: array<Types.eventBatchQueueItem>,
  ~index=0,
  ~checkContractIsRegistered,
  ~logger,
  ~eventsBeforeDynamicRegistrations=[],
  ~dynamicContractRegistrations: option<dynamicContractRegistrations>=None,
  ~inMemoryStore,
  ~preRegisterLatestProcessedBlocks=?,
  ~shouldSaveHistory,
) => {
  switch eventBatch[index] {
  | None => (eventsBeforeDynamicRegistrations, dynamicContractRegistrations)->Ok
  | Some(eventBatchQueueItem) =>
    let dynamicContractRegistrationsResult = if (
      eventBatchQueueItem.hasRegisteredDynamicContracts->Option.getWithDefault(false)
    ) {
      //If an item has already been registered, it would have been
      //put back on the arbitrary events queue and is now being reprocessed
      dynamicContractRegistrations
      ->Option.map(dynamicContractRegistrations =>
        addToUnprocessedBatch(eventBatchQueueItem, dynamicContractRegistrations)
      )
      ->Ok
    } else {
      switch eventBatchQueueItem.handlerRegister->Types.HandlerTypes.Register.getContractRegister {
      | Some(handler) =>
        handler->runEventContractRegister(
          ~logger,
          ~checkContractIsRegistered,
          ~eventBatchQueueItem,
          ~dynamicContractRegistrations,
          ~inMemoryStore,
          ~preRegisterLatestProcessedBlocks?,
          ~shouldSaveHistory,
        )
      | None =>
        dynamicContractRegistrations
        ->Option.map(dynamicContractRegistrations =>
          addToUnprocessedBatch(eventBatchQueueItem, dynamicContractRegistrations)
        )
        ->Ok
      }
    }

    switch dynamicContractRegistrationsResult {
    | Ok(dynamicContractRegistrations) =>
      if dynamicContractRegistrations->Option.isNone {
        //Mutate for performance (could otherwise use concat?)
        eventsBeforeDynamicRegistrations->Js.Array2.push(eventBatchQueueItem)->ignore
      }
      eventBatch->registerDynamicContracts(
        ~index=index + 1,
        ~checkContractIsRegistered,
        ~logger,
        ~eventsBeforeDynamicRegistrations,
        ~dynamicContractRegistrations,
        ~inMemoryStore,
        ~preRegisterLatestProcessedBlocks?,
        ~shouldSaveHistory,
      )
    | Error(e) => Error(e)
    }
  }
}

let runLoaders = (
  eventBatch: array<Types.eventBatchQueueItem>,
  ~loadLayer,
  ~inMemoryStore,
  ~logger,
) => {
  open ErrorHandling.ResultPropogateEnv
  runAsyncEnv(async () => {
    // We don't actually need loader returns,
    // since we'll need to rerun each loader separately
    // before the handler, to get the uptodate entities from the in memory store.
    // Still need to propogate the errors.
    let _: array<unknown> =
      await eventBatch
      ->Array.keepMap(eventBatchQueueItem => {
        eventBatchQueueItem.handlerRegister
        ->Types.HandlerTypes.Register.getLoaderHandler
        ->Option.map(
          ({loader}) => {
            let contextEnv = ContextEnv.make(~eventBatchQueueItem, ~logger)
            runEventLoader(~contextEnv, ~loader, ~inMemoryStore, ~loadLayer)->Promise.thenResolve(
              propogate,
            )
          },
        )
      })
      ->Promise.all
    Ok()
  })
}

let runHandlers = (
  eventBatch: array<Types.eventBatchQueueItem>,
  ~inMemoryStore,
  ~latestProcessedBlocks,
  ~logger,
  ~loadLayer,
  ~config,
  ~isInReorgThreshold,
) => {
  open ErrorHandling.ResultPropogateEnv
  let latestProcessedBlocks = ref(latestProcessedBlocks)
  runAsyncEnv(async () => {
    for i in 0 to eventBatch->Array.length - 1 {
      let eventBatchQueueItem = eventBatch->Js.Array2.unsafe_get(i)

      latestProcessedBlocks :=
        (
          await runHandler(
            eventBatchQueueItem,
            ~inMemoryStore,
            ~logger,
            ~latestProcessedBlocks=latestProcessedBlocks.contents,
            ~loadLayer,
            ~config,
            ~isInReorgThreshold,
          )
        )->propogate
    }
    Ok(latestProcessedBlocks.contents)
  })
}

let registerProcessEventBatchMetrics = (
  ~logger,
  ~batchSize,
  ~loadDuration,
  ~handlerDuration,
  ~dbWriteDuration,
) => {
  logger->Logging.childTrace({
    "message": "Finished processing batch",
    "batch_size": batchSize,
    "loader_time_elapsed": loadDuration,
    "handlers_time_elapsed": handlerDuration,
    "write_time_elapsed": dbWriteDuration,
  })

  Prometheus.incrementLoadEntityDurationCounter(~duration=loadDuration)
  Prometheus.incrementEventRouterDurationCounter(~duration=handlerDuration)
  Prometheus.incrementExecuteBatchDurationCounter(~duration=dbWriteDuration)
  Prometheus.incrementEventsProcessedCounter(~number=batchSize)
}

type batchProcessed = {
  latestProcessedBlocks: EventsProcessed.t,
  dynamicContractRegistrations: option<dynamicContractRegistrations>,
}

let getDynamicContractRegistrations = (
  ~eventBatch: array<Types.eventBatchQueueItem>,
  ~latestProcessedBlocks: EventsProcessed.t,
  ~checkContractIsRegistered,
  ~config,
) => {
  let logger = Logging.createChild(
    ~params={
      "context": "pre-registration",
      "batch-size": eventBatch->Array.length,
      "first-event-timestamp": eventBatch[0]->Option.map(v => v.timestamp),
    },
  )
  let inMemoryStore = InMemoryStore.make()
  let preRegisterLatestProcessedBlocks = ref(latestProcessedBlocks)
  open ErrorHandling.ResultPropogateEnv
  runAsyncEnv(async () => {
    //Register all the dynamic contracts in this batch,
    //only continue processing events before the first dynamic contract registration
    let (_, dynamicContractRegistrations) =
      eventBatch
      ->registerDynamicContracts(
        ~checkContractIsRegistered,
        ~logger,
        ~inMemoryStore,
        ~preRegisterLatestProcessedBlocks,
        ~shouldSaveHistory=false,
      )
      ->propogate

    //We only preregister below the reorg threshold so it can be hardcoded as false
    switch await DbFunctions.sql->IO.executeBatch(
      ~inMemoryStore,
      ~isInReorgThreshold=false,
      ~config,
    ) {
    | exception exn =>
      exn->ErrorHandling.make(~msg="Failed writing batch to database", ~logger)->Error->propogate
    | () => ()
    }

    Ok({
      latestProcessedBlocks: preRegisterLatestProcessedBlocks.contents,
      dynamicContractRegistrations,
    })
  })
}

let processEventBatch = (
  ~eventBatch: array<Types.eventBatchQueueItem>,
  ~inMemoryStore: InMemoryStore.t,
  ~isInReorgThreshold,
  ~latestProcessedBlocks: EventsProcessed.t,
  ~checkContractIsRegistered,
  ~loadLayer,
  ~config,
) => {
  let logger = Logging.createChild(
    ~params={
      "context": "batch",
      "batch-size": eventBatch->Array.length,
      "first-event-timestamp": eventBatch[0]->Option.map(v => v.timestamp),
    },
  )

  let timeRef = Hrtime.makeTimer()

  open ErrorHandling.ResultPropogateEnv
  runAsyncEnv(async () => {
    //Register all the dynamic contracts in this batch,
    //only continue processing events before the first dynamic contract registration
    let (
      eventsBeforeDynamicRegistrations: array<Types.eventBatchQueueItem>,
      dynamicContractRegistrations,
    ) =
      eventBatch
      ->registerDynamicContracts(
        ~checkContractIsRegistered,
        ~logger,
        ~inMemoryStore,
        ~shouldSaveHistory=config->Config.shouldSaveHistory(~isInReorgThreshold),
      )
      ->propogate

    let elapsedAfterContractRegister =
      timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    (await eventsBeforeDynamicRegistrations
    ->runLoaders(~loadLayer, ~inMemoryStore, ~logger))
    ->propogate

    let elapsedAfterLoad = timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    let latestProcessedBlocks =
      (await eventsBeforeDynamicRegistrations
      ->runHandlers(
        ~inMemoryStore,
        ~latestProcessedBlocks,
        ~logger,
        ~loadLayer,
        ~config,
        ~isInReorgThreshold,
      ))
      ->propogate

    let elapsedTimeAfterProcess = timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    switch await DbFunctions.sql->IO.executeBatch(~inMemoryStore, ~isInReorgThreshold, ~config) {
    | exception exn =>
      exn->ErrorHandling.make(~msg="Failed writing batch to database", ~logger)->Error->propogate
    | () => ()
    }

    let elapsedTimeAfterDbWrite = timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis
    let batchSize = eventsBeforeDynamicRegistrations->Array.length
    let handlerDuration = elapsedTimeAfterProcess - elapsedAfterLoad
    let dbWriteDuration = elapsedTimeAfterDbWrite - elapsedTimeAfterProcess
    registerProcessEventBatchMetrics(
      ~logger,
      ~batchSize,
      ~loadDuration=elapsedAfterLoad,
      ~handlerDuration,
      ~dbWriteDuration,
    )
    if Env.Benchmark.shouldSaveData {
      Benchmark.addEventProcessing(
        ~batchSize=eventsBeforeDynamicRegistrations->Array.length,
        ~contractRegisterDuration=elapsedAfterContractRegister,
        ~loadDuration=elapsedAfterLoad - elapsedAfterContractRegister,
        ~handlerDuration,
        ~dbWriteDuration,
        ~totalTimeElapsed=elapsedTimeAfterDbWrite,
      )
    }

    Ok({latestProcessedBlocks, dynamicContractRegistrations})
  })
}
