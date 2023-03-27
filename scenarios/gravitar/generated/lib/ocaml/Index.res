type combinedFilter = {}
let generateCombinedFilter = (): combinedFilter => {
  ()->Obj.magic
}

let eventRouter = async (event: Types.event) => {
  switch event {
  | NewGravatar(event) =>
    //assemble context
    let newGravatarContext = await Context.loadNewGravatarContext()
    Handlers.gravatarNewGravatarEventHandler(event, newGravatarContext)
    await Context.saveNewGravatarContext()

  | UpdateGravatar(event) => {
      let updateGravatarContext = await Context.loadUpdateGravatarContext()
      Handlers.gravatarUpdateGravatarEventHandler(event, updateGravatarContext)
      await Context.saveUpdateGravatarContext()
    }
  }
}

let processEventBatch = async (eventBatch: array<Types.event>) => {
  for i in 0 to eventBatch->Belt.Array.length - 1 {
    await eventBatch[i]->eventRouter
  }

  // eventBatch->Belt.Array.forEach(event => event->eventRouter->ignore)
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
