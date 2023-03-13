
import { NewGravatar, UpdatedGravatar } from '../generated/Gravity/Gravity'
import { Gravatar } from '../generated/schema'
lensProtocolProfilesTransferEventHandler
let gravatarNewGravatarEventHandler = (event: NewGravatar, context) => {

  let gravatarObject = {
    id: event.id,
    owner: event.params.owner,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
  }

  context.Gravatar.insert(gravatarObject)
}

let gravatarUpdatedGravatarEventHandler = (event: UpdatedGravatar, context) => {
  let gravatar = {
    id: event.id,
    owner: event.params.owner,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
  }

  context.Gravatar.update(gravatar)
}
