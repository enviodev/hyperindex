open Vitest

// `registerAllHandlers` returns `(configWithRegistrations, _)` — the returned
// config captures the event filters registered by the handler modules.
let (configWithRegistrations, _) = await HandlerLoader.registerAllHandlers(
  ~config=Config.load(),
)

let getEvmEventConfig = MockConfig.getEvmEventConfig(~config=configWithRegistrations, ...)

// The codegen'd onEventWhereArgs is structurally compatible with
// Internal.onEventWhereArgs<_> at runtime; runtime parser uses Obj.magic.

describe("Test eventFilters", () => {
  it("Supports multichain filters", t => {
    let eventConfig = getEvmEventConfig(~contractName="EventFiltersTest", ~eventName="Transfer")

    t.expect(eventConfig.getEventFiltersOrThrow(ChainMap.Chain.makeUnsafe(~chainId=137))).toEqual(
      Static([
        {
          topic0: [
            "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
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
            "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
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
      ]),
    )
    t.expect(
      eventConfig.dependsOnAddresses,
      ~message=`Even though event filter has a callback,
      dependsOnAddresses should be set to false.
      Otherwise the wildcard event won't fetch for contracts without addresses`,
    ).toBe(false)
  })

  it("Supports filter depending on addresses", t => {
    // Per-chain where-callback probing: pick the chain 137 event config so
    // the probe exercises the branch that accesses addresses.
    let eventConfig = getEvmEventConfig(
      ~contractName="EventFiltersTest",
      ~eventName="WildcardWithAddress",
      ~chainId=137,
    )

    t.expect(
      switch eventConfig.getEventFiltersOrThrow(ChainMap.Chain.makeUnsafe(~chainId=137)) {
      | Static(_) => JsError.throwWithMessage("Should be dynamic")
      | Dynamic(fn) =>
        fn([
          "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"->Address.unsafeFromString,
          "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"->Address.unsafeFromString,
        ])
      },
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
    )

    t.expect(eventConfig.getEventFiltersOrThrow(ChainMap.Chain.makeUnsafe(~chainId=137))).toEqual(
      Static([
        {
          topic0: [
            "0x668839194402d721b0cf3fe98a505bd32f7601265985fd3ca34b9ddaaaa06ea5",
          ]->EvmTypes.Hex.fromStringsUnsafe,
          topic1: [],
          topic2: [],
          topic3: [],
        },
      ]),
    )
    t.expect(eventConfig.dependsOnAddresses, ~message="foo").toBe(false)
  })

  it("Fails on filter with excess field", t => {
    let eventConfig = getEvmEventConfig(
      ~contractName="EventFiltersTest",
      ~eventName="WithExcessField",
    )

    t.expect(
      () => {
        eventConfig.getEventFiltersOrThrow(ChainMap.Chain.makeUnsafe(~chainId=137))
      },
    ).toThrowError(`Invalid where configuration. The event doesn't have an indexed parameter "to" and can't use it for filtering`)
  })
})
