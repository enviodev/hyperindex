let addEventToRawEvents = (
  event: Types.eventLog<'a>,
  ~chainId,
  ~jsonSerializedParams: Js.Json.t,
  ~eventName: Types.eventName,
) => {
  let {
    blockNumber,
    logIndex,
    transactionIndex,
    transactionHash,
    srcAddress,
    blockHash,
    blockTimestamp,
  } = event

  let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
  let rawEvent: Types.rawEventsEntity = {
    chainId,
    eventId: eventId->Ethers.BigInt.toString,
    blockNumber,
    logIndex,
    transactionIndex,
    transactionHash,
    srcAddress,
    blockHash,
    blockTimestamp,
    eventType: eventName->Types.eventName_encode,
    params: jsonSerializedParams->Js.Json.stringify,
  }

  IO.InMemoryStore.RawEvents.setRawEvents(~entity=rawEvent, ~crud=Create)
}
let eventRouter = (event: Types.eventAndContext, ~chainId) => {
  switch event {
  | GravatarContract_TestEventWithContext(event, context) => {
      let jsonSerializedParams =
        event.params->Types.GravatarContract.TestEventEvent.eventArgs_encode
      event->addEventToRawEvents(
        ~chainId,
        ~jsonSerializedParams,
        ~eventName=GravatarContract_TestEventEvent,
      )

      Handlers.GravatarContract.getTestEventHandler()(~event, ~context)
    }

  | GravatarContract_NewGravatarWithContext(event, context) => {
      let jsonSerializedParams =
        event.params->Types.GravatarContract.NewGravatarEvent.eventArgs_encode
      event->addEventToRawEvents(
        ~chainId,
        ~jsonSerializedParams,
        ~eventName=GravatarContract_NewGravatarEvent,
      )

      Handlers.GravatarContract.getNewGravatarHandler()(~event, ~context)
    }

  | GravatarContract_UpdatedGravatarWithContext(event, context) => {
      let jsonSerializedParams =
        event.params->Types.GravatarContract.UpdatedGravatarEvent.eventArgs_encode
      event->addEventToRawEvents(
        ~chainId,
        ~jsonSerializedParams,
        ~eventName=GravatarContract_UpdatedGravatarEvent,
      )

      Handlers.GravatarContract.getUpdatedGravatarHandler()(~event, ~context)
    }

  | NftFactoryContract_SimpleNftCreatedWithContext(event, context) => {
      let jsonSerializedParams =
        event.params->Types.NftFactoryContract.SimpleNftCreatedEvent.eventArgs_encode
      event->addEventToRawEvents(
        ~chainId,
        ~jsonSerializedParams,
        ~eventName=NftFactoryContract_SimpleNftCreatedEvent,
      )

      Handlers.NftFactoryContract.getSimpleNftCreatedHandler()(~event, ~context)
    }

  | SimpleNftContract_TransferWithContext(event, context) => {
      let jsonSerializedParams =
        event.params->Types.SimpleNftContract.TransferEvent.eventArgs_encode
      event->addEventToRawEvents(
        ~chainId,
        ~jsonSerializedParams,
        ~eventName=SimpleNftContract_TransferEvent,
      )

      Handlers.SimpleNftContract.getTransferHandler()(~event, ~context)
    }
  }
}

type readEntitiesResult = {
  blockNumber: int,
  logIndex: int,
  entityReads: array<Types.entityRead>,
  eventAndContext: Types.eventAndContext,
}

