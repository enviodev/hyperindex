open Vitest

// `registerAllHandlers` loads the handler modules, which resolve the event
// filters per chain into the global `HandlerRegister` registry as a side
// effect — that registry state (not `config`, which never changes) is what
// `MockConfig.getEvmOnEventRegistration` reads below.
let config = Config.load()
let registrationsByChainId = await HandlerLoader.registerAllHandlers(~config)

let getEvmEventConfig = MockConfig.getEvmOnEventRegistration(~config, ...)

let getIndexedEvmEventRegistration = eventName => {
  let {HandlerRegister.onEventRegistrations} =
    registrationsByChainId->Dict.getUnsafe("1337")
  onEventRegistrations
  ->Array.find(registration =>
    registration.eventConfig.contractName === "TestEvents" &&
      registration.eventConfig.name === eventName
  )
  ->Option.getOrThrow
  ->(Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration)
}

type topicCase = {
  eventName: string,
  expectedTopic: string,
}

let scalarTopicCases: array<topicCase> = [
  {
    eventName: "IndexedUint",
    expectedTopic: "0x0000000000000000000000000000000000000000000000000000000000000032",
  },
  {
    eventName: "IndexedInt",
    expectedTopic: "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffce",
  },
  {
    eventName: "IndexedAddress",
    expectedTopic: "0x000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266",
  },
  {
    eventName: "IndexedBool",
    expectedTopic: "0x0000000000000000000000000000000000000000000000000000000000000001",
  },
  {
    eventName: "IndexedBytes",
    expectedTopic: "0x1a225f5394ea8eb90a8515ac3013a8d3573052db40af43b7d87c20d608fee005",
  },
  {
    eventName: "IndexedString",
    expectedTopic: "0x9c22ff5f21f0b81b113e63f7db6da94fedef11b2119b4088b89664fb9a3cb658",
  },
  {
    eventName: "IndexedFixedBytes",
    expectedTopic: "0x1212121212121212121212121212121212121212121212121212121212121212",
  },
]

let complexTopicCases: array<topicCase> = [
  {
    eventName: "IndexedStruct",
    expectedTopic: "0xd0b8769ea9cd15d60ef1800406aa875a74f05fc702bedb0572ea99e06d18257d",
  },
  {
    eventName: "IndexedArray",
    expectedTopic: "0xde4717968916aced526cf22f9a203477a82ac23edb99e677f506e50d182b3c4d",
  },
  {
    eventName: "IndexedFixedArray",
    expectedTopic: "0xde4717968916aced526cf22f9a203477a82ac23edb99e677f506e50d182b3c4d",
  },
  {
    eventName: "IndexedNestedArray",
    expectedTopic: "0x9cd74280be85e33c451783be7e54105bdc6d705b6e0b05836df0153a2ba47a2d",
  },
  {
    eventName: "IndexedStructArray",
    expectedTopic: "0x0aba228d60f8731c4d091fc13ecfd996a320396c78c09e6115ee42b6b2e0ad59",
  },
  {
    eventName: "IndexedNestedStruct",
    expectedTopic: "0xdc0d2e5de5ee32cae0b3bd19c32e5863ea705636c11bf11dd2e9d856033d3682",
  },
  {
    eventName: "IndexedStructWithArray",
    expectedTopic: "0x9d1a9024ca624fc8bfc4071fa581a206162ee435dfc42b756e1a70f1b5e4121c",
  },
]

let allTopicCases = Array.concat(scalarTopicCases, complexTopicCases)

let getTopicSelection = eventName => {
  let eventConfig = getEvmEventConfig(~contractName="TestEvents", ~eventName, ~chainId=1337)
  let clientRegistration =
    HyperSyncClient.Registration.fromOnEventRegistrations([eventConfig])->Array.getUnsafe(0)
  clientRegistration.topicSelections->Array.getUnsafe(0)
}

type emittedLog = {
  address: string,
  topics: array<string>,
  json: JSON.t,
}

