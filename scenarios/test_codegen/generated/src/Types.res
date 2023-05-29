//*************
//***ENTITIES**
//*************

@genType.as("Id")
type id = string

//nested subrecord types

@spice
type contactDetails = {
  name: string,
  email: string,
}

@genType
type rec gravatarLoaderConfig = {loadOwner?: userLoaderConfig}
and userLoaderConfig = {loadGravatar?: gravatarLoaderConfig, loadTokens?: tokenLoaderConfig}
and tokenLoaderConfig = {loadOwner?: userLoaderConfig, nftcolletion?: bool}

type entityRead =
  | UserRead(id, userLoaderConfig)
  | GravatarRead(id, gravatarLoaderConfig)
  | NftcollectionRead(id)
  | TokenRead(id, tokenLoaderConfig)

let entitySerialize = (entity: entityRead) => {
  switch entity {
  | UserRead(id, _) => `user${id}`
  | GravatarRead(id, _) => `gravatar${id}`
  | NftcollectionRead(id) => `nftcollection${id}`
  | TokenRead(id, _) => `token${id}`
  }
}

type rawEventsEntity = {
  @as("chain_id") chainId: int,
  @as("event_id") eventId: Ethers.BigInt.t,
  @as("block_number") blockNumber: int,
  @as("log_index") logIndex: int,
  @as("transaction_index") transactionIndex: int,
  @as("transaction_hash") transactionHash: string,
  @as("src_address") srcAddress: string,
  @as("block_hash") blockHash: string,
  @as("block_timestamp") blockTimestamp: int,
  @as("event_type") eventType: Js.Json.t,
  params: Js.Json.t,
}

@genType
type userEntity = {
  id: string,
  address: string,
  gravatar: option<id>,
  updatesCountOnUserForTesting: int,
  tokens: array<id>,
}

type userEntitySerialized = {
  id: string,
  address: string,
  gravatar: option<id>,
  tokens: array<id>,
}

let serializeUserEntity = (entity: userEntity): userEntitySerialized => {
  {
    id: entity.id,
    address: entity.address,
    gravatar: entity.gravatar,
    tokens: entity.tokens,
  }
}

type gravatarEntity = {
  id: string,
  owner: id,
  displayName: string,
  imageUrl: string,
  updatesCount: Ethers.BigInt.t,
}

type gravatarEntitySerialized = {
  id: string,
  owner: id,
  displayName: string,
  imageUrl: string,
  updatesCount: string,
}

let serializeGravatarEntity = (entity: gravatarEntity): gravatarEntitySerialized => {
  {
    id: entity.id,
    owner: entity.owner,
    displayName: entity.displayName,
    imageUrl: entity.imageUrl,
    updatesCount: entity.updatesCount->Ethers.BigInt.toString,
  }
}

@genType
type nftcollectionEntity = {
  id: string,
  contractAddress: string,
  name: string,
  symbol: string,
  maxSupply: Ethers.BigInt.t,
  currentSupply: int,
}

type nftcollectionEntitySerialized = {
  id: string,
  contractAddress: string,
  name: string,
  symbol: string,
  maxSupply: string,
  currentSupply: int,
}

let serializeNftcollectionEntity = (entity: nftcollectionEntity): nftcollectionEntitySerialized => {
  {
    id: entity.id,
    contractAddress: entity.contractAddress,
    name: entity.name,
    symbol: entity.symbol,
    maxSupply: entity.maxSupply->Ethers.BigInt.toString,
    currentSupply: entity.currentSupply,
  }
}

@genType
type tokenEntity = {
  id: string,
  tokenId: Ethers.BigInt.t,
  collection: id,
  owner: id,
}

type tokenEntitySerialized = {
  id: string,
  tokenId: string,
  collection: id,
  owner: id,
}

let serializeTokenEntity = (entity: tokenEntity): tokenEntitySerialized => {
  {
    id: entity.id,
    tokenId: entity.tokenId->Ethers.BigInt.toString,
    collection: entity.collection,
    owner: entity.owner,
  }
}

type entity =
  | UserEntity(userEntity)
  | GravatarEntity(gravatarEntity)
  | NftcollectionEntity(nftcollectionEntity)
  | TokenEntity(tokenEntity)

type crud = Create | Read | Update | Delete

type eventData = {
  @as("event_chain_id") chainId: int,
  @as("event_id") eventId: Ethers.BigInt.t,
}

type inMemoryStoreRow<'a> = {
  crud: crud,
  entity: 'a,
  eventData: eventData,
}

