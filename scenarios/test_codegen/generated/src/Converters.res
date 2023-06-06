type contractName = string
type chainId = int
exception UndefinedEvent(string)
exception UndefinedContractAddress(Ethers.ethAddress, chainId)
exception UndefinedContractName(contractName, chainId)

module ContractNameAddressMappings: {
  let getContractNameFromAddress: (~chainId: int, ~contractAddress: Ethers.ethAddress) => string
  let addContractAddress: (
    ~chainId: int,
    ~contractName: string,
    ~contractAddress: Ethers.ethAddress,
  ) => unit
  let getAddressesFromContractName: (
    ~chainId: int,
    ~contractName: string,
  ) => array<Ethers.ethAddress>
  let registerStaticAddresses: (~chainConfig: Config.chainConfig) => unit
} = {
  let globalMutable = ContractAddressingMap.makeChainMappings()

  let addContractAddress = (
    ~chainId: int,
    ~contractName: string,
    ~contractAddress: Ethers.ethAddress,
  ) => {
    globalMutable->ContractAddressingMap.addChainAddress(~chainId, ~contractName, ~contractAddress)
  }

  let getContractNameFromAddress = (~chainId: int, ~contractAddress: Ethers.ethAddress) => {
    switch globalMutable->ContractAddressingMap.getChainRegistry(~chainId) {
    | None =>
      Logging.error(`chainId ${chainId->Belt.Int.toString} was not constructed in address mapping`)
      UndefinedContractAddress(contractAddress, chainId)->raise
    | Some(registry) =>
      switch ContractAddressingMap.getName(registry, contractAddress->Ethers.ethAddressToString) {
      | None => {
          Logging.error(
            `contract address ${contractAddress->Ethers.ethAddressToString} on chainId ${chainId->Belt.Int.toString} was not found in address store`,
          )
          UndefinedContractAddress(contractAddress, chainId)->raise
        }

      | Some(contractName) => contractName
      }
    }
  }

  let stringsToAddresses: array<string> => array<Ethers.ethAddress> = Obj.magic

  let getAddressesFromContractName = (~chainId, ~contractName) => {
    switch globalMutable->ContractAddressingMap.getChainRegistry(~chainId) {
    | None => {
        Logging.error(
          `chainId ${chainId->Belt.Int.toString} was not constructed in address mapping`,
        )
        UndefinedContractName(contractName, chainId)->raise
      }

    | Some(registry) =>
      switch ContractAddressingMap.getAddresses(registry, contractName) {
      | Some(addresses) => addresses
      | None => Belt.Set.String.empty
      }
      ->Belt.Set.String.toArray
      ->stringsToAddresses
    }
  }

  // Insert the static address into the Contract <-> Address bi-mapping
  let registerStaticAddresses = (~chainConfig: Config.chainConfig) => {
    chainConfig.contracts->Belt.Array.forEach(contract => {
      contract.addresses->Belt.Array.forEach(address => {
        globalMutable->ContractAddressingMap.addChainAddress(
          ~chainId=chainConfig.chainId,
          ~contractName=contract.name,
          ~contractAddress=address,
        )
      })
    })
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
      srcAddress: log.address,
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
      srcAddress: log.address,
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
      srcAddress: log.address,
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
      srcAddress: log.address,
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
      srcAddress: log.address,
      transactionHash: log.transactionHash,
      transactionIndex: log.transactionIndex,
      logIndex: log.logIndex,
    }
    Types.SimpleNftContract_Transfer(transferLog)
  }
}
