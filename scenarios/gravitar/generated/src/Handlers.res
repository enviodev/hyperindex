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
external gravatarUpdatedGravatarLoadEntities: Types.eventLog<Types.updatedGravatarEvent> => array<
  Types.entityRead,
> = "gravatarUpdatedGravatarLoadEntities"

@module("../../src/EventHandlers.bs.js")
external gravatarUpdatedGravatarEventHandler: (
  Types.eventLog<Types.updatedGravatarEvent>,
  Types.context,
) => unit = "gravatarUpdatedGravatarEventHandler"
