open RescriptMocha

let getErrorKind = (res: result<unit, EventModLookup.eventError>): option<
  EventModLookup.errorKind,
> =>
  switch res {
  | Ok(_) => None
  | Error({errorKind}) => Some(errorKind)
  }

let mockChain = ChainMap.Chain.makeUnsafe(~chainId=1)
let toInternal: module(Types.Event) => module(Types.InternalEvent) = Utils.magic
let mockAddress1 = TestHelpers.Addresses.mockAddresses[0]
let mockAddress2 = TestHelpers.Addresses.mockAddresses[1]

let mockTopicCount = 1

module MakeEventMock = (
  E: {
    let sighash: string
    let name: string
    let contractName: string
    let isWildcard: bool
  },
): Types.Event => {
  let sighash = E.sighash
  let topicCount = mockTopicCount
  let name = E.name
  let contractName = E.contractName

  type eventArgs = Types.internalEventArgs
  type eventFilter
  let paramsRawEventSchema = Utils.magic("Stub for paramsRawEventSchema")
  let handlerRegister = Types.HandlerTypes.Register.make(
    ~topic0=sighash->EvmTypes.Hex.fromStringUnsafe,
    ~contractName,
    ~eventName=name,
  )
  handlerRegister->Types.HandlerTypes.Register.setLoaderHandler(
    {
      loader: Utils.magic("Stub for loader"),
      handler: Utils.magic("Stub for handler"),
    },
    ~getEventOptions=_ => Some({
      isWildcard: E.isWildcard,
      topicSelections: [
        LogSelection.makeTopicSelection(
          ~topic0=[sighash->EvmTypes.Hex.fromStringUnsafe],
        )->Utils.unwrapResultExn,
      ],
    }),
  )
  let decodeHyperFuelData = Utils.magic("Stub for decodeHyperFuelData")
  let convertHyperSyncEventArgs = Utils.magic("Stub for convertHyperSyncEventArgs")
  let getTopicSelection = Utils.magic("Stub for getTopicSelection")
}

let makeMockEventMod = (~sighash, ~name, ~contractName, ~isWildcard): module(Types.Event) => {
  module(
    MakeEventMock({
      let sighash = sighash
      let name = name
      let contractName = contractName
      let isWildcard = isWildcard
    })
  )
}

let mockEventName = "TestEvent"
let mockSighash = "0xtest"

