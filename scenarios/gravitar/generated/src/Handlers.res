@module("../../handler.js")
external gravatarNewGravatarEventHandler: (
  EventTypes.eventLog<EventTypes.newGravatarEvent>,
  ContextStub.context,
) => unit = "gravatarNewGravatarEventHandler"

@module("../../handler.js")
external gravatarUpdateGravatarEventHandler: (
  EventTypes.eventLog<EventTypes.updateGravatarEvent>,
  ContextStub.context,
) => unit = "gravatarUpdateGravatarEventHandler"
