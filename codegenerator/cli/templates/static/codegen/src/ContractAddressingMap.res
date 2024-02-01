type contractName = string

exception UndefinedContractName(contractName, Types.chainId)
exception UndefinedContractAddress(Ethers.ethAddress)

// Currently this mapping append only, so we don't need to worry about
// protecting static addresses from de-registration.

type mapping = {
  nameByAddress: Js.Dict.t<contractName>,
  addressesByName: Js.Dict.t<Belt.Set.String.t>,
}

let addAddress = (map: mapping, ~name: string, ~address: Ethers.ethAddress) => {
  map.nameByAddress->Js.Dict.set(address->Ethers.ethAddressToString, name)

  let oldAddresses =
    map.addressesByName->Js.Dict.get(name)->Belt.Option.getWithDefault(Belt.Set.String.empty)
  let newAddresses = oldAddresses->Belt.Set.String.add(address->Ethers.ethAddressToString)
  map.addressesByName->Js.Dict.set(name, newAddresses)
}

/// This adds the address if it doesn't exist and returns a boolean to say if it already existed.
let addAddressIfNotExists = (map: mapping, ~name: string, ~address: Ethers.ethAddress): bool => {
  let addressIsNew =
    map.nameByAddress
    ->Js.Dict.get(address->Ethers.ethAddressToString)
    ->Belt.Option.mapWithDefault(true, expectedName => expectedName != name)

  /* check the name, since differently named contracts can have the same address */

  if addressIsNew {
    addAddress(map, ~name, ~address)
  }

  addressIsNew
}

let getAddresses = (map: mapping, name: string) => {
  map.addressesByName->Js.Dict.get(name)
}

let getName = (map: mapping, address: string) => {
  map.nameByAddress->Js.Dict.get(address)
}

let make = () => {
  nameByAddress: Js.Dict.empty(),
  addressesByName: Js.Dict.empty(),
}

// Insert the static address into the Contract <-> Address bi-mapping
let registerStaticAddresses = (mapping, ~chainConfig: Config.chainConfig, ~logger: Pino.t) => {
  chainConfig.contracts->Belt.Array.forEach(contract => {
    contract.addresses->Belt.Array.forEach(address => {
      Logging.childTrace(
        logger,
        {
          "msg": "adding contract address",
          "contractName": contract.name,
          "address": address,
        },
      )

      mapping->addAddress(~name=contract.name, ~address)
    })
  })
}

let getContractNameFromAddress = (mapping, ~contractAddress: Ethers.ethAddress): option<
  contractName,
> => {
  mapping->getName(contractAddress->Ethers.ethAddressToString)
}

let getContractNameFromAddressUnsafe = (
  mapping,
  ~contractAddress: Ethers.ethAddress,
  ~logger: Pino.t,
) => {
  switch mapping->getContractNameFromAddress(~contractAddress) {
  | None => {
      logger->Logging.childError(
        `contract address ${contractAddress->Ethers.ethAddressToString}  was not found in address store`,
      )

      UndefinedContractAddress(contractAddress)->raise
    }

  | Some(contractName) => contractName
  }
}

let stringsToAddresses: array<string> => array<Ethers.ethAddress> = Obj.magic

let getAddressesFromContractName = (mapping, ~contractName) => {
  switch mapping->getAddresses(contractName) {
  | Some(addresses) => addresses
  | None => Belt.Set.String.empty
  }
  ->Belt.Set.String.toArray
  ->stringsToAddresses
}

let getAllAddresses = (mapping: mapping) => {
  mapping.nameByAddress->Js.Dict.keys->stringsToAddresses
}

let combine = (a, b) => {
  let m = make()
  [a, b]->Belt.Array.forEach(v =>
    v.nameByAddress
    ->Js.Dict.entries
    ->Belt.Array.forEach(((addr, name)) => {
      m->addAddress(~address=addr->Obj.magic, ~name)
    })
  )
  m
}

let fromArray = (nameAddrTuples: array<(Ethers.ethAddress, string)>) => {
  let m = make()
  nameAddrTuples->Belt.Array.forEach(((address, name)) => m->addAddress(~name, ~address))
  m
}
