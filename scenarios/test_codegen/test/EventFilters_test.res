open RescriptMocha

// Test types:
let filterArgsShouldBeASubsetOfInternal = (%raw(`null`): Types.EventFiltersTest.Transfer.eventFiltersArgs :> Internal.eventFiltersArgs)

describe("Test eventFilters", () => {
  it("Supports multichain filters", () => {
    let eventConfig = Types.EventFiltersTest.Transfer.register()

    Assert.deepEqual(
      eventConfig.getTopicSelectionsOrThrow({
        chainId: 137,
        addresses: [],
      }),
      [
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
      ],
    )
    Assert.equal(
      eventConfig.dependsOnAddresses,
      false,
      ~message=`Even though event filter has a callback,
      dependsOnAddresses should be set to false.
      Otherwise the wildcard event won't fetch for contracts without addresses`,
    )
  })

  it("Supports filter depending on addresses", () => {
    let eventConfig = Types.EventFiltersTest.WildcardWithAddress.register()

    Assert.deepEqual(
      eventConfig.getTopicSelectionsOrThrow({
        chainId: 137,
        addresses: [
          "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"->Address.unsafeFromString,
          "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"->Address.unsafeFromString,
        ],
      }),
      [
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
      ],
    )
    Assert.equal(eventConfig.dependsOnAddresses, true)
    Assert.equal(eventConfig.isWildcard, true)
  })

  it("Empty filters should fallback to normal topic selection with only topic0", () => {
    let eventConfig = Types.EventFiltersTest.EmptyFiltersArray.register()

    Assert.deepEqual(
      eventConfig.getTopicSelectionsOrThrow({
        chainId: 1,
        addresses: [],
      }),
      [
        {
          topic0: [
            "0x668839194402d721b0cf3fe98a505bd32f7601265985fd3ca34b9ddaaaa06ea5",
          ]->EvmTypes.Hex.fromStringsUnsafe,
          topic1: [],
          topic2: [],
          topic3: [],
        },
      ],
    )
    Assert.equal(eventConfig.dependsOnAddresses, false)
  })

  it("Fails on filter with excess field", () => {
    let eventConfig = Types.EventFiltersTest.WithExcessField.register()

    Assert.throws(
      () => {
        eventConfig.getTopicSelectionsOrThrow({
          chainId: 1,
          addresses: [],
        })
      },
      ~error={
        "message": `Invalid event filters configuration. The event doesn't have an indexed parameter "to" and can't use it for filtering`,
      },
    )
  })
})
