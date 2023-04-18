let eventRouter = (event: Types.event) => {
  switch event {
  | GravatarContract_NewGravatar(event) => {
      let context = Context.GravatarContract.NewGravatarEvent.getContext()
      event->Handlers.GravatarContract.newGravatarHandler(context)
    }
  | GravatarContract_UpdatedGravatar(event) => {
      let context = Context.GravatarContract.UpdatedGravatarEvent.getContext()
      event->Handlers.GravatarContract.updatedGravatarHandler(context)
    }
  }
}

let loadReadEntities = async (eventBatch: array<Types.event>) => {
  let readEntities =
    eventBatch
    ->Belt.Array.map(event => {
      switch event {
      | GravatarContract_NewGravatar(event) =>
        event->Handlers.GravatarContract.newGravatarLoadEntities
      | GravatarContract_UpdatedGravatar(event) =>
        event->Handlers.GravatarContract.updatedGravatarLoadEntities
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
