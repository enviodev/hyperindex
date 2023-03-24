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
