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

type dynamicContractRegistration = {
  registeringEventBlockNumber: int,
  registeringEventLogIndex: int,
  registeringEventChain: ChainMap.Chain.t,
  dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>,
}

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
    dynamicContracts,
    registeringEventBlockNumber,
    registeringEventLogIndex,
    registeringEventChain: eventBatchQueueItem.chain,
  }
  {
    unprocessedBatch,
    registrations: [...registrations, dynamicContractRegistration],
  }
}

let runEventContractRegister = (
  contractRegister: RegisteredEvents.args<_> => unit,
  ~event,
  ~eventBatchQueueItem: Types.eventBatchQueueItem,
  ~logger,
  ~checkContractIsRegistered,
  ~dynamicContractRegistrations: option<dynamicContractRegistrations>,
  ~inMemoryStore,
) => {
  let {chain, eventMod} = eventBatchQueueItem

  let contextEnv = ContextEnv.make(~event, ~chain, ~logger, ~eventMod)

  switch contractRegister(contextEnv->ContextEnv.getContractRegisterArgs(~inMemoryStore)) {
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
        !checkContractIsRegistered(~chain, ~contractAddress, ~contractName=contractType)
      )

    let addToDynamicContractRegistrations =
      eventBatchQueueItem->(
        addToDynamicContractRegistrations(
          ~registeringEventBlockNumber=event.block.number,
          ~registeringEventLogIndex=event.logIndex,
          ...
        )
      )

    let val = switch (dynamicContracts, dynamicContractRegistrations) {
    | ([], dynamicContractRegistrations) => dynamicContractRegistrations
    | (dynamicContracts, Some({registrations, unprocessedBatch})) =>
      addToDynamicContractRegistrations(~dynamicContracts, ~registrations, ~unprocessedBatch)->Some
    | (dynamicContracts, None) =>
      addToDynamicContractRegistrations(
        ~dynamicContracts,
        ~registrations=[],
        ~unprocessedBatch=[],
      )->Some
    }

    val->Ok
  }
}

let runEventLoader = async (
  ~contextEnv,
  ~handler: RegisteredEvents.registeredLoaderHandler<_>,
  ~inMemoryStore,
  ~loadLayer,
) => {
  let {loader} = handler

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
  event: Types.eventLog<Types.internalEventArgs>,
  ~eventMod: module(Types.InternalEvent),
  ~inMemoryStore: InMemoryStore.t,
  ~chainId,
) => {
  let {block, transaction, params, logIndex, srcAddress} = event
  let {number: blockNumber, hash: blockHash, timestamp: blockTimestamp} = block
  let module(Event) = eventMod
  let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
  let blockFields =
    block->Types.Block.getSelectableFields->S.serializeOrRaiseWith(Types.Block.schema)
  let transactionFields = transaction->S.serializeOrRaiseWith(Types.Transaction.schema)
  let params = params->S.serializeOrRaiseWith(Event.eventArgsSchema)

  let rawEvent: TablesStatic.RawEvents.t = {
    chainId,
    eventId: eventId->BigInt.toString,
    eventName: Event.name,
    contractName: Event.contractName,
    blockNumber,
    logIndex,
    srcAddress,
    blockHash,
    blockTimestamp,
    blockFields,
    transactionFields,
    params,
  }

  let eventIdStr = eventId->BigInt.toString

  inMemoryStore.rawEvents->InMemoryTable.set({chainId, eventId: eventIdStr}, rawEvent)
}

