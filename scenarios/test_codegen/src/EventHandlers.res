
open Types

//user defined function that read entities based on the event log
let gravatarNewGravatarLoadEntities = (_event: eventLog<GravatarContract.NewGravatarTypes.newGravatarEvent>): array<
  entityRead,
> => {
  []
}

let gravatarNewGravatarEventHandler = (
  event: eventLog<GravatarContract.NewGravatarTypes.newGravatarEvent>,
  context: GravatarContract.NewGravatarTypes.context,
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

// module GravatarContract = {
//   module UpdatedGravatarTypes = {
//     type gravatarWithChanges = unit => option<gravatarEntity>
//     type gravatarEntityHandlerContext = {
//       gravatarWithChanges: gravatarWithChanges,
//       insert: Types.gravatarEntity => unit,
//       update: Types.gravatarEntity => unit,
//       delete: Types.id => unit,
//     }
//     type context = {gravatar: gravatarEntityHandlerContext}
//     type gravatarEntityLoaderContext = {gravatarWithChangesLoad: Types.id => unit}
//     type loaderContext = {gravatar: gravatarEntityLoaderContext}
//   }
// }

//user defined function that read entities based on the event log
let gravatarUpdatedGravatarLoadEntities = (
  event: eventLog<GravatarContract.UpdatedGravatarTypes.updatedGravatarEvent>,
  contextUpdator: GravatarContract.UpdatedGravatarTypes.loaderContext,
) => {
  contextUpdator.gravatar.gravatarWithChangesLoad(event.params.id->Ethers.BigInt.toString)
}

let gravatarUpdatedGravatarEventHandler = (
  event: eventLog<GravatarContract.UpdatedGravatarTypes.updatedGravatarEvent>,
  context: GravatarContract.UpdatedGravatarTypes.context,
) => {
  /*
  let updatesCount =
    context.gravatar.loadedEntities.getGravatarById(
      event.params.id->Ethers.BigInt.toString,
    )->Belt.Option.mapWithDefault(1, gravatar => gravatar.updatesCount + 1)
 */
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
