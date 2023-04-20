//*************
//***ENTITIES**
//*************

type id = string

type entityRead =
  | UserRead(id)
  | GravatarRead(id)

let entitySerialize = (entity: entityRead) => {
  switch entity {
  | UserRead(id) => `user${id}`
  | GravatarRead(id) => `gravatar${id}`
  }
}

type userEntity = {
  id: string,
  address: string,
  gravatar: option<id>,
}

type gravatarEntity = {
  id: string,
  owner: id,
  displayName: string,
  imageUrl: string,
  updatesCount: int,
}

type entity =
  | UserEntity(userEntity)
  | GravatarEntity(gravatarEntity)

type crud = Create | Read | Update | Delete

type inMemoryStoreRow<'a> = {
  crud: crud,
  entity: 'a,
}

//*************
//**CONTRACTS**
//*************

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
  module NewGravatarEvent = {
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
    type context = {
      user: userEntityHandlerContext,
      gravatar: gravatarEntityHandlerContext,
    }

    type loaderContext = {}
  }
  module UpdatedGravatarEvent = {
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
      insert: gravatarEntity => unit,
      update: gravatarEntity => unit,
      delete: id => unit,
    }
    type context = {
      user: userEntityHandlerContext,
      gravatar: gravatarEntityHandlerContext,
    }

    type gravatarEntityLoaderContext = {gravatarWithChangesLoad: id => unit}

    type loaderContext = {gravatar: gravatarEntityLoaderContext}
  }
}

type event =
  | GravatarContract_NewGravatar(eventLog<GravatarContract.NewGravatarEvent.eventArgs>)
  | GravatarContract_UpdatedGravatar(eventLog<GravatarContract.UpdatedGravatarEvent.eventArgs>)

type eventAndContext =
  | GravatarContract_NewGravatarWithContext(
      eventLog<GravatarContract.NewGravatarEvent.eventArgs>,
      GravatarContract.NewGravatarEvent.context,
    )
  | GravatarContract_UpdatedGravatarWithContext(
      eventLog<GravatarContract.UpdatedGravatarEvent.eventArgs>,
      GravatarContract.UpdatedGravatarEvent.context,
    )

type eventName =
  | GravatarContract_NewGravatarEvent
  | GravatarContract_UpdatedGravatarEvent

let eventNameToString = (eventName: eventName) =>
  switch eventName {
  | GravatarContract_NewGravatarEvent => "NewGravatar"
  | GravatarContract_UpdatedGravatarEvent => "UpdatedGravatar"
  }
