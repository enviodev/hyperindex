let toTwosComplement = (num: bigint, ~bytesLen: int) => {
  let maxValue = 1n->BigInt.Bitwise.shift_left(BigInt.fromInt(bytesLen * 8))
  let mask = maxValue->BigInt.sub(1n)
  num->BigInt.add(maxValue)->BigInt.Bitwise.logand(mask)
}

let fromSignedBigInt = val => {
  let bytesLen = 32
  let val = val >= 0n ? val : val->toTwosComplement(~bytesLen)
  val->Viem.bigintToHex(~options={size: bytesLen})
}

type hex = EvmTypes.Hex.t
//bytes currently does not work with genType and we also currently generate bytes as a string type
type bytesHex = string
let keccak256 = Viem.keccak256
let bytesToHex = Viem.bytesToHex
let concat = Viem.concat
let castToHexUnsafe: 'a => hex = val => val->Utils.magic
let fromBigInt: bigint => hex = val => val->Viem.bigintToHex(~options={size: 32})
let fromDynamicString: string => hex = val => val->(Utils.magic: string => hex)->keccak256
let fromString: string => hex = val => val->Viem.stringToHex(~options={size: 32})
let fromAddress: Address.t => hex = addr => addr->(Utils.magic: Address.t => hex)->Viem.pad
let fromDynamicBytes: bytesHex => hex = bytes => bytes->(Utils.magic: bytesHex => hex)->keccak256
let fromBytes: bytesHex => hex = bytes =>
  bytes->(Utils.magic: bytesHex => bytes)->Viem.bytesToHex(~options={size: 32})
let fromBool: bool => hex = b => b->Viem.boolToHex(~options={size: 32})
