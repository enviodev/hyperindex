let eventRouter = (event: Types.event, context) => {
  switch event {
  | NewGravatar(event) => Handlers.gravatarNewGravatarEventHandler(event, context)

  | UpdatedGravatar(event) => Handlers.gravatarUpdatedGravatarEventHandler(event, context)
  }
}

let loadReadEntities = async (eventBatch: array<Types.event>) => {
  let readEntities =
    eventBatch
    ->Belt.Array.map(event => {
      switch event {
      | NewGravatar(event) => event->Handlers.gravatarNewGravatarLoadEntities
      | UpdatedGravatar(event) => event->Handlers.gravatarUpdatedGravatarLoadEntities
      }
    })
    ->Belt.Array.concatMany

  await readEntities->IO.loadEntities
}

let processEventBatch = async (eventBatch: array<Types.event>, ~context) => {
  let ioBatch = IO.createBatch()

  await eventBatch->loadReadEntities

  eventBatch->Belt.Array.forEach(event => event->eventRouter(context))

  await ioBatch->IO.executeBatch
}
