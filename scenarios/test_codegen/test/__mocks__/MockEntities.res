let gravatarEntity0_delete: Entities.Gravatar.t = {
  id: "1000",
  owner_id: "0x123",
  displayName: "gravatar1",
  imageUrl: "https://gravatar1.com",
  updatesCount: BigInt.fromInt(0),
  size: LARGE,
}

let gravatarEntity1: Entities.Gravatar.t = {
  id: "1001",
  owner_id: "0x123",
  displayName: "gravatar1",
  imageUrl: "https://gravatar1.com",
  updatesCount: BigInt.fromInt(0),
  size: LARGE,
}

let gravatarEntity2: Entities.Gravatar.t = {
  id: "1002",
  owner_id: "0x678",
  displayName: "gravatar2",
  imageUrl: "https://gravatar2.com",
  updatesCount: BigInt.fromInt(1),
  size: MEDIUM,
}
let logIndexIncrement = ref(0)

let makeDefaultSet = (
  ~chainId=0,
  ~blockNumber=0,
  ~blockTimestamp=0,
  ~logIndex=?,
  entity: 'a,
): Types.inMemoryStoreRowEntity<'a> => {
  // Tests break if the 'eventIdentifier' isn't unique in the event history table. So incrementing the log index helps ensure it is unique.
  let logIndex = switch logIndex {
  | None =>
    logIndexIncrement := logIndexIncrement.contents + 1
    logIndexIncrement.contents
  | Some(logIndex) => logIndex
  }

  Types.Updated({
    initial: Unknown,
    latest: Set(entity)->Types.mkEntityUpdate(
      ~entityId=Utils.magic(entity)["id"],
      ~eventIdentifier={
        chainId,
        blockTimestamp,
        blockNumber,
        logIndex,
      },
    ),
    history: [],
  })
}
let gravatarSerialized1 = gravatarEntity1->S.serializeOrRaiseWith(Entities.Gravatar.schema)
let gravatarSerialized2 = gravatarEntity2->S.serializeOrRaiseWith(Entities.Gravatar.schema)

let mockInMemRow1: Types.inMemoryStoreRowEntity<Js.Json.t> = makeDefaultSet(gravatarSerialized1)

let mockInMemRow2: Types.inMemoryStoreRowEntity<Js.Json.t> = makeDefaultSet(gravatarSerialized1)
