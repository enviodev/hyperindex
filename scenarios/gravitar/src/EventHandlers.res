// import { NewGravatar, UpdatedGravatar } from "../generated/Gravatar/Gravatar";
// import { Gravatar } from "../generated/schema";
open Types

let gravatarNewGravatarEventHandler = (
  event: eventLog<newGravatarEvent>,
  context: ContextStub.context,
) => {
  let gravatarObject: gravatarEntity = {
    id: event.params.id,
    owner: event.params.owner,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount: 1,
  }

  context.gravatar.insert(gravatarObject)
}
//user defined function that read entities based on the event log
let updateGravatarEntityRead = (event: eventLog<updateGravatarEvent>): array<entityRead> => {
  [GravatarRead(event.params.id)]
}

let gravatarUpdateGravatarEventHandler = (
  event: eventLog<updateGravatarEvent>,
  context: ContextStub.context,
) => {
  let entities = context.readGravatarEntities
  let gravatar: gravatarEntity = {
    id: event.params.id,
    owner: event.params.owner,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount: entities[0].updateCounts + 1,
  }

  context.gravatar.update(gravatar)
}
