// import { NewGravatar, UpdatedGravatar } from "../generated/Gravatar/Gravatar";
// import { Gravatar } from "../generated/schema";
open EventTypes

let gravatarNewGravatarEventHandler = (
  event: eventLog<newGravatarEvent>,
  context: ContextStub.context,
) => {
  let gravatarObject: SchemaTypes.gravatar = {
    id: event.params.id,
    owner: event.params.owner,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
  }

  context.gravatar.insert(gravatarObject)
}

let gravatarUpdateGravatarEventHandler = (
  event: eventLog<updateGravatarEvent>,
  context: ContextStub.context,
) => {
  let gravatar: SchemaTypes.gravatar = {
    id: event.params.id,
    owner: event.params.owner,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
  }

  context.gravatar.update(gravatar)
}
