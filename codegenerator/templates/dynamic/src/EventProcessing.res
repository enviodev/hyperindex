let addEventToRawEvents = (event: Types.eventLog<'a>, ~jsonSerializedParams: Js.Json.t, ~eventName: Types.eventName) => {
  let chainId = 137 //TODO: add this to eventLog type

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
let eventRouter = (event: Types.eventAndContext) => {
  switch event {
{{#each contracts as | contract |}}
{{#each contract.events as | event |}}
  | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}WithContext(event, context) => {
  let jsonSerializedParams = event.params->Types.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.eventArgs_encode
  event->addEventToRawEvents(~jsonSerializedParams, ~eventName={{contract.name.capitalized}}Contract_{{event.name.capitalized}}Event
)

  Handlers.{{contract.name.capitalized}}Contract.get{{event.name.capitalized}}Handler()(~event, ~context)
  }
{{/each}}
{{/each}}
  }
}

let loadReadEntities = async (eventBatch: array<Types.event>): array<Types.eventAndContext> => {
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
        let context = contextHelper.getContext()
        (contextHelper.getEntitiesToLoad(), Types.{{contract.name.capitalized}}Contract_{{event.name.capitalized}}WithContext(event, context))
        }
{{/each}}
{{/each}}
      }
    })


  let (readEntitiesGrouped, contexts): (array<array<Types.entityRead>>, array<Types.eventAndContext>) =
  result->Belt.Array.unzip

  let readEntities = readEntitiesGrouped->Belt.Array.concatMany

  await readEntities->IO.loadEntities

  contexts
}

let processEventBatch = async (eventBatch: array<Types.event>) => {
  let ioBatch = IO.createBatch()

  let eventBatchAndContext = await eventBatch->loadReadEntities

  eventBatchAndContext->Belt.Array.forEach(event => event->eventRouter)

  await ioBatch->IO.executeBatch
}
