
open Types

//user defined function that read entities based on the event log
let gravatarNewGravatarLoadEntities = (_event: eventLog<GravatarContract.NewGravatarEvent.eventArgs>): array<
  entityRead,
> => {
  []
}

let gravatarNewGravatarEventHandler = (
  event: eventLog<GravatarContract.NewGravatarEvent.eventArgs>,
  context: Types.GravatarContract.NewGravatarEvent.context,
) => {
  let gravatarObject: gravatarEntity = {
    id: event.params.id->Ethers.BigInt.toString,
    owner: event.params.owner->Ethers.ethAddressToString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount: 1,
  }

  context.gravatar.insert(gravatarObject)
}

//user defined function that read entities based on the event log
let gravatarUpdatedGravatarLoadEntities = (
  event: eventLog<GravatarContract.UpdatedGravatarEvent.eventArgs>,
  contextUpdator: GravatarContract.UpdatedGravatarEvent.loaderContext,
) => {
  contextUpdator.gravatar.gravatarWithChangesLoad(event.params.id->Ethers.BigInt.toString)
}

let gravatarUpdatedGravatarEventHandler = (
  event: eventLog<GravatarContract.UpdatedGravatarEvent.eventArgs>,
  context: GravatarContract.UpdatedGravatarEvent.context,
) => {
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
}
