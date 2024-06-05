open Belt

let newGravatar1: Types.GravatarContract.NewGravatarEvent.eventArgs = {
  id: 1001->Ethers.BigInt.fromInt,
  owner: "0x1230000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "gravatar1",
  imageUrl: "https://gravatar1.com",
}

let newGravatar2: Types.GravatarContract.NewGravatarEvent.eventArgs = {
  id: 1002->Ethers.BigInt.fromInt,
  owner: "0x4560000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "gravatar2",
  imageUrl: "https://gravatar2.com",
}

let newGravatar3: Types.GravatarContract.NewGravatarEvent.eventArgs = {
  id: 1003->Ethers.BigInt.fromInt,
  owner: "0x7890000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "gravatar3",
  imageUrl: "https://gravatar3.com",
}

let newGravatar4_deleted: Types.GravatarContract.NewGravatarEvent.eventArgs = {
  id: 1004->Ethers.BigInt.fromInt,
  owner: "0x9990000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "gravatar4_deleted",
  imageUrl: "https://gravatar4.com",
}

let setGravatar1: Types.GravatarContract.UpdatedGravatarEvent.eventArgs = {
  id: 1001->Ethers.BigInt.fromInt,
  owner: "0x1230000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "update1",
  imageUrl: "https://gravatar1.com",
}

let setGravatar2: Types.GravatarContract.UpdatedGravatarEvent.eventArgs = {
  id: 1002->Ethers.BigInt.fromInt,
  owner: "0x4560000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "update2",
  imageUrl: "https://gravatar2.com",
}

let setGravatar3: Types.GravatarContract.UpdatedGravatarEvent.eventArgs = {
  id: 1003->Ethers.BigInt.fromInt,
  owner: "0x7890000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "update3",
  imageUrl: "https://gravatar3.com",
}
let setGravatar4: Types.GravatarContract.UpdatedGravatarEvent.eventArgs = {
  id: 1004->Ethers.BigInt.fromInt,
  owner: "0x9990000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "update4",
  imageUrl: "https://gravatar4.com",
}

let newGravatarEventLog1: Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs> = {
  params: newGravatar1,
  blockNumber: 1,
  chainId: 54321,
  blockTimestamp: 1,
  blockHash: "deasne",
  // TODO: this should be an address type
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  transactionHash: "0xaaa",
  transactionIndex: 1,
  txOrigin: None,
  txTo: None,
  logIndex: 11,
}

let newGravatarEventLog2: Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs> = {
  params: newGravatar2,
  blockNumber: 1,
  chainId: 54321,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  transactionHash: "0xaaa",
  transactionIndex: 1,
  txOrigin: None,
  txTo: None,
  logIndex: 12,
}

let newGravatarEventLog3: Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs> = {
  params: newGravatar3,
  blockNumber: 1,
  chainId: 54321,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  transactionHash: "0xaaa",
  transactionIndex: 1,
  txOrigin: None,
  txTo: None,
  logIndex: 13,
}

let newGravatarEventLog4: Types.eventLog<Types.GravatarContract.NewGravatarEvent.eventArgs> = {
  params: newGravatar4_deleted,
  blockNumber: 1,
  chainId: 54321,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  transactionHash: "0xaaa",
  transactionIndex: 1,
  txOrigin: None,
  txTo: None,
  logIndex: 13,
}

let setGravatarEventLog1: Types.eventLog<Types.GravatarContract.UpdatedGravatarEvent.eventArgs> = {
  params: setGravatar1,
  blockNumber: 1,
  chainId: 54321,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  transactionHash: "0xaaa",
  transactionIndex: 1,
  txOrigin: None,
  txTo: None,
  logIndex: 14,
}

let setGravatarEventLog2: Types.eventLog<Types.GravatarContract.UpdatedGravatarEvent.eventArgs> = {
  params: setGravatar2,
  blockNumber: 1,
  chainId: 54321,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  transactionHash: "0xaaa",
  transactionIndex: 1,
  txOrigin: None,
  txTo: None,
  logIndex: 15,
}

let setGravatarEventLog3: Types.eventLog<Types.GravatarContract.UpdatedGravatarEvent.eventArgs> = {
  params: setGravatar3,
  blockNumber: 1,
  chainId: 54321,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  transactionHash: "0xaaa",
  transactionIndex: 1,
  txOrigin: None,
  txTo: None,
  logIndex: 16,
}
let setGravatarEventLog4: Types.eventLog<Types.GravatarContract.UpdatedGravatarEvent.eventArgs> = {
  params: setGravatar4,
  blockNumber: 1,
  chainId: 54321,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc0000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  transactionHash: "0xaaa",
  transactionIndex: 1,
  txOrigin: None,
  txTo: None,
  logIndex: 17,
}

let eventBatch: array<Types.event> = [
  GravatarContract_NewGravatar(newGravatarEventLog1),
  GravatarContract_NewGravatar(newGravatarEventLog2),
  GravatarContract_NewGravatar(newGravatarEventLog3),
  GravatarContract_NewGravatar(newGravatarEventLog4),
  GravatarContract_UpdatedGravatar(setGravatarEventLog1),
  GravatarContract_UpdatedGravatar(setGravatarEventLog2),
  GravatarContract_UpdatedGravatar(setGravatarEventLog3),
  GravatarContract_UpdatedGravatar(setGravatarEventLog4),
]

let eventBatchChain = ChainMap.Chain.Chain_1337

let eventBatchItems = eventBatch->Belt.Array.map((e): Types.eventBatchQueueItem => {
  switch e {
  | GravatarContract_NewGravatar(el) => {
      timestamp: el.blockTimestamp,
      chain: eventBatchChain,
      blockNumber: el.blockNumber,
      logIndex: el.logIndex,
      event: e,
    }
  | GravatarContract_UpdatedGravatar(el) => {
      timestamp: el.blockTimestamp,
      chain: eventBatchChain,
      blockNumber: el.blockNumber,
      logIndex: el.logIndex,
      event: e,
    }
  | _ => Js.Exn.raiseError("I couldn't figure out how to make this method polymorphic")
  }
})

let inMemoryStoreMock = InMemoryStore.make()
let makeContext = event =>
  Context.make(
    ~logger=Logging.logger,
    ~chain=Chain_1,
    ~asyncGetters=EventProcessing.asyncGetters,
    ~inMemoryStore=inMemoryStoreMock,
    ~event,
  )

let mockNewGravatarContext = makeContext(newGravatarEventLog1)
let mockUpdateGravatarContext = makeContext(setGravatarEventLog1)
let eventBatch: array<EventProcessing.eventAndContext> = Array.concat(
  [
    Types.GravatarContract_NewGravatar(newGravatarEventLog1),
    GravatarContract_NewGravatar(newGravatarEventLog2),
    GravatarContract_NewGravatar(newGravatarEventLog3),
    GravatarContract_NewGravatar(newGravatarEventLog4),
  ]->Array.map(event => {EventProcessing.context: mockNewGravatarContext, event}),
  [
    Types.GravatarContract_UpdatedGravatar(setGravatarEventLog1),
    GravatarContract_UpdatedGravatar(setGravatarEventLog2),
    GravatarContract_UpdatedGravatar(setGravatarEventLog3),
    GravatarContract_UpdatedGravatar(setGravatarEventLog4),
  ]->Array.map(event => {EventProcessing.context: mockUpdateGravatarContext, event}),
)
