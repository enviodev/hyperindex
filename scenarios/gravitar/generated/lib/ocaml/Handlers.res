@module("../../src/EventHandlers.js")
external gravatarNewGravatarEventHandler: (
  EventTypes.eventLog<EventTypes.newGravatarEvent>,
  ContextStub.context,
) => unit = "gravatarNewGravatarEventHandler"

@module("../../src/EventHandlers.js")
external gravatarUpdateGravatarEventHandler: (
  EventTypes.eventLog<EventTypes.updateGravatarEvent>,
  ContextStub.context,
) => unit = "gravatarUpdateGravatarEventHandler"
