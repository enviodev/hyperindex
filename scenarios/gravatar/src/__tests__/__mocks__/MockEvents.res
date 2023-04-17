let newGravatar1: Types.GravatarContract.newGravatarEvent = {
  id: 1001->Ethers.BigInt.fromInt,
  owner: "0x1230000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "gravatar1",
  imageUrl: "https://gravatar1.com",
}

let newGravatar2: Types.GravatarContract.newGravatarEvent = {
  id: 1002->Ethers.BigInt.fromInt,
  owner: "0x4560000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "gravatar2",
  imageUrl: "https://gravatar2.com",
}

let newGravatar3: Types.GravatarContract.newGravatarEvent = {
  id: 1003->Ethers.BigInt.fromInt,
  owner: "0x7890000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "gravatar3",
  imageUrl: "https://gravatar3.com",
}

let updatedGravatar1: Types.GravatarContract.updatedGravatarEvent = {
  id: 1001->Ethers.BigInt.fromInt,
  owner: "0x1230000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "update1",
  imageUrl: "https://gravatar1.com",
}

let updatedGravatar2: Types.GravatarContract.updatedGravatarEvent = {
  id: 1002->Ethers.BigInt.fromInt,
  owner: "0x4560000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "update2",
  imageUrl: "https://gravatar2.com",
}

let updatedGravatar3: Types.GravatarContract.updatedGravatarEvent = {
  id: 1003->Ethers.BigInt.fromInt,
  owner: "0x7890000000000000000000000000000000000000"->Ethers.getAddressFromStringUnsafe,
  displayName: "update3",
  imageUrl: "https://gravatar3.com",
}

let newGravatarEventLog1: Types.eventLog<Types.GravatarContract.newGravatarEvent> = {
  params: newGravatar1,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  // TODO: this should be an address type
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let newGravatarEventLog2: Types.eventLog<Types.GravatarContract.newGravatarEvent> = {
  params: newGravatar2,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let newGravatarEventLog3: Types.eventLog<Types.GravatarContract.newGravatarEvent> = {
  params: newGravatar3,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let updatedGravatarEventLog1: Types.eventLog<Types.GravatarContract.updatedGravatarEvent> = {
  params: updatedGravatar1,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let updatedGravatarEventLog2: Types.eventLog<Types.GravatarContract.updatedGravatarEvent> = {
  params: updatedGravatar2,
  blockNumber: 1,
  blockTimestamp: 1,
  blockHash: "deasne",
  srcAddress: "0xabc",
  transactionHash: "0xaaa",
  transactionIndex: 1,
  logIndex: 1,
}

let updatedGravatarEventLog3: Types.eventLog<Types.GravatarContract.updatedGravatarEvent> = {
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
  GravatarContract_NewGravatar(newGravatarEventLog1),
  GravatarContract_NewGravatar(newGravatarEventLog2),
  GravatarContract_NewGravatar(newGravatarEventLog3),
  GravatarContract_UpdatedGravatar(updatedGravatarEventLog1),
  GravatarContract_UpdatedGravatar(updatedGravatarEventLog2),
  GravatarContract_UpdatedGravatar(updatedGravatarEventLog3),
]