let matchesRpcValue = (filterValue: JSON.t, actual: string): bool =>
  switch filterValue {
  | JSON.Null => true
  | JSON.String(expected) => expected->String.toLowerCase === actual->String.toLowerCase
  | JSON.Array(expected) =>
    expected->Array.some(value =>
      switch value {
      | JSON.String(expected) => expected->String.toLowerCase === actual->String.toLowerCase
      | _ => false
      }
    )
  | _ => false
  }

// Implements the address/topic subset of eth_getLogs over canonical log
// fixtures. The Rust client still issues a real HTTP JSON-RPC request; a wrong
// topic generated anywhere along the public registration -> native-query path
// therefore makes the provider return no log.
let rpcFilterMatchesLog = (~params: JSON.t, log: emittedLog): bool =>
  switch params {
  | JSON.Array([JSON.Object(filter)]) => {
      let addressMatches = switch filter->Dict.get("address") {
      | None => true
      | Some(filterValue) => matchesRpcValue(filterValue, log.address)
      }
      let topicsMatch = switch filter->Dict.get("topics") {
      | None => true
      | Some(JSON.Array(constraints)) => {
          let matches = ref(true)
          constraints->Array.forEachWithIndex((filterValue, index) => {
            switch log.topics->Array.get(index) {
            | Some(topic) if !matchesRpcValue(filterValue, topic) => matches := false
            | None =>
              switch filterValue {
              | JSON.Null => ()
              | _ => matches := false
              }
            | _ => ()
            }
          })
          matches.contents
        }
      | Some(_) => false
      }
      addressMatches && topicsMatch
    }
  | _ => false
  }

