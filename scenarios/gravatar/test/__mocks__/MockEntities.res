let gravatarEntity1: Types.gravatarEntity = {
  id: "1001",
  owner: "0x123",
  displayName: "gravatar1",
  imageUrl: "https://gravatar1.com",
  updatesCount: 0,
}

let gravatarEntity2: Types.gravatarEntity = {
  id: "1002",
  owner: "0x678",
  displayName: "gravatar2",
  imageUrl: "https://gravatar2.com",
  updatesCount: 1,
}

let mockEventData1: Types.eventData = {chainId: 123, eventId: 456->Ethers.BigInt.fromInt}
let mockEventData2: Types.eventData = {chainId: 123, eventId: 789->Ethers.BigInt.fromInt}
let gravatarSerialized1 = gravatarEntity1->Types.serializeGravatarEntity
let gravatarSerialized2 = gravatarEntity2->Types.serializeGravatarEntity
let mockInMemRow1: Types.inMemoryStoreRow<Types.gravatarEntitySerialized> = {
  entity: gravatarSerialized1,
  eventData: mockEventData1,
  crud: Types.Create,
}

let mockInMemRow2: Types.inMemoryStoreRow<Types.gravatarEntitySerialized> = {
  entity: gravatarSerialized2,
  eventData: mockEventData2,
  crud: Types.Create,
}
