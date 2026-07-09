open Vitest

// `registerAllHandlers` loads the handler modules, which resolve the event
// filters per chain into the global `HandlerRegister` registry as a side
// effect — that registry state (not `config`, which never changes) is what
// `MockConfig.getEvmOnEventRegistration` reads below.
let config = Config.load()
let registrationsByChainId = await HandlerLoader.registerAllHandlers(~config)

let getEvmEventConfig = MockConfig.getEvmOnEventRegistration(~config, ...)

describe("Test eventFilters", () => {
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
    // chain 137 — the finished registrations must include it only on 137.
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
