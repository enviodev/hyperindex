let eventRouter = (event: Types.event) => {
  switch event {
{{#each contracts as | contract |}}
{{#each contract.events as | event |}}
  | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}(event) => {
    let context = Context.{{contract.name.capitalized}}Contract.{{event.name.capitalized}}Event.getContext()
  event->Handlers.{{contract.name.capitalized}}Contract.{{event.name.uncapitalized}}Handler(context)
  }
{{/each}}
{{/each}}
  }
}

let loadReadEntities = async (eventBatch: array<Types.event>) => {
  let readEntities =
    eventBatch
    ->Belt.Array.map(event => {
      switch event {
{{#each contracts as | contract |}}
{{#each contract.events as | event |}}
        | {{contract.name.capitalized}}Contract_{{event.name.capitalized}}(event) => event->Handlers.{{contract.name.capitalized}}Contract.{{event.name.uncapitalized}}LoadEntities
{{/each}}
{{/each}}
      }
    })
    ->Belt.Array.concatMany

  await readEntities->IO.loadEntities
}

let processEventBatch = async (eventBatch: array<Types.event>) => {
  let ioBatch = IO.createBatch()

  await eventBatch->loadReadEntities

  eventBatch->Belt.Array.forEach(event => event->eventRouter)

  await ioBatch->IO.executeBatch
}
