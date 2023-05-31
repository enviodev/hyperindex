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
    eventId,
    blockNumber,
    logIndex,
    transactionIndex,
    transactionHash,
    srcAddress,
    blockHash,
    blockTimestamp,
    eventType: eventName->Types.eventName_encode,
    params: jsonSerializedParams,
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

let loadReadEntities = async (eventBatch: array<Types.event>, ~chainId: int): array<
  Types.eventAndContext,
> => {
  let result: array<(
    array<Types.entityRead>,
    Types.eventAndContext,
  )> = eventBatch->Belt.Array.map(event => {
    switch event {
    | GravatarContract_TestEvent(event) => {
        let contextHelper = Context.GravatarContract.TestEventEvent.contextCreator()
        Handlers.GravatarContract.getTestEventLoadEntities()(
          ~event,
          ~context=contextHelper.getLoaderContext(),
        )
        let {logIndex, blockNumber} = event
        let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
        let context = contextHelper.getContext(~eventData={chainId, eventId})
        (
          contextHelper.getEntitiesToLoad(),
          Types.GravatarContract_TestEventWithContext(event, context),
        )
      }

    | GravatarContract_NewGravatar(event) => {
        let contextHelper = Context.GravatarContract.NewGravatarEvent.contextCreator()
        Handlers.GravatarContract.getNewGravatarLoadEntities()(
          ~event,
          ~context=contextHelper.getLoaderContext(),
        )
        let {logIndex, blockNumber} = event
        let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
        let context = contextHelper.getContext(~eventData={chainId, eventId})
        (
          contextHelper.getEntitiesToLoad(),
          Types.GravatarContract_NewGravatarWithContext(event, context),
        )
      }

    | GravatarContract_UpdatedGravatar(event) => {
        let contextHelper = Context.GravatarContract.UpdatedGravatarEvent.contextCreator()
        Handlers.GravatarContract.getUpdatedGravatarLoadEntities()(
          ~event,
          ~context=contextHelper.getLoaderContext(),
        )
        let {logIndex, blockNumber} = event
        let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
        let context = contextHelper.getContext(~eventData={chainId, eventId})
        (
          contextHelper.getEntitiesToLoad(),
          Types.GravatarContract_UpdatedGravatarWithContext(event, context),
        )
      }

    | NftFactoryContract_SimpleNftCreated(event) => {
        let contextHelper = Context.NftFactoryContract.SimpleNftCreatedEvent.contextCreator()
        Handlers.NftFactoryContract.getSimpleNftCreatedLoadEntities()(
          ~event,
          ~context=contextHelper.getLoaderContext(),
        )
        let {logIndex, blockNumber} = event
        let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
        let context = contextHelper.getContext(~eventData={chainId, eventId})
        (
          contextHelper.getEntitiesToLoad(),
          Types.NftFactoryContract_SimpleNftCreatedWithContext(event, context),
        )
      }

    | SimpleNftContract_Transfer(event) => {
        let contextHelper = Context.SimpleNftContract.TransferEvent.contextCreator()
        Handlers.SimpleNftContract.getTransferLoadEntities()(
          ~event,
          ~context=contextHelper.getLoaderContext(),
        )
        let {logIndex, blockNumber} = event
        let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
        let context = contextHelper.getContext(~eventData={chainId, eventId})
        (
          contextHelper.getEntitiesToLoad(),
          Types.SimpleNftContract_TransferWithContext(event, context),
        )
      }
    }
  })

  let (readEntitiesGrouped, contexts): (
    array<array<Types.entityRead>>,
    array<Types.eventAndContext>,
  ) =
    result->Belt.Array.unzip

  let readEntities = readEntitiesGrouped->Belt.Array.concatMany

  await DbFunctions.sql->IO.loadEntities(readEntities)

  contexts
}

let processEventBatch = async (eventBatch: array<Types.event>, ~chainId) => {
  IO.InMemoryStore.resetStore()

  let eventBatchAndContext = await eventBatch->loadReadEntities(~chainId)

  eventBatchAndContext->Belt.Array.forEach(event => event->eventRouter(~chainId))

  await DbFunctions.sql->IO.executeBatch
}
