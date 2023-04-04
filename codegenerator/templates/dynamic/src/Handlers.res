@module("../../src/EventHandlers.bs.js")
external gravatarNewGravatarLoadEntities: Types.eventLog<Types.newGravatarEvent> => array<
  Types.entityRead,
> = "gravatarNewGravatarLoadEntities"

@module("../../src/EventHandlers.bs.js")
external gravatarNewGravatarEventHandler: (
  Types.eventLog<Types.newGravatarEvent>,
  Types.context,
) => unit = "gravatarNewGravatarEventHandler"

@module("../../src/EventHandlers.bs.js")
external gravatarUpdateGravatarLoadEntities: Types.eventLog<Types.updateGravatarEvent> => array<
  Types.entityRead,
> = "gravatarUpdateGravatarLoadEntities"

@module("../../src/EventHandlers.bs.js")
external gravatarUpdateGravatarEventHandler: (
  Types.eventLog<Types.updateGravatarEvent>,
  Types.context,
) => unit = "gravatarUpdateGravatarEventHandler"
