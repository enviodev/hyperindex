open RescriptMocha

let mockChain = ChainMap.Chain.makeUnsafe(~chainId=1)
let mockAddress1 = TestHelpers.Addresses.mockAddresses[0]
let mockAddress2 = TestHelpers.Addresses.mockAddresses[1]

let mockFromArray = (array): EventRouter.t<'a> => {
  Js.Dict.fromArray(array)
}

describe("EventRouter", () => {
  it("Succeeds on unique insertions", () => {
    let router: EventRouter.t<int> = EventRouter.empty()

    router->EventRouter.addOrThrow(
      "test-event-tag",
      1,
      ~contractName="Contract1",
      ~eventName="Event1",
      ~chain=mockChain,
      ~isWildcard=false,
    )
    router->EventRouter.addOrThrow(
      "test-event-tag",
      2,
      ~contractName="Contract2",
      ~eventName="Event1",
      ~chain=mockChain,
      ~isWildcard=false,
    )

    Assert.deepEqual(
      router,
      mockFromArray([
        (
          "test-event-tag",
          {
            wildcard: None,
            byContractName: Js.Dict.fromArray([("Contract1", 1), ("Contract2", 2)]),
          },
        ),
      ]),
    )
  })

  it("Fails on duplicate insertions", () => {
    let router = EventRouter.empty()

    router->EventRouter.addOrThrow(
      "test-event-tag",
      1,
      ~contractName="Contract1",
      ~eventName="Event1",
      ~chain=mockChain,
      ~isWildcard=false,
    )

    Assert.throws(
      () => {
        router->EventRouter.addOrThrow(
          "test-event-tag",
          1,
          ~contractName="Contract1",
          ~eventName="Event1",
          ~chain=mockChain,
          ~isWildcard=false,
        )
      },
      ~error={
        "message": "Duplicate event detected: Event1 for contract Contract1 on chain 1",
      },
    )
  })

  it("Fails on duplicate wildcard insertions", () => {
    let router = EventRouter.empty()

    router->EventRouter.addOrThrow(
      "test-event-tag",
      1,
      ~contractName="Contract1",
      ~eventName="Event1",
      ~chain=mockChain,
      ~isWildcard=true,
    )

    Assert.throws(
      () => {
        router->EventRouter.addOrThrow(
          "test-event-tag",
          1,
          ~contractName="Contract2",
          ~eventName="Event1",
          ~chain=mockChain,
          ~isWildcard=true,
        )
      },
      ~error={
        "message": "Another event is already registered with the same signature that would interfer with wildcard filtering: Event1 for contract Contract2 on chain 1",
      },
    )
  })

  it("get doesn't returns the correct eventMod without address in mapping if unique", () => {
    let router = EventRouter.empty()

    router->EventRouter.addOrThrow(
      "test-event-tag",
      1,
      ~contractName="Contract1",
      ~eventName="Event1",
      ~chain=mockChain,
      ~isWildcard=false,
    )

    Assert.deepEqual(
      router->EventRouter.get(
        ~tag="test-event-tag",
        ~contractAddress=mockAddress1,
        ~blockNumber=0,
        ~indexingContracts=Js.Dict.empty(),
      ),
      None,
      ~message=`We can return Some, but we want to always check that event is after contract startBlock`,
    )
  })

  it(
    "get returns correct event mod with multiple contracts for both wildcard and non wildcard",
    () => {
      let wildcardContractAddress = mockAddress1
      let nonWildcardContractAddress = mockAddress2
      let nonWildcardContractName = "Contract2"

      let router = EventRouter.empty()

      router->EventRouter.addOrThrow(
        "test-event-tag",
        "wildcard",
        ~contractName="Contract1",
        ~eventName="Event1",
        ~chain=mockChain,
        ~isWildcard=true,
      )
      router->EventRouter.addOrThrow(
        "test-event-tag",
        "non-wildcard",
        ~contractName=nonWildcardContractName,
        ~eventName="Event1",
        ~chain=mockChain,
        ~isWildcard=false,
      )

      let indexingContracts = Js.Dict.empty()
      indexingContracts->Js.Dict.set(
        nonWildcardContractAddress->Address.toString,
        {
          FetchState.startBlock: 0,
          contractName: nonWildcardContractName,
          address: nonWildcardContractAddress,
          register: Config,
        },
      )

      Assert.deepEqual(
        router->EventRouter.get(
          ~tag="test-event-tag",
          ~contractAddress=nonWildcardContractAddress,
          ~blockNumber=0,
          ~indexingContracts,
        ),
        Some("non-wildcard"),
        ~message="Should return the non wildcard event",
      )

      Assert.deepEqual(
        router->EventRouter.get(
          ~tag="test-event-tag",
          ~contractAddress=wildcardContractAddress,
          ~blockNumber=0,
          ~indexingContracts,
        ),
        Some("wildcard"),
        ~message="Should return the wildcard event",
      )
    },
  )

  it("fromEvmEventModsOrThrow works", () => {
    let item = Types.Gravatar.NewGravatar.register()
    let router = EventRouter.fromEvmEventModsOrThrow([item], ~chain=mockChain)

    Assert.deepEqual(
      router,
      mockFromArray([
        (
          "0x9ab3aefb2ba6dc12910ac1bce4692cf5c3c0d06cff16327c64a3ef78228b130b_1",
          {
            wildcard: None,
            byContractName: Js.Dict.fromArray([("Gravatar", item)]),
          },
        ),
      ]),
    )
  })
})