//*************
//**CONTRACTS**
//*************

@genType
type eventLog<'a> = {
  params: 'a,
  blockNumber: int,
  blockTimestamp: int,
  blockHash: string,
  srcAddress: string,
  transactionHash: string,
  transactionIndex: int,
  logIndex: int,
}

module GravatarContract = {
  module TestEventEvent = {
    @spice @genType
    type eventArgs = {
      id: Ethers.BigInt.t,
      user: Ethers.ethAddress,
      contactDetails: contactDetails,
    }
    type userEntityHandlerContext = {
      insert: userEntity => unit,
      update: userEntity => unit,
      delete: id => unit,
    }
    type gravatarEntityHandlerContext = {
      insert: gravatarEntity => unit,
      update: gravatarEntity => unit,
      delete: id => unit,
    }
    @genType
    type context = {
      user: userEntityHandlerContext,
      gravatar: gravatarEntityHandlerContext,
    }

    // NOTE: this only allows single level deep linked entity data loading. TODO: make it recursive

    @genType
    type loaderContext = {}
  }

  module NewGravatarEvent = {
    @spice @genType
    type eventArgs = {
      id: Ethers.BigInt.t,
      owner: Ethers.ethAddress,
      displayName: string,
      imageUrl: string,
    }
    type userEntityHandlerContext = {
      insert: userEntity => unit,
      update: userEntity => unit,
      delete: id => unit,
    }
    type gravatarEntityHandlerContext = {
      insert: gravatarEntity => unit,
      update: gravatarEntity => unit,
      delete: id => unit,
    }
    type nftcollectionEntityHandlerContext = {
      insert: nftcollectionEntity => unit,
      update: nftcollectionEntity => unit,
      delete: id => unit,
    }
    type tokenEntityHandlerContext = {
      insert: tokenEntity => unit,
      update: tokenEntity => unit,
      delete: id => unit,
    }
    @genType
    type context = {
      user: userEntityHandlerContext,
      gravatar: gravatarEntityHandlerContext,
      nftcollection: nftcollectionEntityHandlerContext,
      token: tokenEntityHandlerContext,
    }

    // NOTE: this only allows single level deep linked entity data loading. TODO: make it recursive

    @genType
    type loaderContext = {}
  }
  module UpdatedGravatarEvent = {
    @spice @genType
    type eventArgs = {
      id: Ethers.BigInt.t,
      owner: Ethers.ethAddress,
      displayName: string,
      imageUrl: string,
    }
    type userEntityHandlerContext = {
      insert: userEntity => unit,
      update: userEntity => unit,
      delete: id => unit,
    }
    type gravatarEntityHandlerContext = {
      gravatarWithChanges: unit => option<gravatarEntity>,
      getOwner: gravatarEntity => userEntity,
      insert: gravatarEntity => unit,
      update: gravatarEntity => unit,
      delete: id => unit,
    }
    type nftcollectionEntityHandlerContext = {
      insert: nftcollectionEntity => unit,
      update: nftcollectionEntity => unit,
      delete: id => unit,
    }
    type tokenEntityHandlerContext = {
      insert: tokenEntity => unit,
      update: tokenEntity => unit,
      delete: id => unit,
    }
    @genType
    type context = {
      user: userEntityHandlerContext,
      gravatar: gravatarEntityHandlerContext,
      nftcollection: nftcollectionEntityHandlerContext,
      token: tokenEntityHandlerContext,
    }

    @genType
    type gravatarEntityLoaderContext = {
      gravatarWithChangesLoad: (id, ~loaders: gravatarLoaderConfig=?) => unit,
    }

    @genType
    type loaderContext = {gravatar: gravatarEntityLoaderContext}
  }
}
module NftFactoryContract = {
  module SimpleNftCreatedEvent = {
    @spice @genType
    type eventArgs = {
      name: string,
      symbol: string,
      maxSupply: Ethers.BigInt.t,
      contractAddress: Ethers.ethAddress,
    }
    type userEntityHandlerContext = {
      insert: userEntity => unit,
      update: userEntity => unit,
      delete: id => unit,
    }
    type gravatarEntityHandlerContext = {
      insert: gravatarEntity => unit,
      update: gravatarEntity => unit,
      delete: id => unit,
    }
    type nftcollectionEntityHandlerContext = {
      insert: nftcollectionEntity => unit,
      update: nftcollectionEntity => unit,
      delete: id => unit,
    }
    type tokenEntityHandlerContext = {
      insert: tokenEntity => unit,
      update: tokenEntity => unit,
      delete: id => unit,
    }
    @genType
    type context = {
      user: userEntityHandlerContext,
      gravatar: gravatarEntityHandlerContext,
      nftcollection: nftcollectionEntityHandlerContext,
      token: tokenEntityHandlerContext,
    }

