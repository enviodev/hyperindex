type contractName = string

// Currently this mapping append only, so we don't need to worry about
// protecting static addresses from de-registration.

type mapping = {
  nameByAddress: dict<contractName>,
  addressesByName: dict<Belt.Set.String.t>,
}

let addAddress = (map: mapping, ~name: string, ~address: Address.t) => {
  map.nameByAddress->Js.Dict.set(address->Address.toString, name)

  let oldAddresses =
    map.addressesByName->Utils.Dict.dangerouslyGetNonOption(name)->Belt.Option.getWithDefault(Belt.Set.String.empty)
  let newAddresses = oldAddresses->Belt.Set.String.add(address->Address.toString)
  map.addressesByName->Js.Dict.set(name, newAddresses)
}

let getAddresses = (map: mapping, name: string) => {
  map.addressesByName->Utils.Dict.dangerouslyGetNonOption(name)
}

let getName = (map: mapping, address: string) => {
  map.nameByAddress->Utils.Dict.dangerouslyGetNonOption(address)
}

let make = () => {
  nameByAddress: Js.Dict.empty(),
  addressesByName: Js.Dict.empty(),
}

let getContractNameFromAddress = (mapping, ~contractAddress: Address.t): option<contractName> => {
  mapping->getName(contractAddress->Address.toString)
}

let stringsToAddresses: array<string> => array<Address.t> = Utils.magic
let keyValStringToAddress: array<(string, string)> => array<(Address.t, string)> = Utils.magic

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
      m->addAddress(~address=addr->Utils.magic, ~name)
    })
  )
  m
}

let fromArray = (nameAddrTuples: array<(Address.t, string)>) => {
  let m = make()
  nameAddrTuples->Belt.Array.forEach(((address, name)) => m->addAddress(~name, ~address))
  m
}

/**
Creates a new mapping from the previous without the addresses passed in as "addressesToRemove"
*/
let removeAddresses = (mapping: mapping, ~addressesToRemove: array<Address.t>) => {
  mapping.nameByAddress
  ->Js.Dict.entries
  ->Belt.Array.keep(((addr, _name)) => {
    let shouldRemove = addressesToRemove->Utils.Array.includes(addr->Utils.magic)
    !shouldRemove
  })
  ->keyValStringToAddress
  ->fromArray
}

let addressCount = (mapping: mapping) => mapping.nameByAddress->Js.Dict.keys->Belt.Array.length

let isEmpty = (mapping: mapping) => mapping->addressCount == 0