let updateEventSyncState = (
  event: Types.eventLog<'a>,
  ~chainId,
  ~inMemoryStore: InMemoryStore.t,
) => {
  let {logIndex, block: {number: blockNumber, timestamp: blockTimestamp}} = event
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

let runEventHandler = (
  event,
  ~eventMod: module(Types.InternalEvent),
  ~handler,
  ~inMemoryStore,
  ~logger,
  ~chain,
  ~latestProcessedBlocks,
  ~loadLayer,
  ~config: Config.t,
) => {
  open ErrorHandling.ResultPropogateEnv
  runAsyncEnv(async () => {
    let contextEnv = ContextEnv.make(~event, ~chain, ~logger, ~eventMod)

    let loaderReturn =
      (await runEventLoader(~contextEnv, ~handler, ~inMemoryStore, ~loadLayer))->propogate

    switch await handler.handler(
      contextEnv->ContextEnv.getHandlerArgs(~loaderReturn, ~inMemoryStore, ~loadLayer),
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
      let {chainId} = event

      event->updateEventSyncState(~chainId, ~inMemoryStore)
      if config.enableRawEvents {
        event->addEventToRawEvents(~eventMod, ~inMemoryStore, ~chainId)
      }
      latestProcessedBlocks
      ->EventsProcessed.updateEventsProcessed(~chain, ~blockNumber=event.block.number)
      ->Ok
    }
  })
}

let runHandler = (
  event: Types.eventLog<'eventArgs>,
  ~eventMod: module(Types.InternalEvent),
  ~latestProcessedBlocks,
  ~inMemoryStore,
  ~logger,
  ~chain,
  ~registeredEvents,
  ~loadLayer,
  ~config,
) => {
  switch registeredEvents
  ->RegisteredEvents.get(eventMod)
  ->Option.flatMap(registeredEvent => registeredEvent.loaderHandler) {
  | Some(handler) =>
    event->runEventHandler(
      ~handler,
      ~latestProcessedBlocks,
      ~inMemoryStore,
      ~logger,
      ~chain,
      ~eventMod,
      ~loadLayer,
      ~config,
    )
  | None => Ok(latestProcessedBlocks)->Promise.resolve
  }
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
  ~registeredEvents: RegisteredEvents.t,
  ~checkContractIsRegistered,
  ~logger,
  ~eventsBeforeDynamicRegistrations=[],
  ~dynamicContractRegistrations: option<dynamicContractRegistrations>=None,
  ~inMemoryStore,
) => {
  switch eventBatch[index] {
  | None => (eventsBeforeDynamicRegistrations, dynamicContractRegistrations)->Ok
  // | list{eventBatchQueueItem, ...tail} =>
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
      let {eventMod, event} = eventBatchQueueItem

      switch registeredEvents
      ->RegisteredEvents.get(eventMod)
      ->Option.flatMap(v => v.contractRegister) {
      | Some(handler) =>
        handler->runEventContractRegister(
          ~event,
          ~logger,
          ~checkContractIsRegistered,
          ~eventBatchQueueItem,
          ~dynamicContractRegistrations,
          ~inMemoryStore,
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
        ~registeredEvents,
        ~checkContractIsRegistered,
        ~logger,
        ~eventsBeforeDynamicRegistrations,
        ~dynamicContractRegistrations,
        ~inMemoryStore,
      )
    | Error(e) => Error(e)
    }
  }
}

let runLoaders = (
  eventBatch: array<Types.eventBatchQueueItem>,
  ~registeredEvents: RegisteredEvents.t,
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
      ->Array.keepMap(({chain, eventMod, event}) => {
        registeredEvents
        ->RegisteredEvents.get(eventMod)
        ->Option.flatMap(registeredEvent => registeredEvent.loaderHandler)
        ->Option.map(
          handler => {
            let contextEnv = ContextEnv.make(~chain, ~eventMod, ~event, ~logger)
            runEventLoader(~contextEnv, ~handler, ~inMemoryStore, ~loadLayer)->Promise.thenResolve(
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
  ~registeredEvents,
  ~inMemoryStore,
  ~latestProcessedBlocks,
  ~logger,
  ~loadLayer,
  ~config,
) => {
  open ErrorHandling.ResultPropogateEnv
  let latestProcessedBlocks = ref(latestProcessedBlocks)
  runAsyncEnv(async () => {
    for i in 0 to eventBatch->Array.length - 1 {
      let {event, eventMod, chain} = eventBatch->Js.Array2.unsafe_get(i)

      latestProcessedBlocks :=
        (
          await runHandler(
            event,
            ~eventMod,
            ~inMemoryStore,
            ~logger,
            ~chain,
            ~latestProcessedBlocks=latestProcessedBlocks.contents,
            ~registeredEvents,
            ~loadLayer,
            ~config,
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
let processEventBatch = (
  ~eventBatch: array<Types.eventBatchQueueItem>,
  ~inMemoryStore: InMemoryStore.t,
  ~latestProcessedBlocks: EventsProcessed.t,
  ~checkContractIsRegistered,
  ~registeredEvents: RegisteredEvents.t,
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
        ~registeredEvents,
        ~checkContractIsRegistered,
        ~logger,
        ~inMemoryStore,
      )
      ->propogate

    (await eventsBeforeDynamicRegistrations
    ->runLoaders(~registeredEvents, ~loadLayer, ~inMemoryStore, ~logger))
    ->propogate

    let elapsedAfterLoad = timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    let latestProcessedBlocks =
      (await eventsBeforeDynamicRegistrations
      ->runHandlers(
        ~registeredEvents,
        ~inMemoryStore,
        ~latestProcessedBlocks,
        ~logger,
        ~loadLayer,
        ~config,
      ))
      ->propogate

    let elapsedTimeAfterProcess = timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    switch await DbFunctions.sql->IO.executeBatch(~inMemoryStore) {
    | exception exn =>
      exn->ErrorHandling.make(~msg="Failed writing batch to database", ~logger)->Error->propogate
    | () => ()
    }

    let elapsedTimeAfterDbWrite = timeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis
    registerProcessEventBatchMetrics(
      ~logger,
      ~batchSize=eventsBeforeDynamicRegistrations->Array.length,
      ~loadDuration=elapsedAfterLoad,
      ~handlerDuration=elapsedTimeAfterProcess - elapsedAfterLoad,
      ~dbWriteDuration=elapsedTimeAfterDbWrite - elapsedTimeAfterProcess,
    )

    Ok({latestProcessedBlocks, dynamicContractRegistrations})
  })
}
