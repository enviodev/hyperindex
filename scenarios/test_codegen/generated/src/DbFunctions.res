module RawEvents = {
  type chainId = int
  type eventId = Ethers.BigInt.t
  type rawEventRowId = (chainId, eventId)
  @module("./DbFunctionsImplementation.js")
  external batchSetRawEvents: array<Types.rawEventsEntity> => promise<unit> = "batchSetRawEvents"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteRawEvents: array<rawEventRowId> => promise<unit> = "batchDeleteRawEvents"

  @module("./DbFunctionsImplementation.js")
  external readRawEventsEntities: array<rawEventRowId> => promise<array<Types.rawEventsEntity>> =
    "readRawEventsEntities"
}

module User = {
  @module("./DbFunctionsImplementation.js")
  external batchSetUser: array<Types.userEntity> => promise<unit> = "batchSetUser"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteUser: array<Types.id> => promise<unit> = "batchDeleteUser"

  @module("./DbFunctionsImplementation.js")
  external readUserEntities: array<Types.id> => promise<array<Types.userEntity>> =
    "readUserEntities"
}
module Gravatar = {
  @module("./DbFunctionsImplementation.js")
  external batchSetGravatar: array<Types.gravatarEntity> => promise<unit> = "batchSetGravatar"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteGravatar: array<Types.id> => promise<unit> = "batchDeleteGravatar"

  @module("./DbFunctionsImplementation.js")
  external readGravatarEntities: array<Types.id> => promise<array<Types.gravatarEntity>> =
    "readGravatarEntities"
}
