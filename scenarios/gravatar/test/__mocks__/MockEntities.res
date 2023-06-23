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

let mockEventData1: Types.eventData = {chainId: 123, eventId: "456"}
let mockEventData2: Types.eventData = {chainId: 123, eventId: "789"}
let gravatarSerialized1 = gravatarEntity1->Types.gravatarEntity_encode
let gravatarSerialized2 = gravatarEntity2->Types.gravatarEntity_encode
let mockInMemRow1: Types.inMemoryStoreRow<Js.Json.t> = {
  entity: gravatarSerialized1,
  eventData: mockEventData1,
  dbOp: Types.Set,
}

let mockInMemRow2: Types.inMemoryStoreRow<Js.Json.t> = {
  entity: gravatarSerialized2,
  eventData: mockEventData2,
  dbOp: Types.Set,
}
