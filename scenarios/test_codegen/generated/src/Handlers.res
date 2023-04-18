module GravatarContract = {
  @module("../../src/EventHandlers.bs.js")
  external newGravatarLoadEntities: Types.eventLog<
    Types.GravatarContract.newGravatarEvent,
  > => array<Types.entityRead> = "gravatarNewGravatarLoadEntities"

  @module("../../src/EventHandlers.bs.js")
  external newGravatarHandler: (
    Types.eventLog<Types.GravatarContract.newGravatarEvent>,
    Types.context,
  ) => unit = "gravatarNewGravatarEventHandler"

  @module("../../src/EventHandlers.bs.js")
  external updatedGravatarLoadEntities: Types.eventLog<
    Types.GravatarContract.updatedGravatarEvent,
  > => array<Types.entityRead> = "gravatarUpdatedGravatarLoadEntities"

  @module("../../src/EventHandlers.bs.js")
  external updatedGravatarHandler: (
    Types.eventLog<Types.GravatarContract.updatedGravatarEvent>,
    Types.context,
  ) => unit = "gravatarUpdatedGravatarEventHandler"
}
