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
} = {
  type addressToContractName = Js.Dict.t<contractName>
  type contractNameToAddresses = Js.Dict.t<Belt.Set.String.t>
  type chainAddresses = Js.Dict.t<addressToContractName>
  type chainContractNames = Js.Dict.t<contractNameToAddresses>

  let chainAddresses: chainAddresses = Js.Dict.empty()
  let chainContractNames: chainContractNames = Js.Dict.empty()

  let addContractAddress = (~chainId: int, ~contractName, ~contractAddress: Ethers.ethAddress) => {
    let chainIdStr = chainId->Belt.Int.toString
    let addressesToContractName =
      chainAddresses->Js.Dict.get(chainIdStr)->Belt.Option.getWithDefault(Js.Dict.empty())
    let contractNameToAddresses =
      chainContractNames->Js.Dict.get(chainIdStr)->Belt.Option.getWithDefault(Js.Dict.empty())

    addressesToContractName->Js.Dict.set(contractAddress->Ethers.ethAddressToString, contractName)

    let addresses =
      contractNameToAddresses
      ->Js.Dict.get(contractName)
      ->Belt.Option.getWithDefault(Belt.Set.String.empty)

    let updatedAddresses =
      addresses->Belt.Set.String.add(contractAddress->Ethers.ethAddressToString)

    contractNameToAddresses->Js.Dict.set(contractName, updatedAddresses)
  }

  let getContractNameFromAddress = (~chainId: int, ~contractAddress: Ethers.ethAddress) => {
    let optAddressesToContractName = chainAddresses->Js.Dict.get(chainId->Belt.Int.toString)

    switch optAddressesToContractName {
    | None =>
      Logging.error(`chainId ${chainId->Belt.Int.toString} was not constructed in address mapping`)
      UndefinedContractAddress(contractAddress, chainId)->raise
    | Some(addressesToContractName) =>
      let contractName =
        addressesToContractName->Js.Dict.get(contractAddress->Ethers.ethAddressToString)
      switch contractName {
      | None =>
        Logging.error(
          `contract address ${contractAddress->Ethers.ethAddressToString} on chainId ${chainId->Belt.Int.toString} was not found in address store`,
        )
        UndefinedContractAddress(contractAddress, chainId)->raise
      | Some(contractName) => contractName
      }
    }
  }

  let stringsToAddresses: array<string> => array<Ethers.ethAddress> = Obj.magic

  let getAddressesFromContractName = (~chainId, ~contractName) => {
    let optContractNameToAddresses = chainContractNames->Js.Dict.get(chainId->Belt.Int.toString)

    switch optContractNameToAddresses {
    | None =>
      Logging.error(
        `chainId ${chainId->Belt.Int.toString} was not constructed in contract name mapping`,
      )
      UndefinedContractName(contractName, chainId)->raise
    | Some(contractNameToAddresses) =>
      // this set can be empty, indicating a contract template with no registered addresses
      let addresses =
        contractNameToAddresses
        ->Js.Dict.get(contractName)
        ->Belt.Option.getWithDefault(Belt.Set.String.empty)

      addresses->Belt.Set.String.toArray->stringsToAddresses
    }
  }
}

let getContractNameFromAddress = (contractAddress: Ethers.ethAddress, chainId: int): string => {
  switch (contractAddress->Ethers.ethAddressToString, chainId->Belt.Int.toString) {
  // TODO: make 'contracts' be per contract type/name, and have addresses as an array inside each contract.
  | ("0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3", "1337") => "Gravatar"
  // TODO: make 'contracts' be per contract type/name, and have addresses as an array inside each contract.
  | ("0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC", "1337") => "NftFactory"
  // TODO: make 'contracts' be per contract type/name, and have addresses as an array inside each contract.
  | ("0x93606B31d10C407F13D9702eC4E0290Fd7E32852", "1337") => "SimpleNft"
  | _ => UndefinedContractAddress(contractAddress, chainId)->raise
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
