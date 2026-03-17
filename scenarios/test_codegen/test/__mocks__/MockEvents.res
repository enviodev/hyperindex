let newGravatar1: Indexer.Gravatar.NewGravatar.eventArgs = {
  id: 1001->BigInt.fromInt,
  owner: "0x1230000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  displayName: "gravatar1",
  imageUrl: "https://gravatar1.com",
}

let newGravatar2: Indexer.Gravatar.NewGravatar.eventArgs = {
  id: 1002->BigInt.fromInt,
  owner: "0x4560000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  displayName: "gravatar2",
  imageUrl: "https://gravatar2.com",
}

let newGravatar3: Indexer.Gravatar.NewGravatar.eventArgs = {
  id: 1003->BigInt.fromInt,
  owner: "0x7890000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  displayName: "gravatar3",
  imageUrl: "https://gravatar3.com",
}

let newGravatar4_deleted: Indexer.Gravatar.NewGravatar.eventArgs = {
  id: 1004->BigInt.fromInt,
  owner: "0x9990000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  displayName: "gravatar4_deleted",
  imageUrl: "https://gravatar4.com",
}

let setGravatar1: Indexer.Gravatar.UpdatedGravatar.eventArgs = {
  id: 1001->BigInt.fromInt,
  owner: "0x1230000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  displayName: "update1",
  imageUrl: "https://gravatar1.com",
}

let setGravatar2: Indexer.Gravatar.UpdatedGravatar.eventArgs = {
  id: 1002->BigInt.fromInt,
  owner: "0x4560000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  displayName: "update2",
  imageUrl: "https://gravatar2.com",
}

let setGravatar3: Indexer.Gravatar.UpdatedGravatar.eventArgs = {
  id: 1003->BigInt.fromInt,
  owner: "0x7890000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  displayName: "update3",
  imageUrl: "https://gravatar3.com",
}
let setGravatar4: Indexer.Gravatar.UpdatedGravatar.eventArgs = {
  id: 1004->BigInt.fromInt,
  owner: "0x9990000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  displayName: "update4",
  imageUrl: "https://gravatar4.com",
}

let block1: Indexer.Block.t = {
  number: 1,
  timestamp: 1,
  hash: "deasne",
}

let tx1: Indexer.Transaction.t = {
  hash: "0xaaa",
  transactionIndex: 1,
}

let newGravatarLog1: Indexer.eventLog<Indexer.Gravatar.NewGravatar.eventArgs> = {
  params: newGravatar1,
  chainId: 54321,
  // TODO: this should be an address type
  srcAddress: "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  logIndex: 11,
  transaction: tx1,
  block: block1,
}

let newGravatarLog2: Indexer.eventLog<Indexer.Gravatar.NewGravatar.eventArgs> = {
  params: newGravatar2,
  block: block1,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  transaction: tx1,
  logIndex: 12,
}

let newGravatarLog3: Indexer.eventLog<Indexer.Gravatar.NewGravatar.eventArgs> = {
  params: newGravatar3,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  logIndex: 13,
  transaction: tx1,
  block: block1,
}

let newGravatarLog4: Indexer.eventLog<Indexer.Gravatar.NewGravatar.eventArgs> = {
  params: newGravatar4_deleted,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  logIndex: 13,
  transaction: tx1,
  block: block1,
}

let setGravatarLog1: Indexer.eventLog<Indexer.Gravatar.UpdatedGravatar.eventArgs> = {
  params: setGravatar1,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  logIndex: 14,
  transaction: tx1,
  block: block1,
}

let setGravatarLog2: Indexer.eventLog<Indexer.Gravatar.UpdatedGravatar.eventArgs> = {
  params: setGravatar2,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  logIndex: 15,
  transaction: tx1,
  block: block1,
}

let setGravatarLog3: Indexer.eventLog<Indexer.Gravatar.UpdatedGravatar.eventArgs> = {
  params: setGravatar3,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  logIndex: 16,
  transaction: tx1,
  block: block1,
}
let setGravatarLog4: Indexer.eventLog<Indexer.Gravatar.UpdatedGravatar.eventArgs> = {
  params: setGravatar4,
  chainId: 54321,
  srcAddress: "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  logIndex: 17,
  transaction: tx1,
  block: block1,
}

let newGravatarEventToBatchItem = (
  event: Indexer.eventLog<Indexer.Gravatar.NewGravatar.eventArgs>,
): Internal.item => Internal.Event({
  timestamp: event.block.timestamp,
  chain: MockConfig.chain1337,
  blockNumber: event.block.number,
  logIndex: event.logIndex,
  eventConfig: (Indexer.Gravatar.NewGravatar.register() :> Internal.eventConfig),
  event: event->Internal.fromGenericEvent,
})

let updatedGravatarEventToBatchItem = (
  event: Indexer.eventLog<Indexer.Gravatar.UpdatedGravatar.eventArgs>,
): Internal.item => Internal.Event({
  timestamp: event.block.timestamp,
  chain: MockConfig.chain1337,
  blockNumber: event.block.number,
  logIndex: event.logIndex,
  eventConfig: (Indexer.Gravatar.UpdatedGravatar.register() :> Internal.eventConfig),
  event: event->Internal.fromGenericEvent,
})

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
