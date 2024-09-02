type eventLog = {
  abi: Ethers.abi,
  data: string,
  topics: array<Ethers.EventFilter.topic>,
}

type decodedEvent<'a> = {
  eventName: string,
  args: 'a,
}

@module("viem") external decodeEventLogOrThrow: eventLog => decodedEvent<'a> = "decodeEventLog"

type hex = string
@module("viem") external toHex: 'a => hex = "toHex"
@module("viem") external keccak256: 'a => hex = "keccak256"
@module("viem") external pad: hex => hex = "pad"
@module("viem")
external encodePacked: (~types: array<string>, ~values: array<'a>) => hex = "encodePacked"

type sizeOptions = {size: int}
@module("viem") external intToHex: (int, ~options: sizeOptions=?) => hex = "numberToHex"
@module("viem") external bigintToHex: (bigint, ~options: sizeOptions=?) => hex = "numberToHex"
@module("viem") external stringToHex: (string, ~options: sizeOptions=?) => hex = "stringToHex"
@module("viem") external boolToHex: (bool, ~options: sizeOptions=?) => hex = "boolToHex"
@module("viem") external bytesToHex: (bytes, ~options: sizeOptions=?) => hex = "bytesToHex"

module TopicFilter = {
  let toHexAndPad = value => value->toHex->pad
  let toHex = toHex
  let keccak256 = keccak256
  let encodePacked = encodePacked
  let bytesToHex = bytesToHex
  let fromBigInt: bigint => hex = val => val->bigintToHex(~options={size: 32})
  let fromString: string => hex = val => val->keccak256
  let fromAddress: Address.t => hex = addr => addr->(Utils.magic: Address.t => hex)->pad
  let fromDynamicBytes: bytes => hex = bytes => bytes->keccak256
  let fromBytes: bytes => hex = bytes => bytes->bytesToHex(~options={size: 32})
  let fromBool: bool => hex = b => b->boolToHex(~options={size: 32})
}
