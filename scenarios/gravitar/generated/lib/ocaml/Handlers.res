@module("../../src/EventHandlers.js")
external gravatarNewGravatarEventHandler: (
  Types.eventLog<Types.newGravatarEvent>,
  ContextStub.context,
) => unit = "gravatarNewGravatarEventHandler"

@module("../../src/EventHandlers.js")
external gravatarUpdateGravatarEventHandler: (
  Types.eventLog<Types.updateGravatarEvent>,
  ContextStub.context,
) => unit = "gravatarUpdateGravatarEventHandler"
