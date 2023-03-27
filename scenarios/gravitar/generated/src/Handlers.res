@module("../../src/EventHandlers.bs.js")
external gravatarNewGravatarEventHandler: (
  Types.eventLog<Types.newGravatarEvent>,
  Types.context,
) => unit = "gravatarNewGravatarEventHandler"

@module("../../src/EventHandlers.bs.js")
external gravatarUpdateGravatarEventHandler: (
  Types.eventLog<Types.updateGravatarEvent>,
  Types.context,
) => unit = "gravatarUpdateGravatarEventHandler"
