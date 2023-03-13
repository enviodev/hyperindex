type combinedFilter = {}
let generateCombinedFilter = (): combinedFilter => {
  ()->Obj.magic
}

type event =
  | NewGravatar(EventTypes.eventLog<EventTypes.newGravatarEvent>)
  | UpdateGravatar(EventTypes.eventLog<EventTypes.updateGravatarEvent>)

let eventRouter = async (event: event) => {
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

let startIndexer = () => {
  // create provider from config rpc on each network
  // create filters for all contracts and events
  // interface for all the contracts that we need to parse
  // setup getLogs function on the provider
  // based on the address of the log parse the log with correct interface
  // convert to general eventType that the handler takes
  let combinedFilter = generateCombinedFilter()
}
