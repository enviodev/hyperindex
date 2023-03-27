type combinedFilter = {}
let generateCombinedFilter = (): combinedFilter => {
  ()->Obj.magic
}

let eventRouter = (event: Types.event, context) => {
  switch event {
  | NewGravatar(event) => Handlers.gravatarNewGravatarEventHandler(event, context)

  | UpdateGravatar(event) => Handlers.gravatarUpdateGravatarEventHandler(event, context)
  }
}

let loadReadEntities = async (eventBatch: array<Types.event>) => {
  let readEntities =
    eventBatch
    ->Belt.Array.map(event => {
      switch event {
      | NewGravatar(event) => event->Handlers.gravatarNewGravatarLoadEntities
      | UpdateGravatar(event) => event->Handlers.gravatarUpdateGravatarLoadEntities
      }
    })
    ->Belt.Array.concatMany

  await readEntities->IO.loadEntities
}

let processEventBatch = async (eventBatch: array<Types.event>) => {
  let ioBatch = IO.createBatch()

  await eventBatch->loadReadEntities

  let context = IO.getContext()

  eventBatch->Belt.Array.forEach(event => event->eventRouter(context))

  await ioBatch->IO.executeBatch
}

let startIndexer = () => {
  // create provider from config rpc on each network
  // create filters for all contracts and events
  // interface for all the contracts that we need to parse
  // setup getLogs function on the provider
  // based on the address of the log parse the log with correct interface
  // convert to general eventType that the handler takes
  let combinedFilter = generateCombinedFilter()
}
