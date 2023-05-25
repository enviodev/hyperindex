open Types

Handlers.GravatarContract.registerNewGravatarLoadEntities((~event as _, ~context as _) => {
  ()
})

Handlers.GravatarContract.registerNewGravatarHandler((~event, ~context) => {
  let gravatarObject: gravatarEntity = {
    id: event.params.id->Ethers.BigInt.toString,
    owner: event.params.owner->Ethers.ethAddressToString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount: 1,
  }

  context.gravatar.insert(gravatarObject)
})

Handlers.GravatarContract.registerUpdatedGravatarLoadEntities((~event, ~context) => {
  let _ = context.gravatar.gravatarWithChangesLoad(event.params.id->Ethers.BigInt.toString)
})

Handlers.GravatarContract.registerUpdatedGravatarHandler((~event, ~context) => {
  let updatesCount =
    context.gravatar.gravatarWithChanges()->Belt.Option.mapWithDefault(1, gravatar =>
      gravatar.updatesCount + 1
    )

  let gravatar: gravatarEntity = {
    id: event.params.id->Ethers.BigInt.toString,
    owner: event.params.owner->Ethers.ethAddressToString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount,
  }

  context.gravatar.update(gravatar)
})
