/**
This module helps encapsulate/abstract a set of contract abis,
interfaces and their related contracts and addresses.

Used to work with event topic hashes and in the parsing of events.
*/
type interfaceAndAbi = {
  abi: Ethers.abi,
}
type t = {
  contractAddressMapping: ContractAddressingMap.mapping,
  contractNameInterfaceMapping: dict<interfaceAndAbi>,
}

let make = (
  ~contractNameInterfaceMapping: dict<interfaceAndAbi>,
  ~contractAddressMapping: ContractAddressingMap.mapping,
): t => {
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

let getContractNameFromAddress = (self: t, ~contractAddress) => {
  self.contractAddressMapping->ContractAddressingMap.getContractNameFromAddress(~contractAddress)
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
