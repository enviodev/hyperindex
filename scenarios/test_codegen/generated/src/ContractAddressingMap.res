type contractName = string
type chainId = int

// Mappings per chain

// Currently this mapping append only, so we don't need to worry about
// protecting static addresses from de-registration.

type mapping = {
  nameByAddress: Js.Dict.t<contractName>,
  addressesByName: Js.Dict.t<Belt.Set.String.t>,
}

let addAddress = (map: mapping, name: string, address: string) => {
  map.nameByAddress->Js.Dict.set(address, name)

  let oldAddresses =
    map.addressesByName->Js.Dict.get(name)->Belt.Option.getWithDefault(Belt.Set.String.empty)
  let newAddresses = oldAddresses->Belt.Set.String.add(address)
  map.addressesByName->Js.Dict.set(name, newAddresses)
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

// Mappings across all the chains

type chainMappings = private Js.Dict.t<mapping>

let getChainRegistry = (map: chainMappings, ~chainId: int) => {
  Js.Dict.get(Obj.magic(map), Belt.Int.toString(chainId))
}

let addChainAddress = (
  map: chainMappings,
  ~chainId: int,
  ~contractName: string,
  ~contractAddress: Ethers.ethAddress,
) => {
  let key = Belt.Int.toString(chainId)
  let inner = switch Js.Dict.get(Obj.magic(map), key) {
  | Some(value) => value
  | None =>
    let empty = make()
    Js.Dict.set(Obj.magic(map), key, empty)
    empty
  }
  addAddress(inner, contractName, Ethers.ethAddressToString(contractAddress))
}

let makeChainMappings = (): chainMappings => Obj.magic(Js.Dict.empty())
