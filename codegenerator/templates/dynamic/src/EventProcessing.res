let eventRouter = (event: Types.eventAndContext) => {
  switch event {
{{#each contracts as | contract |}}
{{#each contract.events as | event |}}
  | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}WithContext(event, context) => {
  event->Handlers.{{contract.name.capitalized}}Contract.{{event.name.uncapitalized}}Handler(context)
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
        let readEntities = Handlers.{{contract.name.capitalized}}Contract.{{event.name.uncapitalized}}LoadEntities(event, contextHelper.getLoaderContext())
        let context = contextHelper.getContext()
        (readEntities, Types.{{contract.name.capitalized}}Contract_{{event.name.capitalized}}WithContext(event, context))
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
