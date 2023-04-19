module GravatarContract = {
  @module("../../src/EventHandlers.bs.js")
  external newGravatarLoadEntities: (
    Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs>,
    Types.GravatarContract.NewGravatarEvent.loaderContext,
  ) => unit = "gravatarNewGravatarLoadEntities"

  @module("../../src/EventHandlers.bs.js")
  external newGravatarHandler: (
    Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs>,
    Types.GravatarContract.NewGravatarEvent.context,
  ) => unit = "gravatarNewGravatarEventHandler"

  @module("../../src/EventHandlers.bs.js")
  external updatedGravatarLoadEntities: (
    Types.eventLog<Types.GravatarContract.UpdatedGravatarEvent.eventArgs>,
    Types.GravatarContract.UpdatedGravatarEvent.loaderContext,
  ) => unit = "gravatarUpdatedGravatarLoadEntities"

  @module("../../src/EventHandlers.bs.js")
  external updatedGravatarHandler: (
    Types.eventLog<Types.GravatarContract.UpdatedGravatarEvent.eventArgs>,
    Types.GravatarContract.UpdatedGravatarEvent.context,
  ) => unit = "gravatarUpdatedGravatarEventHandler"
}
