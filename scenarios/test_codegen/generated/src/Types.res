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
//** CONTEXT **
//*************

type loadedEntitiesReader = {
  getUserById: id => option<userEntity>,
  getAllLoadedUser: unit => array<userEntity>,
  getGravatarById: id => option<gravatarEntity>,
  getAllLoadedGravatar: unit => array<gravatarEntity>,
}

type entityController<'a> = {
  insert: 'a => unit,
  update: 'a => unit,
  loadedEntities: loadedEntitiesReader,
}

type userController = entityController<userEntity>
type gravatarController = entityController<gravatarEntity>

type context = {
  @as("User") user: userController,
  @as("Gravatar") gravatar: gravatarController,
}
