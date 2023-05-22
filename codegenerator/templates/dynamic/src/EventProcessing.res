let addEventToRawEvents = (event: Types.eventLog<'a>, ~chainId, ~jsonSerializedParams: Js.Json.t, ~eventName: Types.eventName) => {
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
{{#each contracts as | contract |}}
{{#each contract.events as | event |}}
  | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}WithContext(event, context) => {
  let jsonSerializedParams = event.params->Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs_encode
  event->addEventToRawEvents(~chainId, ~jsonSerializedParams, ~eventName={{contract.name.capitalized}}Contract_{{event.name.capitalized}}Event
)

  Handlers.{{contract.name.capitalized}}Contract.get{{event.name.capitalized}}Handler()(~event, ~context)
  }
{{/each}}
{{/each}}
  }
}

let loadReadEntities = async (eventBatch: array<Types.event>, ~chainId: int): array<Types.eventAndContext> => {
  let result: array<(
    array<Types.entityRead>,
    Types.eventAndContext,
  )> = eventBatch->Belt.Array.map(event => {
      switch event {
{{#each contracts as | contract |}}
{{#each contract.events as | event |}}
        | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}(event) => {

        let contextHelper = Context.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.contextCreator()
        Handlers.{{contract.name.capitalized}}Contract.get{{event.name.capitalized}}LoadEntities()(~event, ~context=contextHelper.getLoaderContext())
        let { logIndex, blockNumber } = event
        let eventId = EventUtils.packEventIndex(~logIndex, ~blockNumber)
        let context = contextHelper.getContext(~eventData={chainId, eventId})
        (contextHelper.getEntitiesToLoad(), Types.{{contract.name.capitalized}}Contract_{{event.name.capitalized}}WithContext(event, context))
        }
{{/each}}
{{/each}}
      }
    })


  let (readEntitiesGrouped, contexts): (array<array<Types.entityRead>>, array<Types.eventAndContext>) =
  result->Belt.Array.unzip

  let readEntities = readEntitiesGrouped->Belt.Array.concatMany

  await DbFunctions.sql->IO.loadEntities(readEntities)

  contexts
}

let processEventBatch = async (eventBatch: array<Types.event>, ~chainId) => {
  let eventBatchAndContext = await eventBatch->loadReadEntities(~chainId)

  eventBatchAndContext->Belt.Array.forEach(event => event->eventRouter(~chainId))

  await DbFunctions.sql->IO.executeBatch
}
