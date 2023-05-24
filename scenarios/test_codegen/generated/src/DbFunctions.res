let config: Postgres.poolConfig = {
  ...Config.db,
  transform: {undefined: Js.null},
}
let sql = Postgres.makeSql(~config)

type chainId = int
type eventId = Ethers.BigInt.t

module RawEvents = {
  type rawEventRowId = (chainId, eventId)
  @module("./DbFunctionsImplementation.js")
  external batchSetRawEvents: (Postgres.sql, array<Types.rawEventsEntity>) => promise<unit> =
    "batchSetRawEvents"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteRawEvents: (Postgres.sql, array<rawEventRowId>) => promise<unit> =
    "batchDeleteRawEvents"

  @module("./DbFunctionsImplementation.js")
  external readRawEventsEntities: (
    Postgres.sql,
    array<rawEventRowId>,
  ) => promise<array<Types.rawEventsEntity>> = "readRawEventsEntities"
}

type readEntityData<'a> = {
  entity: 'a,
  eventData: Types.eventData,
}

module User = {
  open Types
  type userReadRow = {
    id: string,
    address: string,
    gravatar: option<id>,
    updatesCountOnUserForTesting: int,
    @as("event_chain_id") chainId: int,
    @as("event_id") eventId: Ethers.BigInt.t,
  }

  let readRowToReadEntityData = (readRow: userReadRow): readEntityData<Types.userEntity> => {
    let {id, address, gravatar, updatesCountOnUserForTesting, chainId, eventId} = readRow

    {
      entity: {
        id,
        address,
        gravatar,
        gravatarData: None,
        updatesCountOnUserForTesting,
      },
      eventData: {
        chainId,
        eventId,
      },
    }
  }

  @module("./DbFunctionsImplementation.js")
  external batchSetUser: (
    Postgres.sql,
    array<Types.inMemoryStoreRow<Types.userEntity>>,
  ) => promise<unit> = "batchSetUser"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteUser: (Postgres.sql, array<Types.id>) => promise<unit> = "batchDeleteUser"

  @module("./DbFunctionsImplementation.js")
  external readUserEntities: (Postgres.sql, array<Types.id>) => promise<array<userReadRow>> =
    "readUserEntities"
}
module Gravatar = {
  open Types
  type gravatarReadRow = {
    id: string,
    owner: id,
    displayName: string,
    imageUrl: string,
    updatesCount: int,
    @as("event_chain_id") chainId: int,
    @as("event_id") eventId: Ethers.BigInt.t,
  }

  let readRowToReadEntityData = (readRow: gravatarReadRow): readEntityData<
    Types.gravatarEntity,
  > => {
    let {id, owner, displayName, imageUrl, updatesCount, chainId, eventId} = readRow

    {
      entity: {
        id,
        owner,
        ownerData: None,
        displayName,
        imageUrl,
        updatesCount,
      },
      eventData: {
        chainId,
        eventId,
      },
    }
  }

  @module("./DbFunctionsImplementation.js")
  external batchSetGravatar: (
    Postgres.sql,
    array<Types.inMemoryStoreRow<Types.gravatarEntity>>,
  ) => promise<unit> = "batchSetGravatar"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteGravatar: (Postgres.sql, array<Types.id>) => promise<unit> =
    "batchDeleteGravatar"

  @module("./DbFunctionsImplementation.js")
  external readGravatarEntities: (
    Postgres.sql,
    array<Types.id>,
  ) => promise<array<gravatarReadRow>> = "readGravatarEntities"
}
