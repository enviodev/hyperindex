let newGravatar1: Types.newGravatarEvent = {
  id: "1",
  owner: "0x123",
  displayName: "gravatar1",
  imageUrl: "https://gravatar1.com",
}

let newGravatar2: Types.newGravatarEvent = {
  id: "2",
  owner: "0x456",
  displayName: "gravatar2",
  imageUrl: "https://gravatar2.com",
}

let newGravatar3: Types.newGravatarEvent = {
  id: "3",
  owner: "0x789",
  displayName: "gravatar3",
  imageUrl: "https://gravatar3.com",
}

let updatedGravatar1: Types.updatedGravatarEvent = {
  id: "1",
  owner: "0x123",
  displayName: "update1",
  imageUrl: "https://gravatar1.com",
}

let updatedGravatar2: Types.updatedGravatarEvent = {
  id: "2",
  owner: "0x456",
  displayName: "update2",
  imageUrl: "https://gravatar2.com",
}

let updatedGravatar3: Types.updatedGravatarEvent = {
  id: "3",
  owner: "0x789",
  displayName: "update3",
  imageUrl: "https://gravatar3.com",
}

let newGravatarEventLog1: Types.eventLog<Types.newGravatarEvent> = {
  params: newGravatar1,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let newGravatarEventLog2: Types.eventLog<Types.newGravatarEvent> = {
  params: newGravatar2,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let newGravatarEventLog3: Types.eventLog<Types.newGravatarEvent> = {
  params: newGravatar3,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let updatedGravatarEventLog1: Types.eventLog<Types.updatedGravatarEvent> = {
  params: updatedGravatar1,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let updatedGravatarEventLog2: Types.eventLog<Types.updatedGravatarEvent> = {
  params: updatedGravatar2,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let updatedGravatarEventLog3: Types.eventLog<Types.updatedGravatarEvent> = {
  params: updatedGravatar3,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let eventBatch: array<Types.event> = [
  NewGravatar(newGravatarEventLog1),
  NewGravatar(newGravatarEventLog2),
  NewGravatar(newGravatarEventLog3),
  UpdatedGravatar(updatedGravatarEventLog1),
  UpdatedGravatar(updatedGravatarEventLog2),
  UpdatedGravatar(updatedGravatarEventLog3),
]
