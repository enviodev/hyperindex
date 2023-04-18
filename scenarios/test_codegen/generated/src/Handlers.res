module GravatarContract = {
  @module("../../src/EventHandlers.bs.js")
  external newGravatarLoadEntities: Types.eventLog<
    Types.GravatarContract.NewGravatarEvent.eventArgs,
  > => array<Types.entityRead> = "gravatarNewGravatarLoadEntities"

  @module("../../src/EventHandlers.bs.js")
  external newGravatarHandler: (
    Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs>,
    Types.GravatarContract.NewGravatarEvent.context,
  ) => unit = "gravatarNewGravatarEventHandler"

  @module("../../src/EventHandlers.bs.js")
  external updatedGravatarLoadEntities: Types.eventLog<
    Types.GravatarContract.UpdatedGravatarEvent.eventArgs,
  > => array<Types.entityRead> = "gravatarUpdatedGravatarLoadEntities"

  @module("../../src/EventHandlers.bs.js")
  external updatedGravatarHandler: (
    Types.eventLog<Types.GravatarContract.UpdatedGravatarEvent.eventArgs>,
    Types.GravatarContract.UpdatedGravatarEvent.context,
  ) => unit = "gravatarUpdatedGravatarEventHandler"
}