let rec loadReadEntitiesInner = async (
  eventBatch: array<Types.event>,
  ~chainConfig: Config.chainConfig,
  ~blocksProcessed: EventFetching.blocksProcessed,
) => {
  let loadNestedReadEntities = async (
    ~blockNumber,
    ~logIndex,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ) => {
    let addressInterfaceMapping = Js.Dict.empty()

    let eventFilters = dynamicContracts->Belt.Array.flatMap(contract => {
      EventFetching.getSingleContractEventFilters(
        ~contractAddress=contract.contractAddress,
        ~chainConfig,
        ~addressInterfaceMapping,
      )
    })

    let (fetchedEvents, nestedBlocksProcessed) = await EventFetching.getContractEventsOnFilters(
      ~eventFilters,
      ~addressInterfaceMapping,
      ~fromBlock=blockNumber,
      ~toBlock=blocksProcessed.to,
      ~minFromBlockLogIndex=logIndex + 1,
      ~maxBlockInterval=blocksProcessed.to - blockNumber + 1,
      ~chainId=chainConfig.chainId,
      ~provider=chainConfig.provider,
      (),
    )

    await fetchedEvents->loadReadEntitiesInner(~chainConfig, ~blocksProcessed=nestedBlocksProcessed)
  }

  let baseResults: array<readEntitiesResult> = []
  let nestedResults: array<array<readEntitiesResult>> = []

  let chainId = chainConfig.chainId

  for i in 0 to eventBatch->Belt.Array.length - 1 {
    let event = eventBatch[i]

    baseResults
    ->Js.Array2.push(
      switch event {
      | GravatarContract_TestEvent(event) => {
          let contextHelper = Context.GravatarContract.TestEventEvent.contextCreator(
            ~chainId,
            ~event,
          )
          Handlers.GravatarContract.getTestEventLoadEntities()(
            ~event,
            ~context=contextHelper.getLoaderContext(),
          )
          let {logIndex, blockNumber} = event
          let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
          let context = contextHelper.getContext(
            ~eventData={chainId, eventId: eventId->Ethers.BigInt.toString},
          )

          let dynamicContracts = contextHelper.getAddedDynamicContractRegistrations()

          nestedResults
          ->Js.Array2.push(await loadNestedReadEntities(~blockNumber, ~logIndex, ~dynamicContracts))
          ->ignore

          {
            entityReads: contextHelper.getEntitiesToLoad(),
            eventAndContext: Types.GravatarContract_TestEventWithContext(event, context),
            blockNumber,
            logIndex,
          }
        }

      | GravatarContract_NewGravatar(event) => {
          let contextHelper = Context.GravatarContract.NewGravatarEvent.contextCreator(
            ~chainId,
            ~event,
          )
          Handlers.GravatarContract.getNewGravatarLoadEntities()(
            ~event,
            ~context=contextHelper.getLoaderContext(),
          )
          let {logIndex, blockNumber} = event
          let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
          let context = contextHelper.getContext(
            ~eventData={chainId, eventId: eventId->Ethers.BigInt.toString},
          )

          let dynamicContracts = contextHelper.getAddedDynamicContractRegistrations()

          nestedResults
          ->Js.Array2.push(await loadNestedReadEntities(~blockNumber, ~logIndex, ~dynamicContracts))
          ->ignore

          {
            entityReads: contextHelper.getEntitiesToLoad(),
            eventAndContext: Types.GravatarContract_NewGravatarWithContext(event, context),
            blockNumber,
            logIndex,
          }
        }

      | GravatarContract_UpdatedGravatar(event) => {
          let contextHelper = Context.GravatarContract.UpdatedGravatarEvent.contextCreator(
            ~chainId,
            ~event,
          )
          Handlers.GravatarContract.getUpdatedGravatarLoadEntities()(
            ~event,
            ~context=contextHelper.getLoaderContext(),
          )
          let {logIndex, blockNumber} = event
          let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
          let context = contextHelper.getContext(
            ~eventData={chainId, eventId: eventId->Ethers.BigInt.toString},
          )

          let dynamicContracts = contextHelper.getAddedDynamicContractRegistrations()

          nestedResults
          ->Js.Array2.push(await loadNestedReadEntities(~blockNumber, ~logIndex, ~dynamicContracts))
          ->ignore

          {
            entityReads: contextHelper.getEntitiesToLoad(),
            eventAndContext: Types.GravatarContract_UpdatedGravatarWithContext(event, context),
            blockNumber,
            logIndex,
          }
        }

      | NftFactoryContract_SimpleNftCreated(event) => {
          let contextHelper = Context.NftFactoryContract.SimpleNftCreatedEvent.contextCreator(
            ~chainId,
            ~event,
          )
          Handlers.NftFactoryContract.getSimpleNftCreatedLoadEntities()(
            ~event,
            ~context=contextHelper.getLoaderContext(),
          )
          let {logIndex, blockNumber} = event
          let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
          let context = contextHelper.getContext(
            ~eventData={chainId, eventId: eventId->Ethers.BigInt.toString},
          )

          let dynamicContracts = contextHelper.getAddedDynamicContractRegistrations()

          nestedResults
          ->Js.Array2.push(await loadNestedReadEntities(~blockNumber, ~logIndex, ~dynamicContracts))
          ->ignore

          {
            entityReads: contextHelper.getEntitiesToLoad(),
            eventAndContext: Types.NftFactoryContract_SimpleNftCreatedWithContext(event, context),
            blockNumber,
            logIndex,
          }
        }

      | SimpleNftContract_Transfer(event) => {
          let contextHelper = Context.SimpleNftContract.TransferEvent.contextCreator(
            ~chainId,
            ~event,
          )
          Handlers.SimpleNftContract.getTransferLoadEntities()(
            ~event,
            ~context=contextHelper.getLoaderContext(),
          )
          let {logIndex, blockNumber} = event
          let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
          let context = contextHelper.getContext(
            ~eventData={chainId, eventId: eventId->Ethers.BigInt.toString},
          )

          let dynamicContracts = contextHelper.getAddedDynamicContractRegistrations()

          if Belt.Array.length(dynamicContracts) > 0 {
            nestedResults
            ->Js.Array2.push(
              await loadNestedReadEntities(~blockNumber, ~logIndex, ~dynamicContracts),
            )
            ->ignore
          }

          {
            entityReads: contextHelper.getEntitiesToLoad(),
            eventAndContext: Types.SimpleNftContract_TransferWithContext(event, context),
            blockNumber,
            logIndex,
          }
        }
      },
    )
    ->ignore
  }

  // Flatten the nested results into the origin results, but preserving the total order
  let pairOrder = ({blockNumber, logIndex}) => (blockNumber, logIndex)

  Belt.Array.reduce(nestedResults, baseResults, (acc, additionalResults) =>
    Utils.mergeSorted(pairOrder, acc, additionalResults)
  )
}

