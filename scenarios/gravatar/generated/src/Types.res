//************
//** EVENTS **
//************

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
  type newGravatarEvent = {
    id: Ethers.BigInt.t,
    owner: Ethers.ethAddress,
    displayName: string,
    imageUrl: string,
  }

  type updatedGravatarEvent = {
    id: Ethers.BigInt.t,
    owner: Ethers.ethAddress,
    displayName: string,
    imageUrl: string,
  }
}

type event =
  | GravatarContract_NewGravatar(eventLog<GravatarContract.newGravatarEvent>)
  | GravatarContract_UpdatedGravatar(eventLog<GravatarContract.updatedGravatarEvent>)

type eventName =
  | GravatarContract_NewGravatarEvent
  | GravatarContract_UpdatedGravatarEvent

let eventNameToString = (eventName: eventName) =>
  switch eventName {
  | GravatarContract_NewGravatarEvent => "NewGravatar"
  | GravatarContract_UpdatedGravatarEvent => "UpdatedGravatar"
  }

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
//** CONTEXT **
//*************

type loadedEntitiesReader = {
  getGravatarById: id => option<gravatarEntity>,
  getAllLoadedGravatar: unit => array<gravatarEntity>,
}

type entityController<'a> = {
  insert: 'a => unit,
  update: 'a => unit,
  loadedEntities: loadedEntitiesReader,
}

type gravatarController = entityController<gravatarEntity>

type context = {@as("Gravatar") gravatar: gravatarController}
