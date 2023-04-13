exception UndefinedEvent(string)
exception UndefinedContract(Ethers.ethAddress, int)

let getContractNameFromAddress = (contractAddress: Ethers.ethAddress, chainId: int): string => {
  switch (contractAddress->Ethers.ethAddressToString, chainId) {
  // TODO: make 'contracts' be per contract type/name, and have addresses as an array inside each contract.
  | ("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC", 137) => "Gravatar"
  | _ => UndefinedContract(contractAddress, chainId)->raise
  }
}
let eventStringToEvent = (eventName: string, contractName: string): Types.eventName => {
  switch (eventName, contractName) {
  | ("NewGravatar", "Gravatar") => GravatarContract_NewGravatarEvent
  | ("UpdatedGravatar", "Gravatar") => GravatarContract_UpdatedGravatarEvent
  | _ => UndefinedEvent(eventName)->raise
  }
}

module Gravatar = {
  let convertNewGravatarLogDescription = (log: Ethers.logDescription<'a>): Ethers.logDescription<
    Types.GravatarContract.newGravatarEvent,
  > => {
    log->Obj.magic
  }

  let convertNewGravatarLog = async (
    logDescription: Ethers.logDescription<Types.GravatarContract.newGravatarEvent>,
    ~log: Ethers.log,
    ~blockPromise: promise<Ethers.JsonRpcProvider.block>,
  ) => {
    let params: Types.GravatarContract.newGravatarEvent = {
      id: logDescription.args.id,
      owner: logDescription.args.owner,
      imageUrl: logDescription.args.imageUrl,
      displayName: logDescription.args.displayName,
    }
    let block = await blockPromise

    let newGravatarLog: Types.eventLog<Types.GravatarContract.newGravatarEvent> = {
      params,
      blockNumber: block.number,
      blockTimestamp: block.timestamp,
      blockHash: log.blockHash,
      srcAddress: log.address->Ethers.ethAddressToString,
      transactionHash: log.transactionHash,
      transactionIndex: log.transactionIndex,
      logIndex: log.logIndex,
    }
    Types.GravatarContract_NewGravatar(newGravatarLog)
  }

  let convertUpdatedGravatarLogDescription = (
    log: Ethers.logDescription<'a>,
  ): Ethers.logDescription<Types.GravatarContract.updatedGravatarEvent> => {
    log->Obj.magic
  }

  let convertUpdatedGravatarLog = async (
    logDescription: Ethers.logDescription<Types.GravatarContract.updatedGravatarEvent>,
    ~log: Ethers.log,
    ~blockPromise: promise<Ethers.JsonRpcProvider.block>,
  ) => {
    let params: Types.GravatarContract.updatedGravatarEvent = {
      id: logDescription.args.id,
      owner: logDescription.args.owner,
      imageUrl: logDescription.args.imageUrl,
      displayName: logDescription.args.displayName,
    }
    let block = await blockPromise

    let updatedGravatarLog: Types.eventLog<Types.GravatarContract.updatedGravatarEvent> = {
      params,
      blockNumber: block.number,
      blockTimestamp: block.timestamp,
      blockHash: log.blockHash,
      srcAddress: log.address->Ethers.ethAddressToString,
      transactionHash: log.transactionHash,
      transactionIndex: log.transactionIndex,
      logIndex: log.logIndex,
    }
    Types.GravatarContract_UpdatedGravatar(updatedGravatarLog)
  }
}
