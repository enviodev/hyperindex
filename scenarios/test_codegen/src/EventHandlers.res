open Types

Handlers.GravatarContract.NewGravatar.loader((~event, ~context) => {
  context.contractRegistration.addSimpleNft(event.srcAddress)
})

Handlers.GravatarContract.NewGravatar.handler((~event, ~context) => {
  let gravatarObject: gravatarEntity = {
    id: event.params.id->Ethers.BigInt.toString,
    owner: event.params.owner->Ethers.ethAddressToString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount: Ethers.BigInt.fromInt(1),
  }

  context.gravatar.set(gravatarObject)
})

Handlers.GravatarContract.UpdatedGravatar.loader((~event, ~context) => {
  context.gravatar.gravatarWithChangesLoad(
    ~loaders={loadOwner: {}},
    event.params.id->Ethers.BigInt.toString,
  )
})

Handlers.GravatarContract.UpdatedGravatar.handler((~event, ~context) => {
  let updatesCount =
    context.gravatar.gravatarWithChanges()->Belt.Option.mapWithDefault(
      Ethers.BigInt.fromInt(1),
      gravatar => gravatar.updatesCount->Ethers.BigInt.add(Ethers.BigInt.fromInt(1)),
    )

  let gravatar: gravatarEntity = {
    id: event.params.id->Ethers.BigInt.toString,
    owner: event.params.owner->Ethers.ethAddressToString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount,
  }

  context.gravatar.set(gravatar)
})
