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
    JsError.throwWithMessage("Block handlers are not supported for ordered multichain mode.")
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
  let blockNumber = blockNumber->BigInt_.fromInt
  let logIndex = logIndex->BigInt_.fromInt
  let blockNumber = BigInt_.Bitwise.shift_left(blockNumber, 16->BigInt_.fromInt)

  blockNumber->BigInt_.Bitwise.logor(logIndex)
}

// //Currently not used but keeping in utils
// //using @live flag for dead code analyser
// @live
// let packMultiChainEventIndex = (~timestamp, ~chainId, ~blockNumber, ~logIndex) => {
//   let timestamp = timestamp->BigInt_.fromInt
//   let chainId = chainId->BigInt_.fromInt
//   let blockNumber = blockNumber->BigInt_.fromInt
//   let logIndex = logIndex->BigInt_.fromInt

//   let timestamp = BigInt_.Bitwise.shift_left(timestamp, 48->BigInt_.fromInt)
//   let chainId = BigInt_.Bitwise.shift_left(chainId, 16->BigInt_.fromInt)
//   let blockNumber = BigInt_.Bitwise.shift_left(blockNumber, 16->BigInt_.fromInt)

//   timestamp
//   ->BigInt_.Bitwise.logor(chainId)
//   ->BigInt_.Bitwise.logor(blockNumber)
//   ->BigInt_.Bitwise.logor(logIndex)
// }

// //Currently not used but keeping in utils
// //using @live flag for dead code analyser
// @live
// let unpackEventIndex = (packedEventIndex: bigint) => {
//   let blockNumber = packedEventIndex->BigInt_.Bitwise.shift_right(16->BigInt_.fromInt)
//   let logIndexMask = 65535->BigInt_.fromInt
//   let logIndex = packedEventIndex->BigInt_.Bitwise.logand(logIndexMask)
//   {
//     blockNumber: blockNumber->BigInt_.toString->Belt.Int.fromString->Belt.Option.getUnsafe,
//     logIndex: logIndex->BigInt_.toString->Belt.Int.fromString->Belt.Option.getUnsafe,
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