describe("EventModLookup", () => {
  it("Succeeds on unique insertions", () => {
    let mockEventMod1 = makeMockEventMod(
      ~sighash=mockSighash,
      ~name=mockEventName,
      ~contractName="TestContract1",
      ~isWildcard=false,
    )
    let mockEventMod2 = makeMockEventMod(
      ~sighash=mockSighash,
      ~name=mockEventName,
      ~contractName="TestContract2",
      ~isWildcard=false,
    )
    let lookup = EventModLookup.empty()

    Assert.deepEqual(lookup->EventModLookup.set(mockEventMod1), Ok())
    Assert.deepEqual(lookup->EventModLookup.set(mockEventMod2), Ok())
  })

  it("Fails on duplicate insertions", () => {
    let mockEventMod = makeMockEventMod(
      ~sighash=mockSighash,
      ~name=mockEventName,
      ~contractName="TestContract",
      ~isWildcard=false,
    )
    let lookup = EventModLookup.empty()

    Assert.deepEqual(lookup->EventModLookup.set(mockEventMod), Ok())
    Assert.deepEqual(lookup->EventModLookup.set(mockEventMod)->getErrorKind, Some(Duplicate))
  })

  it("Fails on duplicate wildcard insertions", () => {
    let mockEventMod1 = makeMockEventMod(
      ~sighash=mockSighash,
      ~name=mockEventName,
      ~contractName="TestContract1",
      ~isWildcard=true,
    )
    let mockEventMod2 = makeMockEventMod(
      ~sighash=mockSighash,
      ~name=mockEventName,
      ~contractName="TestContract2",
      ~isWildcard=true,
    )
    let lookup = EventModLookup.empty()

    Assert.deepEqual(lookup->EventModLookup.set(mockEventMod1), Ok())
    Assert.deepEqual(
      lookup->EventModLookup.set(mockEventMod2)->getErrorKind,
      Some(WildcardSighashCollision),
    )
  })

  it("getByKey returns the correct eventMod ", () => {
    let mockEventMod = makeMockEventMod(
      ~sighash=mockSighash,
      ~name=mockEventName,
      ~contractName="TestContract",
      ~isWildcard=false,
    )
    let lookup = EventModLookup.empty()

    lookup
    ->EventModLookup.set(mockEventMod)
    ->EventModLookup.unwrapAddEventResponse(~chain=mockChain)

    Assert.deepEqual(
      lookup->EventModLookup.getByKey(
        ~sighash=mockSighash,
        ~topicCount=mockTopicCount,
        ~contractName="TestContract",
      ),
      Some(mockEventMod->toInternal),
    )
  })

  it("get returns the correct eventMod witthout address in mapping if unique", () => {
    let mockEventMod = makeMockEventMod(
      ~sighash=mockSighash,
      ~name=mockEventName,
      ~contractName="TestContract",
      ~isWildcard=false,
    )
    let lookup = EventModLookup.empty()

    lookup
    ->EventModLookup.set(mockEventMod)
    ->EventModLookup.unwrapAddEventResponse(~chain=mockChain)

    Assert.deepEqual(
      lookup->EventModLookup.get(
        ~sighash=mockSighash,
        ~topicCount=mockTopicCount,
        ~contractAddress=mockAddress1,
        ~contractAddressMapping=ContractAddressingMap.make(),
      ),
      Some(mockEventMod->toInternal),
    )
  })

  it(
    "get returns correct event mod with multiple contracts for both wildcard and non wildcard",
    () => {
      let wildcardContractAddress = mockAddress1
      let nonWildcardContractAddress = mockAddress2
      let nonWildcardContractName = "TestContract2"
      let mockWildcardEventMod = makeMockEventMod(
        ~sighash=mockSighash,
        ~name=mockEventName,
        ~contractName="TestContract1",
        ~isWildcard=true,
      )
      let mockNonWildcardEventMod = makeMockEventMod(
        ~sighash=mockSighash,
        ~name=mockEventName,
        ~contractName=nonWildcardContractName,
        ~isWildcard=false,
      )

      let lookup = EventModLookup.empty()

      lookup
      ->EventModLookup.set(mockWildcardEventMod)
      ->EventModLookup.unwrapAddEventResponse(~chain=mockChain)
      lookup
      ->EventModLookup.set(mockNonWildcardEventMod)
      ->EventModLookup.unwrapAddEventResponse(~chain=mockChain)

      let contractAddressMapping = ContractAddressingMap.make()
      contractAddressMapping->ContractAddressingMap.addAddress(
        ~name=nonWildcardContractName,
        ~address=nonWildcardContractAddress,
      )

      Assert.deepEqual(
        lookup->EventModLookup.get(
          ~sighash=mockSighash,
          ~topicCount=mockTopicCount,
          ~contractAddress=nonWildcardContractAddress,
          ~contractAddressMapping,
        ),
        Some(mockNonWildcardEventMod->toInternal),
        ~message="Should return the non wildcard event mod",
      )

      Assert.deepEqual(
        lookup->EventModLookup.get(
          ~sighash=mockSighash,
          ~topicCount=mockTopicCount,
          ~contractAddress=wildcardContractAddress,
          ~contractAddressMapping,
        ),
        Some(mockWildcardEventMod->toInternal),
        ~message="Should return the wildcard event mod",
      )
    },
  )

  it("unwrapAddEventResponse failures", () => {
    let eventMod =
      makeMockEventMod(
        ~sighash=mockSighash,
        ~name=mockEventName,
        ~contractName="TestContract",
        ~isWildcard=false,
      )->toInternal

    [EventModLookup.Duplicate, WildcardSighashCollision]->Belt.Array.forEach(
      errorKind => {
        Assert.throws(
          () => {
            Error({eventMod, errorKind})->EventModLookup.unwrapAddEventResponse(~chain=mockChain)
          },
        )
      },
    )
  })
})
