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
  eventItem: Internal.eventItem,
  ~inMemoryStore: InMemoryStore.t,
  ~isPreRegisteringDynamicContracts,
) => {
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
      isPreRegisteringDynamicContracts,
    },
  )
}

type dynamicContractRegistrations = {
  dynamicContractsByChain: dict<array<TablesStatic.DynamicContractRegistry.t>>,
  unprocessedBatch: array<Internal.eventItem>,
}

let addToDynamicContractRegistrations = (
  eventItem: Internal.eventItem,
  ~dynamicContracts,
  ~dynamicContractsByChain,
  ~unprocessedBatch,
) => {
  //If there are any dynamic contract registrations, put this item in the unprocessedBatch flagged
  //with "hasRegisteredDynamicContracts" and return the same list of entitiesToLoad without the
  //current item
  let unprocessedBatch = [
    ...unprocessedBatch,
    {
      ...eventItem,
      hasRegisteredDynamicContracts: true,
    },
  ]

  switch dynamicContracts {
  | [] => ()
  | dynamicContracts =>
    let key = eventItem.chain->ChainMap.Chain.toString
    dynamicContractsByChain->Js.Dict.set(
      key,
      dynamicContractsByChain
      ->Utils.Dict.dangerouslyGetNonOption(key)
      ->Option.getWithDefault([])
      ->Array.concat(dynamicContracts),
    )
  }

  {
    unprocessedBatch,
    dynamicContractsByChain,
  }
}

let checkContractIsInCurrentRegistrations = (
  ~dynamicContractRegistrations: option<dynamicContractRegistrations>,
  ~chain,
  ~contractAddress,
) => {
  switch dynamicContractRegistrations {
  | Some(dynamicContracts) =>
    dynamicContracts.dynamicContractsByChain
    ->Utils.Dict.dangerouslyGetNonOption(chain->ChainMap.Chain.toString)
    ->Option.mapWithDefault(false, dcs =>
      dcs->Array.some(dc => dc.contractAddress == contractAddress)
    )

  | None => false
  }
}

let runEventContractRegister = (
  contractRegister: Internal.contractRegister,
  ~eventItem: Internal.eventItem,
  ~logger,
  ~checkContractIsRegistered,
  ~dynamicContractRegistrations: option<dynamicContractRegistrations>,
  ~inMemoryStore,
  ~preRegisterLatestProcessedBlocks=?,
  ~shouldSaveHistory,
) => {
  let isPreRegistered = preRegisterLatestProcessedBlocks->Option.isSome

  let addedDynamicContracts = []
  let addedDynamicContractsAddresses = Utils.Set.make()

  let onRegister = (~contractAddress, ~contractName) => {
    let {chain, timestamp, blockNumber, logIndex} = eventItem

    let chainId = chain->ChainMap.Chain.toChainId
    let dc: TablesStatic.DynamicContractRegistry.t = {
      id: ContextEnv.makeDynamicContractId(~chainId, ~contractAddress),
      chainId,
      registeringEventBlockNumber: blockNumber,
      registeringEventLogIndex: logIndex,
      registeringEventName: eventItem.eventName,
      registeringEventContractName: eventItem.contractName,
      registeringEventSrcAddress: eventItem.event.srcAddress,
      registeringEventBlockTimestamp: timestamp,
      contractAddress,
      contractType: contractName,
      isPreRegistered,
    }

    if (
      // Prevent duplications for storing and registering dynamic contracts
      !(addedDynamicContractsAddresses->Utils.Set.has(contractAddress)) &&
      !checkContractIsRegistered(~chain, ~contractAddress, ~contractName) &&
      !checkContractIsInCurrentRegistrations(
        ~dynamicContractRegistrations,
        ~chain,
        ~contractAddress,
      )
    ) {
      addedDynamicContractsAddresses->Utils.Set.add(contractAddress)->ignore
      addedDynamicContracts->Js.Array2.push(dc)->ignore

      let eventIdentifier: Types.eventIdentifier = {
        chainId,
        blockTimestamp: timestamp,
        blockNumber,
        logIndex,
      }

      inMemoryStore.InMemoryStore.entities
      ->InMemoryStore.EntityTables.get(module(TablesStatic.DynamicContractRegistry))
      ->InMemoryTable.Entity.set(
        Set(dc)->Types.mkEntityUpdate(~eventIdentifier, ~entityId=dc.id),
        ~shouldSaveHistory,
      )
    }
  }

  let contextEnv = ContextEnv.make(~eventItem, ~logger)
  switch contractRegister(contextEnv->ContextEnv.getContractRegisterArgs(~onRegister)) {
  | exception exn =>
    exn
    ->ErrorHandling.make(
      ~msg="Event contractRegister failed, please fix the error to keep the indexer running smoothly",
      ~logger=contextEnv.logger,
    )
    ->Error
  | () =>
    let val = switch (addedDynamicContracts, dynamicContractRegistrations) {
    | ([], None) => None
    | (dynamicContracts, Some({dynamicContractsByChain, unprocessedBatch})) =>
      eventItem
      ->addToDynamicContractRegistrations(
        ~dynamicContracts,
        ~dynamicContractsByChain,
        ~unprocessedBatch,
      )
      ->Some
    | (dynamicContracts, None) =>
      eventItem
      ->addToDynamicContractRegistrations(
        ~dynamicContracts,
        ~dynamicContractsByChain=Js.Dict.empty(),
        ~unprocessedBatch=[],
      )
      ->Some
    }

    switch preRegisterLatestProcessedBlocks {
    | Some(latestProcessedBlocks) =>
      eventItem->updateEventSyncState(~inMemoryStore, ~isPreRegisteringDynamicContracts=true)
      latestProcessedBlocks :=
        latestProcessedBlocks.contents->EventsProcessed.updateEventsProcessed(
          ~chain=eventItem.chain,
          ~blockNumber=eventItem.blockNumber,
        )
    | None => ()
    }

    val->Ok
  }
}

