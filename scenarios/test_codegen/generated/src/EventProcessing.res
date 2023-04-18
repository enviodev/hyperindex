let eventRouter = (event: Types.eventAndContext) => {
  switch event {
  | GravatarContract_NewGravatarWithContext(
      event,
      context,
    ) => event->Handlers.GravatarContract.newGravatarHandler(context)
  | GravatarContract_UpdatedGravatarWithContext(
      event,
      context,
    ) => event->Handlers.GravatarContract.updatedGravatarHandler(context)
  }
}

let loadReadEntities = async (eventBatch: array<Types.event>): array<Types.eventAndContext> => {
  let result: array<(
    array<Types.entityRead>,
    Types.eventAndContext,
  )> = eventBatch->Belt.Array.map(event => {
    switch event {
    | GravatarContract_NewGravatar(event) => {
        let contextHelper = Context.GravatarContract.NewGravatarEvent.contextCreator()
        let readEntities = Handlers.GravatarContract.newGravatarLoadEntities(
          event,
          contextHelper.getLoaderContext(),
        )
        let context = contextHelper.getContext()
        (readEntities, Types.GravatarContract_NewGravatarWithContext(event, context))
      }
    | GravatarContract_UpdatedGravatar(event) => {
        let contextHelper = Context.GravatarContract.UpdatedGravatarEvent.contextCreator()
        let readEntities = Handlers.GravatarContract.updatedGravatarLoadEntities(
          event,
          contextHelper.getLoaderContext(),
        )
        let context = contextHelper.getContext()
        (readEntities, Types.GravatarContract_UpdatedGravatarWithContext(event, context))
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

let processEventBatch = async (eventBatch: array<Types.event>) => {
  let ioBatch = IO.createBatch()

  let eventBatchAndContext = await eventBatch->loadReadEntities

  eventBatchAndContext->Belt.Array.forEach(event => event->eventRouter)

  await ioBatch->IO.executeBatch
}
