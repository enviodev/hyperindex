open Types

//user defined function that read entities based on the event log
let gravatarNewGravatarLoadEntities = (_event: eventLog<GravatarContract.newGravatarEvent>): array<
  entityRead,
> => {
  []
}

let gravatarNewGravatarEventHandler = (
  event: eventLog<GravatarContract.newGravatarEvent>,
  context: context,
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
  event: eventLog<GravatarContract.updatedGravatarEvent>,
  contextUpdator: contextUpdator,
): array<entityRead> => {

  [GravatarRead(event.params.id->Ethers.BigInt.toString)]
}

let gravatarUpdatedGravatarEventHandler = (
  event: eventLog<GravatarContract.updatedGravatarEvent>,
  context: context,
) => {
  /*
  let updatesCount =
    context.gravatar.loadedEntities.getGravatarById(
      event.params.id->Ethers.BigInt.toString,
    )->Belt.Option.mapWithDefault(1, gravatar => gravatar.updatesCount + 1)
    */
  let updatesCount =
    context.gravatar.loadedEntities.gravatarWithChanges()->Belt.Option.mapWithDefault(1, gravatar => gravatar.updatesCount + 1)

  let gravatar: gravatarEntity = {
    id: event.params.id->Ethers.BigInt.toString,
    owner: event.params.owner->Ethers.ethAddressToString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount,
  }

  context.gravatar.update(gravatar)
}
