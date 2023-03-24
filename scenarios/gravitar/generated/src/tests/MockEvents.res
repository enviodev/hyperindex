let newGravatar1: EventTypes.newGravatarEvent = {
  id: "1",
  owner: "0x123",
  displayName: "gravatar1",
  imageUrl: "https://gravatar1.com",
}

let newGravatar2: EventTypes.newGravatarEvent = {
  id: "2",
  owner: "0x456",
  displayName: "gravatar2",
  imageUrl: "https://gravatar2.com",
}

let newGravatar3: EventTypes.newGravatarEvent = {
  id: "3",
  owner: "0x789",
  displayName: "gravatar3",
  imageUrl: "https://gravatar3.com",
}

let updateGravatar1: EventTypes.updateGravatarEvent = {
  id: "1",
  owner: "0x123",
  displayName: "update1",
  imageUrl: "https://gravatar1.com",
}

let updateGravatar2: EventTypes.updateGravatarEvent = {
  id: "2",
  owner: "0x456",
  displayName: "update2",
  imageUrl: "https://gravatar2.com",
}

let updateGravatar3: EventTypes.updateGravatarEvent = {
  id: "3",
  owner: "0x789",
  displayName: "update3",
  imageUrl: "https://gravatar3.com",
}

let newGravatarEventLog1: EventTypes.eventLog<EventTypes.newGravatarEvent> = {
  params: newGravatar1,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let newGravatarEventLog2: EventTypes.eventLog<EventTypes.newGravatarEvent> = {
  params: newGravatar2,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let newGravatarEventLog3: EventTypes.eventLog<EventTypes.newGravatarEvent> = {
  params: newGravatar3,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let updateGravatarEventLog1: EventTypes.eventLog<EventTypes.updateGravatarEvent> = {
  params: updateGravatar1,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let updateGravatarEventLog2: EventTypes.eventLog<EventTypes.updateGravatarEvent> = {
  params: updateGravatar2,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let updateGravatarEventLog3: EventTypes.eventLog<EventTypes.updateGravatarEvent> = {
  params: updateGravatar3,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let eventBatch: array<EventTypes.event> = [
  NewGravatar(newGravatarEventLog1),
  NewGravatar(newGravatarEventLog2),
  NewGravatar(newGravatarEventLog3),
  UpdateGravatar(updateGravatarEventLog1),
  UpdateGravatar(updateGravatarEventLog2),
  UpdateGravatar(updateGravatarEventLog3),
]
