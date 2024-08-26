open Types

Handlers.GravatarContract.NewGravatar.loader((~event as _, ~context as _) => {
  ()
})

Handlers.GravatarContract.NewGravatar.handler((~event, ~context) => {
  let gravatarObject: gravatarEntity = {
    id: event.params.id->BigInt.toString,
    owner: event.params.owner->Address.toString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount: 1,
  }

  context.gravatar.set(gravatarObject)
})

Handlers.GravatarContract.UpdatedGravatar.loader((~event, ~context) => {
  let _ = context.gravatar.gravatarWithChangesLoad(event.params.id->BigInt.toString)
})

Handlers.GravatarContract.UpdatedGravatar.handler((~event, ~context) => {
  let updatesCount =
    context.gravatar.gravatarWithChanges()->Belt.Option.mapWithDefault(1, gravatar =>
      gravatar.updatesCount + 1
    )

  let gravatar: gravatarEntity = {
    id: event.params.id->BigInt.toString,
    owner: event.params.owner->Address.toString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount,
  }

  context.gravatar.set(gravatar)
})
