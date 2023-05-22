type chainId = int
type eventId = Ethers.BigInt.t

module RawEvents = {
  type rawEventRowId = (chainId, eventId)
  @module("./DbFunctionsImplementation.js")
  external batchSetRawEvents: array<Types.rawEventsEntity> => promise<unit> = "batchSetRawEvents"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteRawEvents: array<rawEventRowId> => promise<unit> = "batchDeleteRawEvents"

  @module("./DbFunctionsImplementation.js")
  external readRawEventsEntities: array<rawEventRowId> => promise<array<Types.rawEventsEntity>> =
    "readRawEventsEntities"
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
    @as("event_chain_id") chainId: int,
    @as("event_id") eventId: Ethers.BigInt.t,
  }

  let readRowToReadEntityData = (readRow: userReadRow): readEntityData<Types.userEntity> => {
    let {id, address, gravatar, chainId, eventId} = readRow

    {
      entity: {
        id,
        address,
        gravatar,
      },
      eventData: {
        chainId,
        eventId,
      },
    }
  }

  @module("./DbFunctionsImplementation.js")
  external batchSetUser: array<Types.inMemoryStoreRow<Types.userEntitySerialized>> => promise<
    unit,
  > = "batchSetUser"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteUser: array<Types.id> => promise<unit> = "batchDeleteUser"

  @module("./DbFunctionsImplementation.js")
  external //external readUserEntities: array<Types.id> => promise<array<Types.userEntitySerialized>> = "readUserEntities"
  readUserEntities: array<Types.id> => promise<array<userReadRow>> = "readUserEntities"

  // let readUserEntities: array<Types.id> => promise<array<readEntityEventData<Types.userEntity>>> = async (idArr) => {
  // let res = await idArr->readUserEntitiesUnclen
  // res->Belt.Array.map(uncleanItem => uncleanItem->readEntityDataToInMemRow(~entityConverter=readTypeToInMemRow))
  // }
}
module Gravatar = {
  open Types
  type gravatarReadRow = {
    id: string,
    owner: id,
    displayName: string,
    imageUrl: string,
    updatesCount: int,
    bigIntTest: string,
    bigIntOption: option<string>,
    @as("event_chain_id") chainId: int,
    @as("event_id") eventId: Ethers.BigInt.t,
  }

  let readRowToReadEntityData = (readRow: gravatarReadRow): readEntityData<
    Types.gravatarEntity,
  > => {
    let {
      id,
      owner,
      displayName,
      imageUrl,
      updatesCount,
      bigIntTest,
      bigIntOption,
      chainId,
      eventId,
    } = readRow

    {
      entity: {
        id,
        owner,
        displayName,
        imageUrl,
        updatesCount,
        bigIntTest: bigIntTest->Ethers.BigInt.toString,
        bigIntOption: bigIntOption->Belt.Option.map(opt => opt->Ethers.BigInt.toString),
      },
      eventData: {
        chainId,
        eventId,
      },
    }
  }

  @module("./DbFunctionsImplementation.js")
  external batchSetGravatar: array<
    Types.inMemoryStoreRow<Types.gravatarEntitySerialized>,
  > => promise<unit> = "batchSetGravatar"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteGravatar: array<Types.id> => promise<unit> = "batchDeleteGravatar"

  @module("./DbFunctionsImplementation.js")
  external //external readGravatarEntities: array<Types.id> => promise<array<Types.gravatarEntitySerialized>> = "readGravatarEntities"
  readGravatarEntities: array<Types.id> => promise<array<gravatarReadRow>> = "readGravatarEntities"

  // let readGravatarEntities: array<Types.id> => promise<array<readEntityEventData<Types.gravatarEntity>>> = async (idArr) => {
  // let res = await idArr->readGravatarEntitiesUnclen
  // res->Belt.Array.map(uncleanItem => uncleanItem->readEntityDataToInMemRow(~entityConverter=readTypeToInMemRow))
  // }
}
