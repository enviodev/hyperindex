//*************
//***ENTITIES**
//*************

type id = string

type entityRead = GravatarRead(id)

let entitySerialize = (entity: entityRead) => {
  switch entity {
  | GravatarRead(id) => `gravatar${id}`
  }
}

type gravatarEntity = {
  id: string,
  owner: string,
  displayName: string,
  imageUrl: string,
  updatesCount: int,
}

type entity = GravatarEntity(gravatarEntity)

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
    type gravatarEntityHandlerContext = {
      /// TODO: add named entities (this is hardcoded)
      gravatarWithChanges: unit => option<gravatarEntity>,
      insert: gravatarEntity => unit,
      update: gravatarEntity => unit,
      delete: id => unit,
    }
    type context = {gravatar: gravatarEntityHandlerContext}

    // TODO: these are hardcoded on all events, but should be generated based on the read config
    type gravatarEntityLoaderContext = {gravatarWithChangesLoad: id => unit}
    type loaderContext = {gravatar: gravatarEntityLoaderContext}
  }
  module UpdatedGravatarEvent = {
    type eventArgs = {
      id: Ethers.BigInt.t,
      owner: Ethers.ethAddress,
      displayName: string,
      imageUrl: string,
    }
    type gravatarEntityHandlerContext = {
      /// TODO: add named entities (this is hardcoded)
      gravatarWithChanges: unit => option<gravatarEntity>,
      insert: gravatarEntity => unit,
      update: gravatarEntity => unit,
      delete: id => unit,
    }
    type context = {gravatar: gravatarEntityHandlerContext}

    // TODO: these are hardcoded on all events, but should be generated based on the read config
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
