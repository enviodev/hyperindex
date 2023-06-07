exception UndefinedEvent(string)
exception UndefinedContract(Ethers.ethAddress, int)

let getContractNameFromAddress = (contractAddress: Ethers.ethAddress, chainId: int): string => {
  switch (contractAddress->Ethers.ethAddressToString, chainId->Belt.Int.toString) {
  // TODO: make 'contracts' be per contract type/name, and have addresses as an array inside each contract.
  | ("0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3", "1337") => "Gravatar"
  // TODO: make 'contracts' be per contract type/name, and have addresses as an array inside each contract.
  | ("0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC", "1337") => "NftFactory"
  // TODO: make 'contracts' be per contract type/name, and have addresses as an array inside each contract.
  | ("0x93606B31d10C407F13D9702eC4E0290Fd7E32852", "1337") => "SimpleNft"
  | _ => UndefinedContract(contractAddress, chainId)->raise
  }
}
let eventStringToEvent = (eventName: string, contractName: string): Types.eventName => {
  switch (eventName, contractName) {
  | ("TestEvent", "Gravatar") => GravatarContract_TestEventEvent
  | ("NewGravatar", "Gravatar") => GravatarContract_NewGravatarEvent
  | ("UpdatedGravatar", "Gravatar") => GravatarContract_UpdatedGravatarEvent
  | ("SimpleNftCreated", "NftFactory") => NftFactoryContract_SimpleNftCreatedEvent
  | ("Transfer", "SimpleNft") => SimpleNftContract_TransferEvent
  | _ => UndefinedEvent(eventName)->raise
  }
}

module Gravatar = {
  let convertTestEventLogDescription = (log: Ethers.logDescription<'a>): Ethers.logDescription<
    Types.GravatarContract.TestEventEvent.eventArgs,
  > => {
    log->Obj.magic
  }

  let convertTestEventLog = async (
    logDescription: Ethers.logDescription<Types.GravatarContract.TestEventEvent.eventArgs>,
    ~log: Ethers.log,
    ~blockPromise: promise<Ethers.JsonRpcProvider.block>,
  ) => {
    let params: Types.GravatarContract.TestEventEvent.eventArgs = {
      id: logDescription.args.id,
      user: logDescription.args.user,
      contactDetails: logDescription.args.contactDetails,
    }
    let block = await blockPromise

    let testEventLog: Types.eventLog<Types.GravatarContract.TestEventEvent.eventArgs> = {
      params,
      blockNumber: block.number,
      blockTimestamp: block.timestamp,
      blockHash: log.blockHash,
      srcAddress: log.address->Ethers.ethAddressToString,
      transactionHash: log.transactionHash,
      transactionIndex: log.transactionIndex,
      logIndex: log.logIndex,
    }
    Types.GravatarContract_TestEvent(testEventLog)
  }

  let convertNewGravatarLogDescription = (log: Ethers.logDescription<'a>): Ethers.logDescription<
    Types.GravatarContract.NewGravatarEvent.eventArgs,
  > => {
    log->Obj.magic
  }

  let convertNewGravatarLog = async (
    logDescription: Ethers.logDescription<Types.GravatarContract.NewGravatarEvent.eventArgs>,
    ~log: Ethers.log,
    ~blockPromise: promise<Ethers.JsonRpcProvider.block>,
  ) => {
    let params: Types.GravatarContract.NewGravatarEvent.eventArgs = {
      id: logDescription.args.id,
      owner: logDescription.args.owner,
      displayName: logDescription.args.displayName,
      imageUrl: logDescription.args.imageUrl,
    }
    let block = await blockPromise

    let newGravatarLog: Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs> = {
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
  ): Ethers.logDescription<Types.GravatarContract.UpdatedGravatarEvent.eventArgs> => {
    log->Obj.magic
  }

  let convertUpdatedGravatarLog = async (
    logDescription: Ethers.logDescription<Types.GravatarContract.UpdatedGravatarEvent.eventArgs>,
    ~log: Ethers.log,
    ~blockPromise: promise<Ethers.JsonRpcProvider.block>,
  ) => {
    let params: Types.GravatarContract.UpdatedGravatarEvent.eventArgs = {
      id: logDescription.args.id,
      owner: logDescription.args.owner,
      displayName: logDescription.args.displayName,
      imageUrl: logDescription.args.imageUrl,
    }
    let block = await blockPromise

    let updatedGravatarLog: Types.eventLog<
      Types.GravatarContract.UpdatedGravatarEvent.eventArgs,
    > = {
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

module NftFactory = {
  let convertSimpleNftCreatedLogDescription = (
    log: Ethers.logDescription<'a>,
  ): Ethers.logDescription<Types.NftFactoryContract.SimpleNftCreatedEvent.eventArgs> => {
    log->Obj.magic
  }

  let convertSimpleNftCreatedLog = async (
    logDescription: Ethers.logDescription<Types.NftFactoryContract.SimpleNftCreatedEvent.eventArgs>,
    ~log: Ethers.log,
    ~blockPromise: promise<Ethers.JsonRpcProvider.block>,
  ) => {
    let params: Types.NftFactoryContract.SimpleNftCreatedEvent.eventArgs = {
      name: logDescription.args.name,
      symbol: logDescription.args.symbol,
      maxSupply: logDescription.args.maxSupply,
      contractAddress: logDescription.args.contractAddress,
    }
    let block = await blockPromise

    let simpleNftCreatedLog: Types.eventLog<
      Types.NftFactoryContract.SimpleNftCreatedEvent.eventArgs,
    > = {
      params,
      blockNumber: block.number,
      blockTimestamp: block.timestamp,
      blockHash: log.blockHash,
      srcAddress: log.address->Ethers.ethAddressToString,
      transactionHash: log.transactionHash,
      transactionIndex: log.transactionIndex,
      logIndex: log.logIndex,
    }
    Types.NftFactoryContract_SimpleNftCreated(simpleNftCreatedLog)
  }
}

module SimpleNft = {
  let convertTransferLogDescription = (log: Ethers.logDescription<'a>): Ethers.logDescription<
    Types.SimpleNftContract.TransferEvent.eventArgs,
  > => {
    log->Obj.magic
  }

  let convertTransferLog = async (
    logDescription: Ethers.logDescription<Types.SimpleNftContract.TransferEvent.eventArgs>,
    ~log: Ethers.log,
    ~blockPromise: promise<Ethers.JsonRpcProvider.block>,
  ) => {
    let params: Types.SimpleNftContract.TransferEvent.eventArgs = {
      from: logDescription.args.from,
      to: logDescription.args.to,
      tokenId: logDescription.args.tokenId,
    }
    let block = await blockPromise

    let transferLog: Types.eventLog<Types.SimpleNftContract.TransferEvent.eventArgs> = {
      params,
      blockNumber: block.number,
      blockTimestamp: block.timestamp,
      blockHash: log.blockHash,
      srcAddress: log.address->Ethers.ethAddressToString,
      transactionHash: log.transactionHash,
      transactionIndex: log.transactionIndex,
      logIndex: log.logIndex,
    }
    Types.SimpleNftContract_Transfer(transferLog)
  }
}
