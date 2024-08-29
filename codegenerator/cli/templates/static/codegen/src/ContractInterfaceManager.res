/**
This module helps encapsulate/abstract a set of contract abis,
interfaces and their related contracts and addresses.

Used to work with event topic hashes and in the parsing of events.
*/
type interfaceAndAbi = {
  interface: Ethers.Interface.t,
  abi: Ethers.abi,
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
    let {name, abi} = contract
    let interface = Ethers.Interface.make(~abi)
    contractNameInterfaceMapping->Js.Dict.set(name, {interface, abi})
  })

  {contractAddressMapping, contractNameInterfaceMapping}
}

let getAbiMapping = (self: t) => {
  self.contractAddressMapping.nameByAddress
  ->Js.Dict.entries
  ->Belt.Array.keepMap(((addr, name)) => {
    self.contractNameInterfaceMapping->Js.Dict.get(name)->Belt.Option.map(v => (addr, v.abi))
  })
  ->Js.Dict.fromArray
}

let getInterfaceByName = (self: t, ~contractName) =>
  self.contractNameInterfaceMapping->Js.Dict.get(contractName)

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
  let {abi, name} = contract
  let interface = Ethers.Interface.make(~abi)
  contractNameInterfaceMapping->Js.Dict.set(name, {interface, abi})
  contractAddressMapping->ContractAddressingMap.addAddress(
    ~name=contract.name,
    ~address=contractAddress,
  )

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
  topics: array<Ethers.EventFilter.topic>,
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
        interface.interface->Ethers.Interface.forEachEvent((eventFragment, _i) => {
          topics->Js.Array2.push(eventFragment.topicHash)->ignore
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

let getLogSelection = (self: t): result<array<LogSelection.t>, exn> => {
  try {
    self.contractAddressMapping.addressesByName
    ->Js.Dict.keys
    ->Belt.Array.map(contractName => {
      let interfaceOpt = self->getInterfaceByName(~contractName)
      switch interfaceOpt {
      | None => UndefinedInterface(contractName)->raise
      | Some({interface}) => {
          let topic0 = []
          //Add the topic hash from each event on the interface
          interface->Ethers.Interface.forEachEvent((eventFragment, _i) => {
            topic0->Js.Array2.push(eventFragment.topicHash)->ignore
          })

          let topicSelection = LogSelection.makeTopicSelection(~topic0)->Utils.unwrapResultExn

          let addresses = []
          //Add the addresses for each contract
          self.contractAddressMapping
          ->ContractAddressingMap.getAddressesFromContractName(~contractName)
          ->Belt.Array.forEach(address => addresses->Js.Array2.push(address)->ignore)

          LogSelection.make(~addresses, ~topicSelections=[topicSelection])
        }
      }
    })
    ->Ok
  } catch {
  | exn => exn->Error
  }
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

type parseError = ParseError(Viem.decodeEventLogError) | UndefinedInterface(Address.t)

let parseLogViem = (self: t, ~log: Types.Log.t) => {
  let abiOpt =
    self
    ->getInterfaceByAddress(~contractAddress=log.address)
    ->Belt.Option.map(mapping => mapping.abi)
  switch abiOpt {
  | None => Error(UndefinedInterface(log.address))
  | Some(abi) =>
    let viemLog: Viem.eventLog = {
      abi,
      data: log.data,
      topics: log.topics,
    }

    switch viemLog->Viem.decodeEventLog {
    | Error(e) => Error(ParseError(e))
    | Ok(v) => Ok(v)
    }
  }
}
