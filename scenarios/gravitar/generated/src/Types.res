type newGravatarEvent = {
  id: string,
  owner: string,
  displayName: string,
  imageUrl: string,
}
type updateGravatarEvent = {
  id: string,
  owner: string,
  displayName: string,
  imageUrl: string,
}

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

type event =
  | NewGravatar(eventLog<newGravatarEvent>)
  | UpdateGravatar(eventLog<updateGravatarEvent>)

// generated entity types:

type id = string

type entityRead = GravatarRead(id)

type gravatarEntity = {
  id: string,
  owner: string,
  displayName: string,
  imageUrl: string,
  updatesCount: int,
}

//*************
//** CONTEXT **
//*************

type gravitarController = {
  insert: gravatarEntity => unit,
  update: gravatarEntity => unit,
  readEntities: array<gravatarEntity>,
}

type context = {@as("Gravatar") gravatar: gravitarController}
