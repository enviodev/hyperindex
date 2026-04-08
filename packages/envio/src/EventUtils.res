//Comparator used when ordering multichain events
let getOrderedBatchItemComparator = (item: Internal.item) => {
  switch item {
  | Internal.Event({timestamp, chain, blockNumber, logIndex}) => (
      timestamp,
      chain->ChainMap.Chain.toChainId,
      blockNumber,
      logIndex,
    )
  | Internal.Block(_) =>
    Js.Exn.raiseError("Block handlers are not supported for ordered multichain mode.")
  }
}

let isEarlier = (item1: (int, int, int, int), item2: (int, int, int, int)) => {
  item1 < item2
}

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
  let blockNumber = blockNumber->Utils.BigInt.fromInt
  let logIndex = logIndex->Utils.BigInt.fromInt
  let blockNumber = Utils.BigInt.Bitwise.shift_left(blockNumber, 16->Utils.BigInt.fromInt)

  blockNumber->Utils.BigInt.Bitwise.logor(logIndex)
}

// //Currently not used but keeping in utils
// //using @live flag for dead code analyser
// @live
// let packMultiChainEventIndex = (~timestamp, ~chainId, ~blockNumber, ~logIndex) => {
//   let timestamp = timestamp->Utils.BigInt.fromInt
//   let chainId = chainId->Utils.BigInt.fromInt
//   let blockNumber = blockNumber->Utils.BigInt.fromInt
//   let logIndex = logIndex->Utils.BigInt.fromInt

//   let timestamp = Utils.BigInt.Bitwise.shift_left(timestamp, 48->Utils.BigInt.fromInt)
//   let chainId = Utils.BigInt.Bitwise.shift_left(chainId, 16->Utils.BigInt.fromInt)
//   let blockNumber = Utils.BigInt.Bitwise.shift_left(blockNumber, 16->Utils.BigInt.fromInt)

//   timestamp
//   ->Utils.BigInt.Bitwise.logor(chainId)
//   ->Utils.BigInt.Bitwise.logor(blockNumber)
//   ->Utils.BigInt.Bitwise.logor(logIndex)
// }

// //Currently not used but keeping in utils
// //using @live flag for dead code analyser
// @live
// let unpackEventIndex = (packedEventIndex: bigint) => {
//   let blockNumber = packedEventIndex->Utils.BigInt.Bitwise.shift_right(16->Utils.BigInt.fromInt)
//   let logIndexMask = 65535->Utils.BigInt.fromInt
//   let logIndex = packedEventIndex->Utils.BigInt.Bitwise.logand(logIndexMask)
//   {
//     blockNumber: blockNumber->Utils.BigInt.toString->Belt.Int.fromString->Belt.Option.getUnsafe,
//     logIndex: logIndex->Utils.BigInt.toString->Belt.Int.fromString->Belt.Option.getUnsafe,
//   }
// }

// //takes an eventIndex record and returnts a packed event index
// //used in TS tests
// @live
// let packEventIndexFromRecord = (eventIndex: eventIndex) => {
//   packEventIndex(~blockNumber=eventIndex.blockNumber, ~logIndex=eventIndex.logIndex)
// }

//Returns unique string id for an event using its chain id combined with event id
//Used in IO for the key in the in mem rawEvents table
let getEventIdKeyString = (~chainId: int, ~eventId: string) => {
  let chainIdStr = chainId->Belt.Int.toString
  let key = chainIdStr ++ "_" ++ eventId

  key
}
