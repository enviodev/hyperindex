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
@module("viem") external keccak256: hex => hex = "keccak256"
@module("viem") external pad: hex => hex = "pad"
@module("viem") external encodePacked: (~types:array<string>,  ~values:array<'a>) => hex = "encodePacked"

module TopicFilter = {
  let toHexAndPad = value => value->toHex->pad

  let fomBigInt: bigint => hex = toHexAndPad
  let fromString: string => hex = toHexAndPad
  let fromAddress: Address.t => hex = addr => addr->(Utils.magic: Address.t => hex)->pad
  let fromBytes: string => hex = bytes => bytes->(Utils.magic: string => hex)->pad
  let fromBool: bool => hex = b => (b ? 1 : 0)->toHexAndPad
}
