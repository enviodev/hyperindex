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

type hex = EvmTypes.Hex.t
@module("viem") external toHex: 'a => hex = "toHex"
@module("viem") external keccak256: hex => hex = "keccak256"
@module("viem") external keccak256Bytes: bytes => hex = "keccak256"
@module("viem") external pad: hex => hex = "pad"
@module("viem")
external encodePacked: (~types: array<string>, ~values: array<'a>) => hex = "encodePacked"

type sizeOptions = {size: int}
@module("viem") external intToHex: (int, ~options: sizeOptions=?) => hex = "numberToHex"
@module("viem") external bigintToHex: (bigint, ~options: sizeOptions=?) => hex = "numberToHex"
@module("viem") external stringToHex: (string, ~options: sizeOptions=?) => hex = "stringToHex"
@module("viem") external boolToHex: (bool, ~options: sizeOptions=?) => hex = "boolToHex"
@module("viem") external bytesToHex: (bytes, ~options: sizeOptions=?) => hex = "bytesToHex"
@module("viem") external concat: array<hex> => hex = "concat"