let runEventLoader = async (~contextEnv, ~loader: Internal.loader, ~inMemoryStore, ~loadLayer) => {
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
  let {
    event,
    eventName,
    contractName,
    chain,
    blockNumber,
    paramsRawEventSchema,
    timestamp: blockTimestamp,
  } = eventItem
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
    ->S.reverseConvertOrThrow(paramsRawEventSchema)
    ->(Utils.magic: unknown => Js.Json.t)

  let rawEvent: TablesStatic.RawEvents.t = {
    chainId,
    eventId,
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
  eventItem: Internal.eventItem,
  ~loader,
  ~handler,
  ~inMemoryStore,
  ~logger,
  ~loadLayer,
  ~shouldSaveHistory,
) => {
  open ErrorHandling.ResultPropogateEnv
  runAsyncEnv(async () => {
    let contextEnv = ContextEnv.make(~eventItem, ~logger)

    //Include the load in time before handler
    let timeBeforeHandler = Hrtime.makeTimer()

    let loaderReturn = switch loader {
    | Some(loader) =>
      (await runEventLoader(~contextEnv, ~loader, ~inMemoryStore, ~loadLayer))->propogate
    | None => (%raw(`undefined`): Internal.loaderReturn)
    }

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
          ~label=`${eventItem.contractName} ${eventItem.eventName} Handler (ms)`,
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
  ~latestProcessedBlocks,
  ~inMemoryStore,
  ~logger,
  ~loadLayer,
  ~config: Config.t,
  ~isInReorgThreshold,
) => {
  let result = switch eventItem.handler {
  | None => Ok()
  | Some(handler) =>
    await eventItem->runEventHandler(
      ~loader=eventItem.loader,
      ~handler,
      ~inMemoryStore,
      ~logger,
      ~loadLayer,
      ~shouldSaveHistory=config->Config.shouldSaveHistory(~isInReorgThreshold),
    )
  }

  result->Result.map(() => {
    eventItem->updateEventSyncState(~inMemoryStore, ~isPreRegisteringDynamicContracts=false)

    if config.enableRawEvents {
      eventItem->addEventToRawEvents(~inMemoryStore)
    }

    latestProcessedBlocks->EventsProcessed.updateEventsProcessed(
      ~chain=eventItem.chain,
      ~blockNumber=eventItem.blockNumber,
    )
  })
}

let addToUnprocessedBatch = (eventItem: Internal.eventItem, dynamicContractRegistrations) => {
  {
    ...dynamicContractRegistrations,
    unprocessedBatch: [...dynamicContractRegistrations.unprocessedBatch, eventItem],
  }
}

let rec registerDynamicContracts = (
  eventBatch: array<Internal.eventItem>,
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
  | Some(eventItem) =>
    let dynamicContractRegistrationsResult = if (
      eventItem.hasRegisteredDynamicContracts->Option.getWithDefault(false)
    ) {
      //If an item has already been registered, it would have been
      //put back on the arbitrary events queue and is now being reprocessed
      dynamicContractRegistrations
      ->Option.map(dynamicContractRegistrations =>
        addToUnprocessedBatch(eventItem, dynamicContractRegistrations)
      )
      ->Ok
    } else {
      switch eventItem {
      | {contractRegister: Some(handler)} =>
        handler->runEventContractRegister(
          ~logger,
          ~checkContractIsRegistered,
          ~eventItem,
          ~dynamicContractRegistrations,
          ~inMemoryStore,
          ~preRegisterLatestProcessedBlocks?,
          ~shouldSaveHistory,
        )
      | _ =>
        dynamicContractRegistrations
        ->Option.map(dynamicContractRegistrations =>
          addToUnprocessedBatch(eventItem, dynamicContractRegistrations)
        )
        ->Ok
      }
    }

    switch dynamicContractRegistrationsResult {
    | Ok(dynamicContractRegistrations) =>
      if dynamicContractRegistrations->Option.isNone {
        //Mutate for performance (could otherwise use concat?)
        eventsBeforeDynamicRegistrations->Js.Array2.push(eventItem)->ignore
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

let runLoaders = (eventBatch: array<Internal.eventItem>, ~loadLayer, ~inMemoryStore, ~logger) => {
  open ErrorHandling.ResultPropogateEnv
  runAsyncEnv(async () => {
    // We don't actually need loader returns,
    // since we'll need to rerun each loader separately
    // before the handler, to get the uptodate entities from the in memory store.
    // Still need to propogate the errors.
    let _: array<Internal.loaderReturn> =
      await eventBatch
      ->Array.keepMap(eventItem => {
        switch eventItem {
        | {loader: Some(loader)} => {
            let contextEnv = ContextEnv.make(~eventItem, ~logger)
            runEventLoader(~contextEnv, ~loader, ~inMemoryStore, ~loadLayer)
            ->Promise.thenResolve(propogate)
            ->Some
          }
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
      let eventItem = eventBatch->Js.Array2.unsafe_get(i)

      latestProcessedBlocks :=
        (
          await runHandler(
            eventItem,
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
  ~latestProcessedBlocks: EventsProcessed.t,
) => {
  logger->Logging.childTrace({
    "msg": "Finished processing batch",
    "batch_size": batchSize,
    "loader_time_elapsed": loadDuration,
    "handlers_time_elapsed": handlerDuration,
    "write_time_elapsed": dbWriteDuration,
  })

  Prometheus.incrementLoadEntityDurationCounter(~duration=loadDuration)
  Prometheus.incrementEventRouterDurationCounter(~duration=handlerDuration)
  Prometheus.incrementExecuteBatchDurationCounter(~duration=dbWriteDuration)
  latestProcessedBlocks
  ->ChainMap.entries
  ->Array.forEach(((chain, {numEventsProcessed})) => {
    Prometheus.setEventsProcessedGuage(
      ~chainId=chain->ChainMap.Chain.toChainId,
      ~number=numEventsProcessed,
    )
  })
}

type batchProcessed = {
  latestProcessedBlocks: EventsProcessed.t,
  dynamicContractRegistrations: option<dynamicContractRegistrations>,
}

let getDynamicContractRegistrations = (
  ~eventBatch: array<Internal.eventItem>,
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

    switch await Db.sql->IO.executeBatch(
      ~inMemoryStore,
      //We only preregister below the reorg threshold so it can be hardcoded as false
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
  ~eventBatch: array<Internal.eventItem>,
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
      eventsBeforeDynamicRegistrations: array<Internal.eventItem>,
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

    switch await Db.sql->IO.executeBatch(~inMemoryStore, ~isInReorgThreshold, ~config) {
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
      ~latestProcessedBlocks,
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
