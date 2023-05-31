let config: Postgres.poolConfig = {
  ...Config.db,
  transform: {undefined: Js.null},
}
let sql = Postgres.makeSql(~config)

type chainId = int
type eventId = Ethers.BigInt.t
type blockNumberRow = {@as("block_number") blockNumber: int}

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

  ///Returns an array with 1 block number (the highest processed on the given chainId)
  @module("./DbFunctionsImplementation.js")
  external readLatestRawEventsBlockNumberProcessedOnChainId: (
    Postgres.sql,
    chainId,
  ) => promise<array<blockNumberRow>> = "readLatestRawEventsBlockNumberProcessedOnChainId"

  let getLatestProcessedBlockNumber = async (~chainId) => {
    let row = await sql->readLatestRawEventsBlockNumberProcessedOnChainId(chainId)

    row->Belt.Array.get(0)->Belt.Option.map(row => row.blockNumber)
  }
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
    tokens: array<id>,
    @as("event_chain_id") chainId: int,
    @as("event_id") eventId: Ethers.BigInt.t,
  }

  let readRowToReadEntityData = (readRow: userReadRow): readEntityData<Types.userEntity> => {
    let {id, address, gravatar, updatesCountOnUserForTesting, tokens, chainId, eventId} = readRow

    {
      entity: {
        id,
        address,
        gravatar,
        updatesCountOnUserForTesting,
        tokens,
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
    array<Types.inMemoryStoreRow<Types.userEntitySerialized>>,
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
    updatesCount: string,
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
        displayName,
        imageUrl,
        updatesCount: updatesCount->Ethers.BigInt.fromStringUnsafe,
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
    array<Types.inMemoryStoreRow<Types.gravatarEntitySerialized>>,
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
module Nftcollection = {
  open Types
  type nftcollectionReadRow = {
    id: string,
    contractAddress: string,
    name: string,
    symbol: string,
    maxSupply: string,
    currentSupply: int,
    @as("event_chain_id") chainId: int,
    @as("event_id") eventId: Ethers.BigInt.t,
  }

  let readRowToReadEntityData = (readRow: nftcollectionReadRow): readEntityData<
    Types.nftcollectionEntity,
  > => {
    let {id, contractAddress, name, symbol, maxSupply, currentSupply, chainId, eventId} = readRow

    {
      entity: {
        id,
        contractAddress,
        name,
        symbol,
        maxSupply: maxSupply->Ethers.BigInt.fromStringUnsafe,
        currentSupply,
      },
      eventData: {
        chainId,
        eventId,
      },
    }
  }

  @module("./DbFunctionsImplementation.js")
  external batchSetNftcollection: (
    Postgres.sql,
    array<Types.inMemoryStoreRow<Types.nftcollectionEntitySerialized>>,
  ) => promise<unit> = "batchSetNftcollection"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteNftcollection: (Postgres.sql, array<Types.id>) => promise<unit> =
    "batchDeleteNftcollection"

  @module("./DbFunctionsImplementation.js")
  external readNftcollectionEntities: (
    Postgres.sql,
    array<Types.id>,
  ) => promise<array<nftcollectionReadRow>> = "readNftcollectionEntities"
}
module Token = {
  open Types
  type tokenReadRow = {
    id: string,
    tokenId: string,
    collection: id,
    owner: id,
    @as("event_chain_id") chainId: int,
    @as("event_id") eventId: Ethers.BigInt.t,
  }

  let readRowToReadEntityData = (readRow: tokenReadRow): readEntityData<Types.tokenEntity> => {
    let {id, tokenId, collection, owner, chainId, eventId} = readRow

    {
      entity: {
        id,
        tokenId: tokenId->Ethers.BigInt.fromStringUnsafe,
        collection,
        owner,
      },
      eventData: {
        chainId,
        eventId,
      },
    }
  }

  @module("./DbFunctionsImplementation.js")
  external batchSetToken: (
    Postgres.sql,
    array<Types.inMemoryStoreRow<Types.tokenEntitySerialized>>,
  ) => promise<unit> = "batchSetToken"

  @module("./DbFunctionsImplementation.js")
  external batchDeleteToken: (Postgres.sql, array<Types.id>) => promise<unit> = "batchDeleteToken"

  @module("./DbFunctionsImplementation.js")
  external readTokenEntities: (Postgres.sql, array<Types.id>) => promise<array<tokenReadRow>> =
    "readTokenEntities"
}
