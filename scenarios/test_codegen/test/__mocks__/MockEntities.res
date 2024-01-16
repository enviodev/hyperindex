let gravatarEntity1: Types.gravatarEntity = {
  id: "1001",
  owner_id: "0x123",
  displayName: "gravatar1",
  imageUrl: "https://gravatar1.com",
  updatesCount: Ethers.BigInt.fromInt(0),
  size: #LARGE,
}

let gravatarEntity2: Types.gravatarEntity = {
  id: "1002",
  owner_id: "0x678",
  displayName: "gravatar2",
  imageUrl: "https://gravatar2.com",
  updatesCount: Ethers.BigInt.fromInt(1),
  size: #MEDIUM,
}

let logIndexIncrement = ref(0)

let makeDefaultSet = (~chainId=0, ~blockNumber=0, ~logIndex=?, entity: 'a): Types.inMemoryStoreRow<
  'a,
> => {
  // Tests break if the 'eventIdentifier' isn't unique in the event history table. So incrementing the log index helps ensure it is unique.
  let logIndex = switch logIndex {
  | None =>
    logIndexIncrement := logIndexIncrement.contents + 1
    logIndexIncrement.contents
  | Some(logIndex) => logIndex
  }

  Js.log2("log index", logIndex)

  {
    current: Set(
      entity,
      {
        chainId,
        blockNumber,
        logIndex,
      },
    ),
    history: [],
  }
}

let gravatarSerialized1 = gravatarEntity1->Types.gravatarEntity_encode
let gravatarSerialized2 = gravatarEntity2->Types.gravatarEntity_encode

let mockInMemRow1: Types.inMemoryStoreRow<Js.Json.t> = makeDefaultSet(gravatarSerialized1)

let mockInMemRow2: Types.inMemoryStoreRow<Js.Json.t> = makeDefaultSet(gravatarSerialized1)
