open RescriptMocha

describe("Test eventFilters", () => {
  it("Supports multichain filters", () => {
    let eventConfig = Types.EventFiltersTest.Transfer.register()

    Assert.deepEqual(
      eventConfig.getTopicSelectionsOrThrow(~chain=ChainMap.Chain.makeUnsafe(~chainId=1)),
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
  })

  it("Empty filters should fallback to normal topic selection with only topic0", () => {
    let eventConfig = Types.EventFiltersTest.EmptyFiltersArray.register()

    Assert.deepEqual(
      eventConfig.getTopicSelectionsOrThrow(~chain=ChainMap.Chain.makeUnsafe(~chainId=1)),
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
  })
})
