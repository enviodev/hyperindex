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

type rec readEntitiesResultPromise = {
  blockNumber: int,
  logIndex: int,
  promise: promise<(
    array<Types.entityRead>,
    Types.eventAndContext,
    option<array<readEntitiesResultPromise>>,
  )>,
}

let rec loadReadEntitiesInner = async (
  eventBatch: array<EventFetching.eventBatchPromise>,
  ~chainConfig: Config.chainConfig,
  ~blocksProcessed: EventFetching.blocksProcessed,
  ~blockLoader,
): array<readEntitiesResultPromise> => {
  // Recursively load entities
  let loadNestedReadEntities = (
    ~blockNumber,
    ~logIndex,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ): promise<array<readEntitiesResultPromise>> => {
    let addressInterfaceMapping = Js.Dict.empty()

    let eventFilters = dynamicContracts->Belt.Array.flatMap(contract => {
      EventFetching.getSingleContractEventFilters(
        ~contractAddress=contract.contractAddress,
        ~chainConfig,
        ~addressInterfaceMapping,
      )
    })

    EventFetching.getContractEventsOnFilters(
      ~eventFilters,
      ~addressInterfaceMapping,
      ~fromBlock=blockNumber,
      ~toBlock=blocksProcessed.to,
      ~minFromBlockLogIndex=logIndex + 1,
      ~maxBlockInterval=blocksProcessed.to - blockNumber + 1,
      ~chainId=chainConfig.chainId,
      ~provider=chainConfig.provider,
      ~blockLoader,
      (),
    )->Promise.then(((fetchedEvents, nestedBlocksProcessed)) => {
      fetchedEvents->loadReadEntitiesInner(
        ~chainConfig,
        ~blockLoader,
        ~blocksProcessed=nestedBlocksProcessed,
      )
    })
  }

  let baseResults: array<readEntitiesResultPromise> = []

  let chainId = chainConfig.chainId

  for i in 0 to eventBatch->Belt.Array.length - 1 {
    let {blockNumber, logIndex, eventPromise} = eventBatch[i]
    baseResults
    ->Js.Array2.push({
      blockNumber,
      logIndex,
      promise: eventPromise->Promise.then(async event =>
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

            (
              contextHelper.getEntitiesToLoad(),
              Types.GravatarContract_TestEventWithContext(event, context),
              if Belt.Array.length(dynamicContracts) > 0 {
                Some(await loadNestedReadEntities(~blockNumber, ~logIndex, ~dynamicContracts))
              } else {
                None
              },
            )
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

            (
              contextHelper.getEntitiesToLoad(),
              Types.GravatarContract_NewGravatarWithContext(event, context),
              if Belt.Array.length(dynamicContracts) > 0 {
                Some(await loadNestedReadEntities(~blockNumber, ~logIndex, ~dynamicContracts))
              } else {
                None
              },
            )
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

            (
              contextHelper.getEntitiesToLoad(),
              Types.GravatarContract_UpdatedGravatarWithContext(event, context),
              if Belt.Array.length(dynamicContracts) > 0 {
                Some(await loadNestedReadEntities(~blockNumber, ~logIndex, ~dynamicContracts))
              } else {
                None
              },
            )
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

            (
              contextHelper.getEntitiesToLoad(),
              Types.NftFactoryContract_SimpleNftCreatedWithContext(event, context),
              if Belt.Array.length(dynamicContracts) > 0 {
                Some(await loadNestedReadEntities(~blockNumber, ~logIndex, ~dynamicContracts))
              } else {
                None
              },
            )
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

            (
              contextHelper.getEntitiesToLoad(),
              Types.SimpleNftContract_TransferWithContext(event, context),
              if Belt.Array.length(dynamicContracts) > 0 {
                Some(await loadNestedReadEntities(~blockNumber, ~logIndex, ~dynamicContracts))
              } else {
                None
              },
            )
          }
        }
      ),
    })
    ->ignore
  }

  baseResults
}

type rec nestedResult = {
  result: readEntitiesResult,
  nested: option<array<nestedResult>>,
}
// Given a read entities promise, unwrap just the top level result
let unwrap = async (p: readEntitiesResultPromise): readEntitiesResult => {
  let (er, ec, _) = await p.promise
  {
    blockNumber: p.blockNumber,
    logIndex: p.logIndex,
    entityReads: er,
    eventAndContext: ec,
  }
}

// Recursively await the promises to get their results
let rec recurseEntityPromises = async (p: readEntitiesResultPromise): nestedResult => {
  let (_, _, nested) = await p.promise

  {
    result: await unwrap(p),
    nested: switch nested {
    | None => None
    | Some(xs) => Some(await xs->Belt.Array.map(recurseEntityPromises)->Promise.all)
    },
  }
}

// This function is used to sort results according to their order in the chain
let resultPosition = ({blockNumber, logIndex}: readEntitiesResult) => (blockNumber, logIndex)

// Given the recursively awaited results, flatten them down into a single list using chain order
let rec flattenNested = (xs: array<nestedResult>): array<readEntitiesResult> => {
  let baseResults = xs->Belt.Array.map(({result}) => result)
  let nestedNestedResults = xs->Belt.Array.keepMap(({nested}) => nested)
  let nestedResults = nestedNestedResults->Belt.Array.map(flattenNested)
  Belt.Array.reduce(nestedResults, baseResults, (acc, additionalResults) =>
    Utils.mergeSorted(resultPosition, acc, additionalResults)
  )
}

let loadReadEntities = async (
  eventBatch: array<EventFetching.eventBatchPromise>,
  ~chainConfig: Config.chainConfig,
  ~blockLoader,
  ~blocksProcessed: EventFetching.blocksProcessed,
): array<Types.eventAndContext> => {
  let batch = await eventBatch->loadReadEntitiesInner(~chainConfig, ~blocksProcessed, ~blockLoader)

  let nestedResults = await batch->Belt.Array.map(recurseEntityPromises)->Promise.all
  let mergedResults = flattenNested(nestedResults)

  // Project the result record into a tuple, so that we can unzip the two payloads.
  let resultToPair = ({entityReads, eventAndContext}) => (entityReads, eventAndContext)

  let (readEntitiesGrouped, contexts): (
    array<array<Types.entityRead>>,
    array<Types.eventAndContext>,
  ) =
    mergedResults->Belt.Array.map(resultToPair)->Belt.Array.unzip

  let readEntities = readEntitiesGrouped->Belt.Array.concatMany

  await DbFunctions.sql->IO.loadEntities(readEntities)

  contexts
}

let processEventBatch = async (
  eventBatch: array<EventFetching.eventBatchPromise>,
  ~chainConfig,
  ~blocksProcessed: EventFetching.blocksProcessed,
  ~blockLoader,
) => {
  IO.InMemoryStore.resetStore()

  let eventBatchAndContext =
    await eventBatch->loadReadEntities(~chainConfig, ~blockLoader, ~blocksProcessed)

  eventBatchAndContext->Belt.Array.forEach(event =>
    event->eventRouter(~chainId=chainConfig.chainId)
  )

  await DbFunctions.sql->IO.executeBatch
}
