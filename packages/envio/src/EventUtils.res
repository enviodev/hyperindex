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
  let blockNumber = blockNumber->BigInt.fromInt
  let logIndex = logIndex->BigInt.fromInt
  let blockNumber = BigInt.lsl(blockNumber, 16->BigInt.fromInt)

  blockNumber->BigInt.lor(logIndex)
}

// //Currently not used but keeping in utils
// //using @live flag for dead code analyser
// @live
// let packMultiChainEventIndex = (~timestamp, ~chainId, ~blockNumber, ~logIndex) => {
//   let timestamp = timestamp->BigInt.fromInt
//   let chainId = chainId->BigInt.fromInt
//   let blockNumber = blockNumber->BigInt.fromInt
//   let logIndex = logIndex->BigInt.fromInt

//   let timestamp = BigInt.lsl(timestamp, 48->BigInt.fromInt)
//   let chainId = BigInt.lsl(chainId, 16->BigInt.fromInt)
//   let blockNumber = BigInt.lsl(blockNumber, 16->BigInt.fromInt)

//   timestamp
//   ->BigInt.lor(chainId)
//   ->BigInt.lor(blockNumber)
//   ->BigInt.lor(logIndex)
// }

// //Currently not used but keeping in utils
// //using @live flag for dead code analyser
// @live
// let unpackEventIndex = (packedEventIndex: bigint) => {
//   let blockNumber = packedEventIndex->BigInt.asr(16->BigInt.fromInt)
//   let logIndexMask = 65535->BigInt.fromInt
//   let logIndex = packedEventIndex->BigInt.land(logIndexMask)
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

//Returns unique string id for an event using its chain id combined with event id
//Used in IO for the key in the in mem rawEvents table
let getEventIdKeyString = (~chainId: int, ~eventId: string) => {
  let chainIdStr = chainId->Belt.Int.toString
  let key = chainIdStr ++ "_" ++ eventId

  key
}
