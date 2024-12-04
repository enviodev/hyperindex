/**
This module helps encapsulate/abstract a set of contract abis,
interfaces and their related contracts and addresses.

Used to work with event topic hashes and in the parsing of events.
*/
type interfaceAndAbi = {
  abi: Ethers.abi,
  sighashes: array<string>,
}
type t = {
  contractAddressMapping: ContractAddressingMap.mapping,
  contractNameInterfaceMapping: dict<interfaceAndAbi>,
}

let make = (
  ~contracts: array<Config.contract>,
  ~contractAddressMapping: ContractAddressingMap.mapping,
): t => {
  let contractNameInterfaceMapping = Js.Dict.empty()

  contracts->Belt.Array.forEach(contract => {
    contractNameInterfaceMapping->Js.Dict.set(contract.name, (contract :> interfaceAndAbi))
  })

  {contractAddressMapping, contractNameInterfaceMapping}
}

let getInterfaceByName = (self: t, ~contractName) =>
  self.contractNameInterfaceMapping->Utils.Dict.dangerouslyGetNonOption(contractName)

let getInterfaceByAddress = (self: t, ~contractAddress) => {
  self.contractAddressMapping
  ->ContractAddressingMap.getContractNameFromAddress(~contractAddress)
  ->Belt.Option.flatMap(contractName => {
    self->getInterfaceByName(~contractName)
  })
}

type contractName = string
exception UndefinedInterface(contractName)
exception UndefinedContract(contractName)

let makeFromSingleContract = (
  ~chainConfig: Config.chainConfig,
  ~contractAddress,
  ~contractName,
): t => {
  let contract = switch chainConfig.contracts->Js.Array2.find(configContract =>
    configContract.name == contractName
  ) {
  | None =>
    let exn = UndefinedContract(contractName)
    Logging.errorWithExn(
      exn,
      `EE900: Unexpected undefined contract ${contractName} on chain ${chainConfig.chain->ChainMap.Chain.toString}. Please verify the contract name defined in the config.yaml file.`,
    )
    exn->raise
  | Some(c) => c
  }

  let contractNameInterfaceMapping = Js.Dict.empty()
  let contractAddressMapping = ContractAddressingMap.make()
  let {name} = contract
  contractNameInterfaceMapping->Js.Dict.set(name, (contract :> interfaceAndAbi))
  contractAddressMapping->ContractAddressingMap.addAddress(~name, ~address=contractAddress)

  {contractNameInterfaceMapping, contractAddressMapping}
}

//Useful for taking single address interface mappings and merging them
let combineInterfaceManagers = (managers: array<t>): t => {
  let contractAddressMapping = ContractAddressingMap.make()
  let contractNameInterfaceMapping = Js.Dict.empty()

  managers->Belt.Array.forEach(manager => {
    //Loop through address mappings and add them to combined mapping
    manager.contractAddressMapping.nameByAddress
    ->Js.Dict.values
    ->Belt.Array.forEach(contractName => {
      manager.contractAddressMapping
      ->ContractAddressingMap.getAddressesFromContractName(~contractName)
      ->Belt.Array.forEach(
        contractAddress => {
          contractAddressMapping->ContractAddressingMap.addAddress(
            ~name=contractName,
            ~address=contractAddress,
          )
        },
      )
    })

    //Loop through interfaces and add dhtem to combined interface mapping
    manager.contractNameInterfaceMapping
    ->Js.Dict.entries
    ->Belt.Array.forEach(((key, val)) => {
      contractNameInterfaceMapping->Js.Dict.set(key, val)
    })
  })

  {
    contractAddressMapping,
    contractNameInterfaceMapping,
  }
}

type addressesAndTopics = {
  addresses: array<Address.t>,
  topics: array<EvmTypes.Hex.t>,
}

//Returns a flattened unified mapping with all contract addresses
//and topics (not subdivided by contract)
let getAllTopicsAndAddresses = (self: t): addressesAndTopics => {
  let topics = []
  let addresses = []
  self.contractAddressMapping.addressesByName
  ->Js.Dict.keys
  ->Belt.Array.forEach(contractName => {
    let interfaceOpt = self->getInterfaceByName(~contractName)
    switch interfaceOpt {
    | None =>
      let exn = UndefinedInterface(contractName)
      Logging.errorWithExn(
        exn,
        "EE901: Unexpected case. Contract name does not exist in interface mapping.",
      )
      exn->raise
    | Some(interface) => {
        //Add the topic hash from each event on the interface
        interface.sighashes->Js.Array2.forEach(topic0 => {
          topics->Js.Array2.push(topic0->EvmTypes.Hex.fromStringUnsafe)->ignore
        })

        //Add the addresses for each contract
        self.contractAddressMapping
        ->ContractAddressingMap.getAddressesFromContractName(~contractName)
        ->Belt.Array.forEach(address => addresses->Js.Array2.push(address)->ignore)
      }
    }
  })

  {addresses, topics}
}

let getContractNameFromAddress = (self: t, ~contractAddress) => {
  self.contractAddressMapping->ContractAddressingMap.getContractNameFromAddress(~contractAddress)
}

let getCombinedEthersFilter = (
  self: t,
  ~fromBlock: int,
  ~toBlock: int,
): Ethers.CombinedFilter.combinedFilterRecord => {
  let {addresses, topics} = self->getAllTopicsAndAddresses

  //Just the topics of the event signature and no topics related
  //to indexed parameters
  let topLevelTopics = [topics]

  {
    address: addresses,
    topics: topLevelTopics,
    fromBlock: BlockNumber(fromBlock)->Ethers.BlockTag.blockTagFromVariant,
    toBlock: BlockNumber(toBlock)->Ethers.BlockTag.blockTagFromVariant,
  }
}

exception ParseError(exn)
exception UndefinedInterfaceAddress(Address.t)

let parseLogViemOrThrow = (self: t, ~address, ~topics, ~data) => {
  let abiOpt =
    self
    ->getInterfaceByAddress(~contractAddress=address)
    ->Belt.Option.map(mapping => mapping.abi)
  switch abiOpt {
  | None => raise(UndefinedInterfaceAddress(address))
  | Some(abi) =>
    let viemLog: Viem.eventLog = {
      abi,
      data,
      topics,
    }

    try viemLog->Viem.decodeEventLogOrThrow catch {
    | exn => raise(ParseError(exn))
    }
  }
}