    @genType
    type loaderContext = {}
  }
}
module SimpleNftContract = {
  module TransferEvent = {
    @spice @genType
    type eventArgs = {
      from: Ethers.ethAddress,
      to: Ethers.ethAddress,
      tokenId: Ethers.BigInt.t,
    }
    type userEntityHandlerContext = {
      userFrom: unit => option<userEntity>,
      userTo: unit => option<userEntity>,
      insert: userEntity => unit,
      update: userEntity => unit,
      delete: id => unit,
    }
    type gravatarEntityHandlerContext = {
      insert: gravatarEntity => unit,
      update: gravatarEntity => unit,
      delete: id => unit,
    }
    type nftcollectionEntityHandlerContext = {
      nftCollectionUpdated: unit => option<nftcollectionEntity>,
      insert: nftcollectionEntity => unit,
      update: nftcollectionEntity => unit,
      delete: id => unit,
    }
    type tokenEntityHandlerContext = {
      existingTransferredToken: unit => option<tokenEntity>,
      insert: tokenEntity => unit,
      update: tokenEntity => unit,
      delete: id => unit,
    }
    @genType
    type context = {
      user: userEntityHandlerContext,
      gravatar: gravatarEntityHandlerContext,
      nftcollection: nftcollectionEntityHandlerContext,
      token: tokenEntityHandlerContext,
    }

    type userEntityLoaderContext = {
      userFromLoad: (id, ~loaders: userLoaderConfig=?) => unit,
      userToLoad: (id, ~loaders: userLoaderConfig=?) => unit,
    }
    type nftcollectionEntityLoaderContext = {nftCollectionUpdatedLoad: id => unit}
    type tokenEntityLoaderContext = {
      existingTransferredTokenLoad: (id, ~loaders: tokenLoaderConfig=?) => unit,
    }

    @genType
    type loaderContext = {
      user: userEntityLoaderContext,
      nftcollection: nftcollectionEntityLoaderContext,
      token: tokenEntityLoaderContext,
    }
  }
}

type event =
  | GravatarContract_NewGravatar(eventLog<GravatarContract.NewGravatarEvent.eventArgs>)
  | GravatarContract_UpdatedGravatar(eventLog<GravatarContract.UpdatedGravatarEvent.eventArgs>)
  | NftFactoryContract_SimpleNftCreated(
      eventLog<NftFactoryContract.SimpleNftCreatedEvent.eventArgs>,
    )
  | SimpleNftContract_Transfer(eventLog<SimpleNftContract.TransferEvent.eventArgs>)

type eventAndContext =
  | GravatarContract_NewGravatarWithContext(
      eventLog<GravatarContract.NewGravatarEvent.eventArgs>,
      GravatarContract.NewGravatarEvent.context,
    )
  | GravatarContract_UpdatedGravatarWithContext(
      eventLog<GravatarContract.UpdatedGravatarEvent.eventArgs>,
      GravatarContract.UpdatedGravatarEvent.context,
    )
  | NftFactoryContract_SimpleNftCreatedWithContext(
      eventLog<NftFactoryContract.SimpleNftCreatedEvent.eventArgs>,
      NftFactoryContract.SimpleNftCreatedEvent.context,
    )
  | SimpleNftContract_TransferWithContext(
      eventLog<SimpleNftContract.TransferEvent.eventArgs>,
      SimpleNftContract.TransferEvent.context,
    )

@spice
type eventName =
  | @spice.as("GravatarContract_NewGravatarEvent") GravatarContract_NewGravatarEvent
  | @spice.as("GravatarContract_UpdatedGravatarEvent") GravatarContract_UpdatedGravatarEvent
  | @spice.as("NftFactoryContract_SimpleNftCreatedEvent") NftFactoryContract_SimpleNftCreatedEvent
  | @spice.as("SimpleNftContract_TransferEvent") SimpleNftContract_TransferEvent

let eventNameToString = (eventName: eventName) =>
  switch eventName {
  | GravatarContract_NewGravatarEvent => "NewGravatar"
  | GravatarContract_UpdatedGravatarEvent => "UpdatedGravatar"
  | NftFactoryContract_SimpleNftCreatedEvent => "SimpleNftCreated"
  | SimpleNftContract_TransferEvent => "Transfer"
  }
