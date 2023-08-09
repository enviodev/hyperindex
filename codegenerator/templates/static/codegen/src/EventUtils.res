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

//Function used to determine if one event is earlier than another
let isEarlierEvent = (event1: multiChainEventIndex, event2: multiChainEventIndex) => {
  event1->getEventComparator < event2->getEventComparator
}

type eventIndex = {
  blockNumber: int,
  logIndex: int,
}

// takes blockNumber, logIndex and packs them into a number with
//32 bits, 8bits and 8 bits respectively
let packEventIndex = (~blockNumber, ~logIndex) => {
  let blockNumber = blockNumber->Ethers.BigInt.fromInt
  let logIndex = logIndex->Ethers.BigInt.fromInt
  let blockNumber = Ethers.BigInt.Bitwise.shift_left(blockNumber, 16->Ethers.BigInt.fromInt)

  blockNumber->Ethers.BigInt.Bitwise.logor(logIndex)
}

//Currently not used but keeping in utils
//using @live flag for dead code analyser
@live
let unpackEventIndex = (packedEventIndex: Ethers.BigInt.t) => {
  let blockNumber = packedEventIndex->Ethers.BigInt.Bitwise.shift_right(16->Ethers.BigInt.fromInt)
  let logIndexMask = 65535->Ethers.BigInt.fromInt
  let logIndex = packedEventIndex->Ethers.BigInt.Bitwise.logand(logIndexMask)
  {
    blockNumber: blockNumber->Ethers.BigInt.toString->Belt.Int.fromString->Belt.Option.getUnsafe,
    logIndex: logIndex->Ethers.BigInt.toString->Belt.Int.fromString->Belt.Option.getUnsafe,
  }
}

//takes an eventIndex record and returnts a packed event index
@live //used in TS tests
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

let waitForNextBlock = async (provider: Ethers.JsonRpcProvider.t) => {
  await Promise.make((resolve, _reject) => {
    provider->Ethers.JsonRpcProvider.onBlock(blockNumber => {
      provider->Ethers.JsonRpcProvider.removeOnBlockEventListener
      resolve(. blockNumber)
    })
  })
}
