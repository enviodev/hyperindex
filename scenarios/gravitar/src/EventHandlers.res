open Types

//user defined function that read entities based on the event log
let gravatarNewGravatarReadEntities = (_event: eventLog<newGravatarEvent>): array<entityRead> => {
  []
}

let gravatarNewGravatarEventHandler = (event: eventLog<newGravatarEvent>, context: context) => {
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
let gravatarUpdateGravatarReadEntities = (event: eventLog<updateGravatarEvent>): array<
  entityRead,
> => {
  [GravatarRead(event.params.id)]
}

let gravatarUpdateGravatarEventHandler = (
  event: eventLog<updateGravatarEvent>,
  context: context,
) => {
  let updatesCount =
    context.gravatar.readEntities
    ->Belt.Array.get(0)
    ->Belt.Option.mapWithDefault(1, gravatar => gravatar.updatesCount + 1)

  let gravatar: gravatarEntity = {
    id: event.params.id,
    owner: event.params.owner,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount,
  }

  context.gravatar.update(gravatar)
}