let loadReadEntities = async (
  eventBatch: array<Types.event>,
  ~chainConfig: Config.chainConfig,
  ~blocksProcessed: EventFetching.blocksProcessed,
): array<Types.eventAndContext> => {
  let result = await eventBatch->loadReadEntitiesInner(~chainConfig, ~blocksProcessed)

  let flattenResult = ({entityReads, eventAndContext}) => (entityReads, eventAndContext)

  let (readEntitiesGrouped, contexts): (
    array<array<Types.entityRead>>,
    array<Types.eventAndContext>,
  ) =
    result->Belt.Array.map(flattenResult)->Belt.Array.unzip

  let readEntities = readEntitiesGrouped->Belt.Array.concatMany

  await DbFunctions.sql->IO.loadEntities(readEntities)

  contexts
}

let processEventBatch = async (
  eventBatch: array<Types.event>,
  ~chainConfig,
  ~blocksProcessed: EventFetching.blocksProcessed,
) => {
  IO.InMemoryStore.resetStore()

  let eventBatchAndContext = await eventBatch->loadReadEntities(~chainConfig, ~blocksProcessed)

  eventBatchAndContext->Belt.Array.forEach(event =>
    event->eventRouter(~chainId=chainConfig.chainId)
  )

  await DbFunctions.sql->IO.executeBatch
}
