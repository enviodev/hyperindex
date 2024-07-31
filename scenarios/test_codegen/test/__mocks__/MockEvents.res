let newGravatar1: Types.Gravatar.NewGravatar.eventArgs = {
  id: 1001->BigInt.fromInt,
  owner: "0x1230000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "gravatar1",
  imageUrl: "https://gravatar1.com",
}

let newGravatar2: Types.Gravatar.NewGravatar.eventArgs = {
  id: 1002->BigInt.fromInt,
  owner: "0x4560000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "gravatar2",
  imageUrl: "https://gravatar2.com",
}

let newGravatar3: Types.Gravatar.NewGravatar.eventArgs = {
  id: 1003->BigInt.fromInt,
  owner: "0x7890000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "gravatar3",
  imageUrl: "https://gravatar3.com",
}

let newGravatar4_deleted: Types.Gravatar.NewGravatar.eventArgs = {
  id: 1004->BigInt.fromInt,
  owner: "0x9990000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "gravatar4_deleted",
  imageUrl: "https://gravatar4.com",
}

let setGravatar1: Types.Gravatar.UpdatedGravatar.eventArgs = {
  id: 1001->BigInt.fromInt,
  owner: "0x1230000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "update1",
  imageUrl: "https://gravatar1.com",
}

let setGravatar2: Types.Gravatar.UpdatedGravatar.eventArgs = {
  id: 1002->BigInt.fromInt,
  owner: "0x4560000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "update2",
  imageUrl: "https://gravatar2.com",
}

let setGravatar3: Types.Gravatar.UpdatedGravatar.eventArgs = {
  id: 1003->BigInt.fromInt,
  owner: "0x7890000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "update3",
  imageUrl: "https://gravatar3.com",
}
let setGravatar4: Types.Gravatar.UpdatedGravatar.eventArgs = {
  id: 1004->BigInt.fromInt,
  owner: "0x9990000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "update4",
  imageUrl: "https://gravatar4.com",
}

let block1: Types.Block.t = {
  number: 1,
  timestamp: 1,
  hash: "deasne",
}

let tx1: Types.Transaction.t = {
  hash: "0xaaa",
  transactionIndex: 1,
}

let newGravatarLog1: Types.eventLog<Types.Gravatar.NewGravatar.eventArgs> = {
  params: newGravatar1,
  chainId: 54321,
  // TODO: this should be an address type
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  logIndex: 11,
  transaction: tx1,
  block: block1,
}

let newGravatarLog2: Types.eventLog<Types.Gravatar.NewGravatar.eventArgs> = {
  params: newGravatar2,
  block: block1,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  transaction: tx1,
  logIndex: 12,
}

let newGravatarLog3: Types.eventLog<Types.Gravatar.NewGravatar.eventArgs> = {
  params: newGravatar3,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  logIndex: 13,
  transaction: tx1,
  block: block1,
}

let newGravatarLog4: Types.eventLog<Types.Gravatar.NewGravatar.eventArgs> = {
  params: newGravatar4_deleted,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  logIndex: 13,
  transaction: tx1,
  block: block1,
}

let setGravatarLog1: Types.eventLog<Types.Gravatar.UpdatedGravatar.eventArgs> = {
  params: setGravatar1,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  logIndex: 14,
  transaction: tx1,
  block: block1,
}

let setGravatarLog2: Types.eventLog<Types.Gravatar.UpdatedGravatar.eventArgs> = {
  params: setGravatar2,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  logIndex: 15,
  transaction: tx1,
  block: block1,
}

let setGravatarLog3: Types.eventLog<Types.Gravatar.UpdatedGravatar.eventArgs> = {
  params: setGravatar3,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  logIndex: 16,
  transaction: tx1,
  block: block1,
}
let setGravatarLog4: Types.eventLog<Types.Gravatar.UpdatedGravatar.eventArgs> = {
  params: setGravatar4,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  logIndex: 17,
  transaction: tx1,
  block: block1,
}

let newGravatarEventToBatchItem = (event: Types.eventLog<Types.Gravatar.NewGravatar.eventArgs>): Types.eventBatchQueueItem => {
  {
    timestamp: event.block.timestamp,
    chain: MockConfig.chain1337,
    blockNumber: event.block.number,
    logIndex: event.logIndex,
    eventMod: module(Types.Gravatar.NewGravatar)->Types.eventModToInternal,
    event: event->Types.eventToInternal,
  }
}


let updatedGravatarEventToBatchItem = (event: Types.eventLog<Types.Gravatar.UpdatedGravatar.eventArgs>): Types.eventBatchQueueItem => {
  {
    timestamp: event.block.timestamp,
    chain: MockConfig.chain1337,
    blockNumber: event.block.number,
    logIndex: event.logIndex,
    eventMod: module(Types.Gravatar.UpdatedGravatar)->Types.eventModToInternal,
    event: event->Types.eventToInternal,
  }
}

let eventBatchItems = [
  newGravatarLog1->newGravatarEventToBatchItem,
  newGravatarLog2->newGravatarEventToBatchItem,
  newGravatarLog3->newGravatarEventToBatchItem,
  newGravatarLog4->newGravatarEventToBatchItem,
  setGravatarLog1->updatedGravatarEventToBatchItem,
  setGravatarLog2->updatedGravatarEventToBatchItem,
  setGravatarLog3->updatedGravatarEventToBatchItem,
  setGravatarLog4->updatedGravatarEventToBatchItem,
]
