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

  IO.InMemoryStore.RawEvents.setRawEvents(~rawEvents=rawEvent, ~crud=Create)
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
  }
}

let loadReadEntities = async (eventBatch: array<Types.event>): array<Types.eventAndContext> => {
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
        let context = contextHelper.getContext()
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
        let context = contextHelper.getContext()
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
        let context = contextHelper.getContext()
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

  await readEntities->IO.loadEntities

  contexts
}

let processEventBatch = async (eventBatch: array<Types.event>, ~chainId) => {
  let ioBatch = IO.createBatch()

  let eventBatchAndContext = await eventBatch->loadReadEntities

  eventBatchAndContext->Belt.Array.forEach(event => event->eventRouter(~chainId))

  await ioBatch->IO.executeBatch
}
