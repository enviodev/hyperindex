open Vitest


describe("HyperFuelSource - getNormalRecieptsSelection", () => {
  let contractName1 = "TestContract"
  let contractName2 = "TestContract2"
  let chain = ChainMap.Chain.makeUnsafe(~chainId=0)
  let address1 = Address.unsafeFromString("0x1234567890abcdef1234567890abcdef1234567890abcde1")
  let address2 = Address.unsafeFromString("0x1234567890abcdef1234567890abcdef1234567890abcde2")
  let address3 = Address.unsafeFromString("0x1234567890abcdef1234567890abcdef1234567890abcde3")

  let mock = (~contracts: array<Internal.fuelContractConfig>) => {
    let selectionConfig = {
      dependsOnAddresses: true,
      eventConfigs: contracts->Array.flatMap(c => {
        c.events->Array.filterMap(
          e => {
            if e.isWildcard {
              None
            } else {
              Some((e :> Internal.eventConfig))
            }
          },
        )
      }),
    }->HyperFuelSource.getSelectionConfig(~chain)
    selectionConfig.getRecieptsSelection
  }

  let mockAddressesByContractName = () => {
    Js.Dict.fromArray([(contractName1, [address1, address2]), (contractName2, [address3])])
  }

  it("Receipts Selection with no contracts", t => {
    let getNormalRecieptsSelection = mock(~contracts=[])
    t.expect(
      getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
    ).toEqual(
      [],
    )
  })

  it("Receipts Selection with no events", t => {
    let getNormalRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [],
        },
      ],
    )
    t.expect(
      getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
    ).toEqual(
      [],
    )
  })

  it("Receipts Selection with single non-wildcard log event", t => {
    let getNormalRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              id: "1",
              name: "StrLog",
              contractName: "TestContract",
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
    ).toEqual(
      [
        {
          rb: [1n],
          receiptType: [LogData],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
      ],
    )
  })

  it(
    "Receipts Selection with non-wildcard transfer event - catches both TRANSFER and TRANSFER_OUT receipts",
    t => {
      let getNormalRecieptsSelection = mock(
        ~contracts=[
          {
            name: "TestContract",
            events: [
              {
                id: "Transfer",
                name: "Transfer",
                contractName: "TestContract",
                kind: Transfer,
                isWildcard: false,
                filterByAddresses: false,
                dependsOnAddresses: true,
                handler: None,
                contractRegister: None,
                paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
              },
            ],
          },
          {
            name: "TestContract2",
            events: [
              {
                id: "Transfer",
                name: "Transfer",
                contractName: "TestContract2",
                kind: Transfer,
                isWildcard: false,
                filterByAddresses: false,
                dependsOnAddresses: true,
                handler: None,
                contractRegister: None,
                paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
              },
            ],
          },
        ],
      )
      t.expect(
        getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
      ).toEqual(
        [
          {
            receiptType: [Transfer, TransferOut],
            rootContractId: [address1, address2],
            txStatus: [1],
          },
          {
            receiptType: [Transfer, TransferOut],
            rootContractId: [address3],
            txStatus: [1],
          },
        ],
      )
    },
  )

  it("Receipts Selection with non-wildcard mint event", t => {
    let getNormalRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              id: "Mint",
              name: "Mint",
              contractName: "TestContract",
              kind: Mint,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              id: "Mint",
              name: "Mint",
              contractName: "TestContract2",
              kind: Mint,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
    ).toEqual(
      [
        {
          receiptType: [Mint],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
        {
          receiptType: [Mint],
          rootContractId: [address3],
          txStatus: [1],
        },
      ],
    )
  })

  it("Receipts Selection with non-wildcard burn event", t => {
    let getNormalRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              id: "Burn",
              name: "Burn",
              contractName: "TestContract",
              kind: Burn,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              id: "Burn",
              name: "Burn",
              contractName: "TestContract2",
              kind: Burn,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
    ).toEqual(
      [
        {
          receiptType: [Burn],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
        {
          receiptType: [Burn],
          rootContractId: [address3],
          txStatus: [1],
        },
      ],
    )
  })

  it("Receipts Selection with all possible events together", t => {
    let getNormalRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              id: "1",
              name: "StrLog",
              contractName: "TestContract",
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "2",
              name: "BoolLog",
              contractName: "TestContract",
              kind: LogData({
                logId: "2",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "Mint",
              name: "Mint",
              contractName: "TestContract",
              kind: Mint,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "Burn",
              name: "Burn",
              contractName: "TestContract",
              kind: Burn,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "Transfer",
              name: "Transfer",
              contractName: "TestContract",
              kind: Transfer,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "Call",
              name: "Call",
              contractName: "TestContract",
              kind: Call,
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              id: "UnitLog",
              name: "UnitLog",
              contractName: "TestContract2",
              kind: LogData({
                logId: "3",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "Burn",
              name: "Burn",
              contractName: "TestContract2",
              kind: Burn,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
      ~message=`Note that non-wildcard events should be skipped`,
    ).toEqual(
      [
        {
          receiptType: [Mint, Burn, Transfer, TransferOut],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
        {
          rb: [1n],
          receiptType: [LogData],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
        {
          receiptType: [Burn],
          rootContractId: [address3],
          txStatus: [1],
        },
        {
          rb: [3n],
          receiptType: [LogData],
          rootContractId: [address3],
          txStatus: [1],
        },
      ],
    )
  })

  it("Fails with non-wildcard Call event", t => {
    t.expect(
      () => {
        mock(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  id: "Call",
                  name: "Call",
                  contractName: "TestContract",
                  kind: Call,
                  isWildcard: false,
                  filterByAddresses: false,
                  dependsOnAddresses: true,
                  handler: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
                },
              ],
            },
          ],
        )
      },
    ).toThrowError(
      "Call receipt indexing currently supported only in wildcard mode",
    )
  })

  it("Fails when contract has multiple mint events", t => {
    t.expect(
      () => {
        mock(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  id: "Mint",
                  name: "MyEvent",
                  contractName: "TestContract",
                  kind: Mint,
                  isWildcard: false,
                  filterByAddresses: false,
                  dependsOnAddresses: true,
                  handler: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
                },
                {
                  id: "Mint",
                  name: "MyEvent2",
                  contractName: "TestContract",
                  kind: Mint,
                  isWildcard: false,
                  filterByAddresses: false,
                  dependsOnAddresses: true,
                  handler: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
                },
              ],
            },
          ],
        )
      },
    ).toThrowError(
      "Duplicate event detected: MyEvent2 for contract TestContract on chain 0",
    )
  })

  it("Fails when contract has multiple burn events", t => {
    t.expect(
      () => {
        mock(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  id: "Burn",
                  name: "MyEvent",
                  contractName: "TestContract",
                  kind: Burn,
                  isWildcard: false,
                  filterByAddresses: false,
                  dependsOnAddresses: true,
                  handler: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
                },
                {
                  id: "Burn",
                  name: "MyEvent2",
                  contractName: "TestContract",
                  kind: Burn,
                  isWildcard: false,
                  filterByAddresses: false,
                  dependsOnAddresses: true,
                  handler: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
                },
              ],
            },
          ],
        )
      },
    ).toThrowError(
      "Duplicate event detected: MyEvent2 for contract TestContract on chain 0",
    )
  })

  it(
    "Shouldn't fail with contracts having the same wildcard and non-wildcard event. This should be handled when we create FetchState",
    t => {
      let getNormalRecieptsSelection = mock(
        ~contracts=[
          {
            name: "TestContract",
            events: [
              {
                id: "Mint",
                name: "WildcardMint",
                contractName: "TestContract",
                kind: Mint,
                isWildcard: true,
                filterByAddresses: false,
                dependsOnAddresses: false,
                handler: None,
                contractRegister: None,
                paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
              },
              {
                id: "Mint",
                name: "Mint",
                contractName: "TestContract",
                kind: Mint,
                isWildcard: false,
                filterByAddresses: false,
                dependsOnAddresses: true,
                handler: None,
                contractRegister: None,
                paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
              },
            ],
          },
        ],
      )
      t.expect(
        getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
      ).toEqual(
        [
          {
            receiptType: [Mint],
            rootContractId: [address1, address2],
            txStatus: [1],
          },
        ],
      )
    },
  )

  it("Works with wildcard mint and non-wildcard mint together in different contract", t => {
    let getNormalRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract2",
          events: [
            {
              id: "Mint",
              name: "Mint",
              contractName: "TestContract2",
              kind: Mint,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract",
          events: [
            {
              id: "Mint",
              name: "Mint",
              contractName: "TestContract",
              kind: Mint,
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
    ).toEqual(
      [
        {
          receiptType: [Mint],
          rootContractId: [address3],
          txStatus: [1],
        },
      ],
    )

    // The same but with different event registration order
    let getNormalRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              id: "Mint",
              name: "Mint",
              contractName: "TestContract",
              kind: Mint,
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              id: "Mint",
              name: "Mint",
              contractName: "TestContract2",
              kind: Mint,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
    ).toEqual(
      [
        {
          receiptType: [Mint],
          rootContractId: [address3],
          txStatus: [1],
        },
      ],
    )
  })

  it("Works with wildcard burn and non-wildcard burn together in different contract", t => {
    let getNormalRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract2",
          events: [
            {
              id: "Burn",
              name: "Burn",
              contractName: "TestContract2",
              kind: Burn,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract",
          events: [
            {
              id: "Burn",
              name: "Burn",
              contractName: "TestContract",
              kind: Burn,
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
    ).toEqual(
      [
        {
          receiptType: [Burn],
          rootContractId: [address3],
          txStatus: [1],
        },
      ],
    )

    // The same but with different event registration order
    let getNormalRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              id: "Burn",
              name: "Burn",
              contractName: "TestContract",
              kind: Burn,
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              id: "Burn",
              name: "Burn",
              contractName: "TestContract2",
              kind: Burn,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      getNormalRecieptsSelection(~addressesByContractName=mockAddressesByContractName()),
    ).toEqual(
      [
        {
          receiptType: [Burn],
          rootContractId: [address3],
          txStatus: [1],
        },
      ],
    )
  })
})

describe("HyperFuelSource - makeWildcardRecieptsSelection", () => {
  let chain = ChainMap.Chain.makeUnsafe(~chainId=0)

  let mock = (~contracts: array<Internal.fuelContractConfig>) => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: contracts->Array.flatMap(c => {
        c.events->Array.filterMap(
          e => {
            if e.isWildcard {
              Some((e :> Internal.eventConfig))
            } else {
              None
            }
          },
        )
      }),
    }->HyperFuelSource.getSelectionConfig(~chain)
    selectionConfig.getRecieptsSelection(~addressesByContractName=Js.Dict.empty())
  }

  it("Receipts Selection with no contracts", t => {
    let wildcardReceiptsSelection = mock(~contracts=[])
    t.expect(
      wildcardReceiptsSelection,
      ~message=`It should never happen, since the partition like this wouldn't exist`,
    ).toEqual(
      [],
    )
  })

  it("Receipts Selection with no events", t => {
    let wildcardReceiptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [],
        },
      ],
    )
    t.expect(
      wildcardReceiptsSelection,
      ~message=`It should never happen, since the partition like this wouldn't exist`,
    ).toEqual(
      [],
    )
  })

  it("Receipts Selection with all possible events together", t => {
    let wildcardReceiptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              id: "1",
              name: "StrLog",
              contractName: "TestContract",
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "2",
              name: "BoolLog",
              contractName: "TestContract",
              kind: LogData({
                logId: "2",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "Mint",
              name: "Mint",
              contractName: "TestContract",
              kind: Mint,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "Burn",
              name: "Burn",
              contractName: "TestContract",
              kind: Burn,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "Transfer",
              name: "Transfer",
              contractName: "TestContract",
              kind: Transfer,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "Call",
              name: "Call",
              contractName: "TestContract",
              kind: Call,
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              id: "3",
              name: "UnitLog",
              contractName: "TestContract2",
              kind: LogData({
                logId: "3",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "Burn",
              name: "Burn",
              contractName: "TestContract2",
              kind: Burn,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      wildcardReceiptsSelection,
      ~message=`Note that wildcard events should be skipped`,
    ).toEqual(
      [
        {
          receiptType: [Call],
          txStatus: [1],
        },
        {
          rb: [2n],
          receiptType: [LogData],
          txStatus: [1],
        },
      ],
    )
  })

  it("Works with wildcard mint and non-wildcard mint together in different contract", t => {
    let wildcardReceiptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract2",
          events: [
            {
              id: "Mint",
              name: "Mint",
              contractName: "TestContract2",
              kind: Mint,
              isWildcard: false,
              filterByAddresses: false,
              dependsOnAddresses: true,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract",
          events: [
            {
              id: "Mint",
              name: "Mint",
              contractName: "TestContract",
              kind: Mint,
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      wildcardReceiptsSelection,
    ).toEqual(
      [
        {
          receiptType: [Mint],
          txStatus: [1],
        },
      ],
    )
  })

  it("Receipts Selection with wildcard mint event", t => {
    let wildcardReceiptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              id: "Mint",
              name: "Mint",
              contractName: "TestContract",
              kind: Mint,
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      wildcardReceiptsSelection,
    ).toEqual(
      [
        {
          receiptType: [Mint],
          txStatus: [1],
        },
      ],
    )
  })

  it("Receipts Selection with wildcard burn event", t => {
    let wildcardReceiptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              id: "Burn",
              name: "Burn",
              contractName: "TestContract",
              kind: Burn,
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      wildcardReceiptsSelection,
    ).toEqual(
      [
        {
          receiptType: [Burn],
          txStatus: [1],
        },
      ],
    )
  })

  it("Receipts Selection with multiple wildcard log event", t => {
    let wildcardReceiptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              id: "1",
              name: "StrLog",
              contractName: "TestContract",
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
            {
              id: "2",
              name: "BoolLog",
              contractName: "TestContract",
              kind: LogData({
                logId: "2",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              id: "3",
              name: "UnitLog",
              contractName: "TestContract2",
              kind: LogData({
                logId: "3",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
              filterByAddresses: false,
              dependsOnAddresses: false,
              handler: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
              simulateParamsSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    t.expect(
      wildcardReceiptsSelection,
    ).toEqual(
      [
        {
          rb: [1n, 2n, 3n],
          receiptType: [LogData],
          txStatus: [1],
        },
      ],
    )
  })
})
