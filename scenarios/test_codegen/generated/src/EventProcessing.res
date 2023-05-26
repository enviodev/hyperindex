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