describe("Test eventFilters", () => {
  it("Matches Solidity's topics for indexed scalar filters through the public handler API", t => {
    scalarTopicCases->Array.forEach(({eventName, expectedTopic}) => {
      t.expect(getTopicSelection(eventName).topic1, ~message=eventName).toEqual(
        Some([expectedTopic]),
      )
    })
  })

  it("Preserves boundary scalar values across the NAPI encoder", t => {
    let maxUint = 115792089237316195423570985008687907853269984665640564039457584007913129639935n
    let minInt = -57896044618658097711785492504343953926634992332820282019728792003956564819968n
    let cases: array<(string, unknown, string)> = [
      (
        "uint256",
        maxUint->(Utils.magic: bigint => unknown),
        "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      ),
      (
        "int256",
        minInt->(Utils.magic: bigint => unknown),
        "0x8000000000000000000000000000000000000000000000000000000000000000",
      ),
      (
        "string",
        "héllo 🦀"->(Utils.magic: string => unknown),
        "0x541801b52322f17e33651df948fa5b57358e8f7db2645051b250a0a2411f0bd8",
      ),
      (
        "bytes4",
        "0x01020304"->(Utils.magic: string => unknown),
        "0x0102030400000000000000000000000000000000000000000000000000000000",
      ),
    ]
    cases->Array.forEach(((abiType, value, expectedTopic)) => {
      t.expect(
        Core.getAddon().encodeIndexedTopic(~abiType, ~value)->EvmTypes.Hex.toString,
        ~message=abiType,
      ).toBe(expectedTopic)
    })
  })

  it("Matches Solidity's topics for indexed complex-type filters", t => {
    // EventHandlers.ts registers this through the public API:
    // indexer.onEvent({
    //   contract: "TestEvents",
    //   event: "IndexedArray",
    //   where: {params: {array: [[50n, 51n]]}},
    // }, ...)
    //
    // TestEvents.emitTestEvents emits IndexedArray([50, 51]). Solidity hashes
    // an indexed array's special in-place encoding: the two padded elements,
    // without the offset or length prefix used by regular ABI encoding.
    // Exercise the filter path from public handler registration through the
    // client payload handed to the native source implementations.
    complexTopicCases->Array.forEach(({eventName, expectedTopic}) => {
      t.expect(getTopicSelection(eventName).topic1, ~message=eventName).toEqual(
        Some([expectedTopic]),
      )
    })
  })

  Async.it(
    "Matches canonical emitted logs through the native RPC client",
    async t => {
      // The registrations are produced by EventHandlers.ts calling the public
      // indexer.onEvent API. From here the test follows the production path:
      // registration serialization -> Rust selection builder -> real HTTP
      // eth_getLogs request -> Rust routing and decoding.
      let onEventRegistrations = allTopicCases->Array.map(({eventName}) =>
        getIndexedEvmEventRegistration(eventName)
      )
      let nativeRegistrations =
        HyperSyncClient.Registration.fromOnEventRegistrations(onEventRegistrations)
      let providerAddress = Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0)
      let providerAddressString = providerAddress->Address.toString

      let makeEmittedLog = (~topics, ~logIndex): emittedLog => {
        address: providerAddressString,
        topics,
        json: JSON.Object(
          Dict.fromArray([
            ("address", JSON.String(providerAddressString)),
            ("topics", JSON.Array(topics->Array.map(topic => JSON.String(topic)))),
            ("data", JSON.String("0x")),
            ("blockNumber", JSON.String("0x1")),
            (
              "transactionHash",
              JSON.String(
                "0x27e26f21f744064a4af53810d8002bbd7208a2ca4865503a99b9c529e5cff5ea",
              ),
            ),
            ("transactionIndex", JSON.String("0x0")),
            (
              "blockHash",
              JSON.String(
                "0x0000000000000000000000000000000000000000000000000000000000000001",
              ),
            ),
            ("logIndex", JSON.String(`0x${logIndex->Int.toString(~radix=16)}`)),
            ("removed", JSON.Boolean(false)),
          ]),
        ),
      }

      let emittedLogs = allTopicCases->Array.mapWithIndex((topicCase, index) => {
        let registration = nativeRegistrations->Array.getUnsafe(index)
        makeEmittedLog(
          ~topics=[registration.sighash, topicCase.expectedTopic],
          ~logIndex=index,
        )
      })
      // Same signature as IndexedUint, but a non-matching indexed value. If
      // native query construction drops topic1 or widens it accidentally, this
      // extra log is returned and the item-count/registration assertions fail.
      let mismatchingLog = makeEmittedLog(
        ~topics=[
          (nativeRegistrations->Array.getUnsafe(0)).sighash,
          "0x0000000000000000000000000000000000000000000000000000000000000000",
        ],
        ~logIndex=emittedLogs->Array.length,
      )
      let providerLogs = emittedLogs->Array.concat([mismatchingLog])

      let mock = await MockRpcServer.makeWithParams(~getResult=(~method, ~params) =>
        switch method {
        | "eth_getLogs" =>
          providerLogs
          ->Array.filter(log => rpcFilterMatchesLog(~params, log))
          ->Array.map(log => log.json)
          ->JSON.Array
        | _ => JSON.Null
        }
      )
      let client = EvmRpcClient.make(
        ~url=mock.url,
        ~checksumAddresses=true,
        ~syncConfig=EvmChain.getSyncConfig({}),
        ~eventRegistrations=nativeRegistrations,
      )
      let addressesByContractName = Dict.fromArray([("TestEvents", [providerAddress])])

      let page = try await client.getNextPage({
        fromBlock: 1,
        toBlockCeiling: 1,
        partitionId: "topic-filter-e2e",
        registrationIndexes: nativeRegistrations->Array.map(reg => reg.index),
        addressesByContractName,
        clientSideFilteredContracts: None,
      }) catch {
      | exn =>
        mock.close()
        throw(exn)
      }
      mock.close()

      let getLogsRequestCount =
        mock.requests->Array.filter(body => body->String.includes("eth_getLogs"))->Array.length
      t.expect((
        getLogsRequestCount,
        page.items->Array.map(item => item.onEventRegistrationIndex),
      )).toEqual((
        allTopicCases->Array.length,
        nativeRegistrations->Array.map(reg => reg.index),
      ))
    },
  )

  it("Supports multichain filters and lowercases mixed-case address values", t => {
    let eventConfig = getEvmEventConfig(
      ~contractName="EventFiltersTest",
      ~eventName="Transfer",
      ~chainId=137,
    )

    // The whitelisted addresses are checksummed (mixed-case) in the handler
    // file; the resolved topics must be lowercased so they match the
    // lowercase hex topics returned by sources.
    t.expect(eventConfig.resolvedWhere.topicSelections).toEqual([
      {
        topic0: [
          "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        ]->EvmTypes.Hex.fromStringsUnsafe,
        topic1: Values(
          [
            "0x0000000000000000000000000000000000000000000000000000000000000000",
          ]->EvmTypes.Hex.fromStringsUnsafe,
        ),
        topic2: Values(
          [
            "0x000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266",
            "0x00000000000000000000000070997970c51812dc3a010c7d01b50e0d17dc79c8",
          ]->EvmTypes.Hex.fromStringsUnsafe,
        ),
        topic3: Values([]),
      },
      {
        topic0: [
          "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        ]->EvmTypes.Hex.fromStringsUnsafe,
        topic1: Values(
          [
            "0x000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266",
            "0x00000000000000000000000070997970c51812dc3a010c7d01b50e0d17dc79c8",
          ]->EvmTypes.Hex.fromStringsUnsafe,
        ),
        topic2: Values(
          [
            "0x0000000000000000000000000000000000000000000000000000000000000000",
          ]->EvmTypes.Hex.fromStringsUnsafe,
        ),
        topic3: Values([]),
      },
    ])
    t.expect(
      eventConfig.dependsOnAddresses,
      ~message=`Even though event filter has a callback,
      dependsOnAddresses should be set to false.
      Otherwise the wildcard event won't fetch for contracts without addresses`,
    ).toBe(false)
  })

  it("Supports filter depending on addresses", t => {
    let eventConfig = getEvmEventConfig(
      ~contractName="EventFiltersTest",
      ~eventName="WildcardWithAddress",
      ~chainId=137,
    )

    t.expect(eventConfig.resolvedWhere.topicSelections).toEqual([
      {
        topic0: [
          "0xf26849ed9bbf448cc2a8d7bcb15203e1e2a68bbbd94550aa4f2f717455c1abed",
        ]->EvmTypes.Hex.fromStringsUnsafe,
        topic1: Values(
          [
            "0x0000000000000000000000000000000000000000000000000000000000000000",
          ]->EvmTypes.Hex.fromStringsUnsafe,
        ),
        topic2: ContractAddresses({contractName: "EventFiltersTest"}),
        topic3: Values([]),
      },
      {
        topic0: [
          "0xf26849ed9bbf448cc2a8d7bcb15203e1e2a68bbbd94550aa4f2f717455c1abed",
        ]->EvmTypes.Hex.fromStringsUnsafe,
        topic1: ContractAddresses({contractName: "EventFiltersTest"}),
        topic2: Values(
          [
            "0x0000000000000000000000000000000000000000000000000000000000000000",
          ]->EvmTypes.Hex.fromStringsUnsafe,
        ),
        topic3: Values([]),
      },
    ])

    // Materialization at query build expands the markers into the
    // partition's addresses encoded as topics.
    t.expect(
      eventConfig.resolvedWhere.topicSelections->LogSelection.materializeTopicSelections(
        ~addresses=[
          "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"->Address.unsafeFromString,
          "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"->Address.unsafeFromString,
        ],
      ),
    ).toEqual([
      {
        topic0: [
          "0xf26849ed9bbf448cc2a8d7bcb15203e1e2a68bbbd94550aa4f2f717455c1abed",
        ]->EvmTypes.Hex.fromStringsUnsafe,
        topic1: [
          "0x0000000000000000000000000000000000000000000000000000000000000000",
        ]->EvmTypes.Hex.fromStringsUnsafe,
        topic2: [
          "0x000000000000000000000000f39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
          "0x00000000000000000000000070997970C51812dc3A010C7d01b50e0d17dc79C8",
        ]->EvmTypes.Hex.fromStringsUnsafe,
        topic3: [],
      },
      {
        topic0: [
          "0xf26849ed9bbf448cc2a8d7bcb15203e1e2a68bbbd94550aa4f2f717455c1abed",
        ]->EvmTypes.Hex.fromStringsUnsafe,
        topic1: [
          "0x000000000000000000000000f39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
          "0x00000000000000000000000070997970C51812dc3A010C7d01b50e0d17dc79C8",
        ]->EvmTypes.Hex.fromStringsUnsafe,
        topic2: [
          "0x0000000000000000000000000000000000000000000000000000000000000000",
        ]->EvmTypes.Hex.fromStringsUnsafe,
        topic3: [],
      },
    ])
    t.expect(eventConfig.dependsOnAddresses).toBe(true)
    t.expect(eventConfig.isWildcard).toBe(true)
  })

  it("Empty filters should fallback to normal topic selection with only topic0", t => {
    let eventConfig = getEvmEventConfig(
      ~contractName="EventFiltersTest",
      ~eventName="EmptyFiltersArray",
      ~chainId=137,
    )

    t.expect(eventConfig.resolvedWhere.topicSelections).toEqual([
      {
        topic0: [
          "0x668839194402d721b0cf3fe98a505bd32f7601265985fd3ca34b9ddaaaa06ea5",
        ]->EvmTypes.Hex.fromStringsUnsafe,
        topic1: Values([]),
        topic2: Values([]),
        topic3: Values([]),
      },
    ])
    t.expect(eventConfig.dependsOnAddresses, ~message="foo").toBe(false)
  })

  it("Second registration with a distinct-but-equal-resolving where composes handlers", t => {
    // EmptyFiltersArray is registered twice in EventHandlers.ts with two
    // different callback instances that resolve identically — the duplicate
    // guard compares resolved structures, so registration succeeded and the
    // handlers composed.
    let eventConfig = getEvmEventConfig(
      ~contractName="EventFiltersTest",
      ~eventName="EmptyFiltersArray",
      ~chainId=137,
    )
    t.expect(eventConfig.handler->Option.isSome).toBe(true)
  })

  it("Where returning false drops the chain's registration entirely", t => {
    // WithExcessField's where returns `false` for chain 100 and a filter for
    // chain 137 — the handler opted out of chain 100, so the event gets no
    // registration there (not even a raw-events one), only on 137.
    let hasEvent = chainId =>
      switch registrationsByChainId->Dict.get(chainId) {
      | Some({HandlerRegister.onEventRegistrations: regs}) =>
        regs->Array.some(reg => reg.eventConfig.name === "WithExcessField")
      | None => false
      }
    t.expect((hasEvent("137"), hasEvent("100"))).toEqual((true, false))
  })

  it("Fails on filter with excess field at registration time", t => {
    let eventConfig = MockConfig.getEvmEventConfig(
      ~config,
      ~contractName="EventFiltersTest",
      ~eventName="WithExcessField",
      ~chainId=137,
    )
    t.expect(() =>
      EventConfigBuilder.buildEvmOnEventRegistration(
        ~eventConfig,
        ~isWildcard=true,
        ~handler=None,
        ~contractRegister=None,
        ~where=Some(
          %raw(`{params: {from: "0x0000000000000000000000000000000000000000", to: "0x0000000000000000000000000000000000000000"}}`),
        ),
        ~chainId=137,
        ~onEventBlockFilterSchema=config.ecosystem.onEventBlockFilterSchema,
      )
    ).toThrowError(`Invalid where configuration. The event doesn't have an indexed parameter "to" and can't use it for filtering`)
  })

  it("Registration path builds clientAddressFilter for address-filtered events only", t => {
    let wildcardWithAddress = getEvmEventConfig(
      ~contractName="EventFiltersTest",
      ~eventName="WildcardWithAddress",
      ~chainId=137,
    )
    let transfer = getEvmEventConfig(
      ~contractName="EventFiltersTest",
      ~eventName="Transfer",
      ~chainId=137,
    )
    t.expect((
      wildcardWithAddress.clientAddressFilter->Option.isSome,
      transfer.clientAddressFilter->Option.isNone,
    )).toEqual((true, true))
  })
})
