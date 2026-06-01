let isEarlierUnordered = (item1: (int, int, int), item2: (int, int, int)) => {
  item1 < item2
}

// type eventIndex = {
//   blockNumber: int,
//   logIndex: int,
// }
//

// takes blockNumber, logIndex and packs them into a number with
//32 bits, 16 bits and 16 bits respectively
let packEventIndex = (~blockNumber, ~logIndex) => {
  let blockNumber = blockNumber->BigInt.fromInt
  let logIndex = logIndex->BigInt.fromInt
  let blockNumber = BigInt.shiftLeft(blockNumber, 16->BigInt.fromInt)

  blockNumber->BigInt.bitwiseOr(logIndex)
}

// //Currently not used but keeping in utils
// //using @live flag for dead code analyser
// @live
// let packMultiChainEventIndex = (~timestamp, ~chainId, ~blockNumber, ~logIndex) => {
//   let timestamp = timestamp->BigInt.fromInt
//   let chainId = chainId->BigInt.fromInt
//   let blockNumber = blockNumber->BigInt.fromInt
//   let logIndex = logIndex->BigInt.fromInt

//   let timestamp = BigInt.shiftLeft(timestamp, 48->BigInt.fromInt)
//   let chainId = BigInt.shiftLeft(chainId, 16->BigInt.fromInt)
//   let blockNumber = BigInt.shiftLeft(blockNumber, 16->BigInt.fromInt)

//   timestamp
//   ->BigInt.bitwiseOr(chainId)
//   ->BigInt.bitwiseOr(blockNumber)
//   ->BigInt.bitwiseOr(logIndex)
// }

// //Currently not used but keeping in utils
// //using @live flag for dead code analyser
// @live
// let unpackEventIndex = (packedEventIndex: bigint) => {
//   let blockNumber = packedEventIndex->BigInt.shiftRight(16->BigInt.fromInt)
//   let logIndexMask = 65535->BigInt.fromInt
//   let logIndex = packedEventIndex->BigInt.bitwiseAnd(logIndexMask)
//   {
//     blockNumber: blockNumber->BigInt.toString->Belt.Int.fromString->Belt.Option.getUnsafe,
//     logIndex: logIndex->BigInt.toString->Belt.Int.fromString->Belt.Option.getUnsafe,
//   }
// }

// //takes an eventIndex record and returnts a packed event index
// //used in TS tests
// @live
// let packEventIndexFromRecord = (eventIndex: eventIndex) => {
//   packEventIndex(~blockNumber=eventIndex.blockNumber, ~logIndex=eventIndex.logIndex)
// }
