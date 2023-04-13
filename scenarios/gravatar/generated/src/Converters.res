type event = NewGravatar | UpdatedGravatar
exception UndefinedEvent(string)
let eventStringToEvent = (eventName: string) => {
  switch eventName {
  | "NewGravatar" => NewGravatar
  | "UpdatedGravatar" => UpdatedGravatar
  | _ => UndefinedEvent(eventName)->raise
  }
}

let convertNewGravatarLogDescription = (log: Ethers.logDescription<'a>): Ethers.logDescription<
  Types.newGravatarEvent,
> => {
  log->Obj.magic
}

let convertNewGravatarLog = async (
  logDescription: Ethers.logDescription<Types.newGravatarEvent>,
  ~log: Ethers.log,
  ~blockPromise: promise<Ethers.JsonRpcProvider.block>,
) => {
  let params: Types.newGravatarEvent = {
    id: logDescription.args.id,
    owner: logDescription.args.owner,
    imageUrl: logDescription.args.imageUrl,
    displayName: logDescription.args.displayName,
  }
  let block = await blockPromise

  let newGravatarLog: Types.eventLog<Types.newGravatarEvent> = {
    params,
    blockNumber: block.number,
    blockTimestamp: block.timestamp,
    blockHash: log.blockHash,
    srcAddress: log.address->Ethers.ethAddressToString,
    transactionHash: log.transactionHash,
    transactionIndex: log.transactionIndex,
    logIndex: log.logIndex,
  }
  Types.NewGravatar(newGravatarLog)
}

let convertUpdatedGravatarLogDescription = (log: Ethers.logDescription<'a>): Ethers.logDescription<
  Types.updatedGravatarEvent,
> => {
  log->Obj.magic
}

let convertUpdatedGravatarLog = async (
  logDescription: Ethers.logDescription<Types.updatedGravatarEvent>,
  ~log: Ethers.log,
  ~blockPromise: promise<Ethers.JsonRpcProvider.block>,
) => {
  let params: Types.updatedGravatarEvent = {
    id: logDescription.args.id,
    owner: logDescription.args.owner,
    imageUrl: logDescription.args.imageUrl,
    displayName: logDescription.args.displayName,
  }
  let block = await blockPromise

  let updatedGravatarLog: Types.eventLog<Types.updatedGravatarEvent> = {
    params,
    blockNumber: block.number,
    blockTimestamp: block.timestamp,
    blockHash: log.blockHash,
    srcAddress: log.address->Ethers.ethAddressToString,
    transactionHash: log.transactionHash,
    transactionIndex: log.transactionIndex,
    logIndex: log.logIndex,
  }
  Types.UpdatedGravatar(updatedGravatarLog)
}
