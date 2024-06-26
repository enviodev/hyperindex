type multiChainEventIndex = {
  timestamp: int,
  chainId: int,
  blockNumber: int,
  logIndex: int,
}

//Comparator used when ordering multichain events
let getEventComparator = (multiChainEventIndex: multiChainEventIndex) => {
  let {timestamp, chainId, blockNumber, logIndex} = multiChainEventIndex
  (timestamp, chainId, blockNumber, logIndex)
}

let getEventComparatorFromQueueItem = (
  {chain, timestamp, blockNumber, logIndex}: Types.eventBatchQueueItem,
) => {
  let chainId = chain->ChainMap.Chain.toChainId
  (timestamp, chainId, blockNumber, logIndex)
}

//Function used to determine if one event is earlier than another
let isEarlierEvent = (event1: multiChainEventIndex, event2: multiChainEventIndex) => {
  event1->getEventComparator < event2->getEventComparator
}

type eventIndex = {
  blockNumber: int,
  logIndex: int,
}

// takes blockNumber, logIndex and packs them into a number with
//32 bits, 16 bits and 16 bits respectively
let packEventIndex = (~blockNumber, ~logIndex) => {
  let blockNumber = blockNumber->BigInt.fromInt
  let logIndex = logIndex->BigInt.fromInt
  let blockNumber = BigInt.Bitwise.shift_left(blockNumber, 16->BigInt.fromInt)

  blockNumber->BigInt.Bitwise.logor(logIndex)
}

//Currently not used but keeping in utils
//using @live flag for dead code analyser
@live
let packMultiChainEventIndex = (~timestamp, ~chainId, ~blockNumber, ~logIndex) => {
  let timestamp = timestamp->BigInt.fromInt
  let chainId = chainId->BigInt.fromInt
  let blockNumber = blockNumber->BigInt.fromInt
  let logIndex = logIndex->BigInt.fromInt

  let timestamp = BigInt.Bitwise.shift_left(timestamp, 48->BigInt.fromInt)
  let chainId = BigInt.Bitwise.shift_left(chainId, 16->BigInt.fromInt)
  let blockNumber = BigInt.Bitwise.shift_left(blockNumber, 16->BigInt.fromInt)

  timestamp
  ->BigInt.Bitwise.logor(chainId)
  ->BigInt.Bitwise.logor(blockNumber)
  ->BigInt.Bitwise.logor(logIndex)
}

//Currently not used but keeping in utils
//using @live flag for dead code analyser
@live
let unpackEventIndex = (packedEventIndex: bigint) => {
  let blockNumber = packedEventIndex->BigInt.Bitwise.shift_right(16->BigInt.fromInt)
  let logIndexMask = 65535->BigInt.fromInt
  let logIndex = packedEventIndex->BigInt.Bitwise.logand(logIndexMask)
  {
    blockNumber: blockNumber->BigInt.toString->Belt.Int.fromString->Belt.Option.getUnsafe,
    logIndex: logIndex->BigInt.toString->Belt.Int.fromString->Belt.Option.getUnsafe,
  }
}

//takes an eventIndex record and returnts a packed event index
//used in TS tests
@live
let packEventIndexFromRecord = (eventIndex: eventIndex) => {
  packEventIndex(~blockNumber=eventIndex.blockNumber, ~logIndex=eventIndex.logIndex)
}

//Returns unique string id for an event using its chain id combined with event id
//Used in IO for the key in the in mem rawEvents table
let getEventIdKeyString = (~chainId: int, ~eventId: string) => {
  let chainIdStr = chainId->Belt.Int.toString
  let key = chainIdStr ++ "_" ++ eventId

  key
}

let getContractAddressKeyString = (~chainId: int, ~contractAddress: Ethers.ethAddress) => {
  let chainIdStr = chainId->Belt.Int.toString
  let key = chainIdStr ++ "_" ++ contractAddress->Ethers.ethAddressToString

  key
}
// TODO: utilities like this should be moved to the particular chain worker.
let waitForNextBlock = async (provider: Ethers.JsonRpcProvider.t) => {
  // TODO: think how to handle the case where this fails? The way this is written now there is no `_reject`, nor any timeout
  //       (maybe for each chain there should be a max wait time, 2 minutes for ethereum, 30 seconds for arbitrum etc, and then it retries?)
  await Promise.make((resolve, _reject) => {
    provider->Ethers.JsonRpcProvider.onBlock(blockNumber => {
      provider->Ethers.JsonRpcProvider.removeOnBlockEventListener
      resolve(. blockNumber)
    })
  })
}
