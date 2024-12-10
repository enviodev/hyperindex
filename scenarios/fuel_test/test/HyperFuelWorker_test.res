open RescriptMocha

describe("HyperFuelWorker - getRecieptsSelection", () => {
  let contractName1 = "TestContract"
  let contractName2 = "TestContract2"
  let chain = ChainMap.Chain.makeUnsafe(~chainId=0)
  let address1 = Address.unsafeFromString("0x1234567890abcdef1234567890abcdef1234567890abcde1")
  let address2 = Address.unsafeFromString("0x1234567890abcdef1234567890abcdef1234567890abcde2")
  let address3 = Address.unsafeFromString("0x1234567890abcdef1234567890abcdef1234567890abcde3")

  let mock = (~contracts) => {
    let workerConfig = HyperFuelWorker.makeWorkerConfigOrThrow(~contracts, ~chain)
    HyperFuelWorker.makeGetRecieptsSelection(
      ~wildcardLogDataRbs=workerConfig.wildcardLogDataRbs,
      ~nonWildcardLogDataRbsByContract=workerConfig.nonWildcardLogDataRbsByContract,
      ~nonLogDataReceiptTypesByContract=workerConfig.nonLogDataReceiptTypesByContract,
      ~nonLogDataWildcardReceiptTypes=workerConfig.nonLogDataWildcardReceiptTypes,
      ~contracts,
    )
  }

  let mockContractAddressMapping = () => {
    ContractAddressingMap.fromArray([
      (address1, contractName1),
      (address2, contractName1),
      (address3, contractName2),
    ])
  }

  it("Receipts Selection with no contracts", () => {
    let getRecieptsSelection = mock(~contracts=[])
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [],
    )
  })

  it("Receipts Selection with no events", () => {
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [],
    )
  })

  it("Receipts Selection with single non-wildcard log event", () => {
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "StrLog",
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
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
    () => {
      let getRecieptsSelection = mock(
        ~contracts=[
          {
            name: "TestContract",
            events: [
              {
                name: "Transfer",
                kind: Transfer,
                isWildcard: false,
                handler: None,
                loader: None,
                contractRegister: None,
                paramsRawEventSchema: %raw(`"Not relevat"`),
              },
            ],
          },
          {
            name: "TestContract2",
            events: [
              {
                name: "Transfer",
                kind: Transfer,
                isWildcard: false,
                handler: None,
                loader: None,
                contractRegister: None,
                paramsRawEventSchema: %raw(`"Not relevat"`),
              },
            ],
          },
        ],
      )
      Assert.deepEqual(
        getRecieptsSelection(
          ~contractAddressMapping=mockContractAddressMapping(),
          ~shouldApplyWildcards=true,
        ),
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

  it("Receipts Selection with non-wildcard mint event", () => {
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "Mint",
              kind: Mint,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              name: "Mint",
              kind: Mint,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
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

  it("Receipts Selection with non-wildcard burn event", () => {
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "Burn",
              kind: Burn,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              name: "Burn",
              kind: Burn,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
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

  it("Receipts Selection with wildcard mint event", () => {
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "Mint",
              kind: Mint,
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [
        {
          receiptType: [Mint],
          txStatus: [1],
        },
      ],
    )
  })

  it("Receipts Selection with wildcard burn event", () => {
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "Burn",
              kind: Burn,
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [
        {
          receiptType: [Burn],
          txStatus: [1],
        },
      ],
    )
  })

  it("Receipts Selection with multiple wildcard log event", () => {
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "StrLog",
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
            {
              name: "BoolLog",
              kind: LogData({
                logId: "2",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              name: "UnitLog",
              kind: LogData({
                logId: "3",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [
        {
          rb: [1n, 2n, 3n],
          receiptType: [LogData],
          txStatus: [1],
        },
      ],
    )
  })

  it("Receipts Selection with all possible events together", () => {
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "StrLog",
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
            {
              name: "BoolLog",
              kind: LogData({
                logId: "2",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
            {
              name: "Mint",
              kind: Mint,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
            {
              name: "Burn",
              kind: Burn,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
            {
              name: "Transfer",
              kind: Transfer,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
            {
              name: "Call",
              kind: Call,
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              name: "UnitLog",
              kind: LogData({
                logId: "3",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
            {
              name: "Burn",
              kind: Burn,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
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

  it("Fails with non-wildcard Call event", () => {
    Assert.throws(
      () => {
        mock(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  name: "Call",
                  kind: Call,
                  isWildcard: false,
                  handler: None,
                  loader: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Call receipt indexing currently supported only in wildcard mode",
      },
    )
  })

  it("Fails when contract has multiple mint events", () => {
    Assert.throws(
      () => {
        mock(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  name: "MyEvent",
                  kind: Mint,
                  isWildcard: false,
                  handler: None,
                  loader: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
                },
                {
                  name: "MyEvent2",
                  kind: Mint,
                  isWildcard: false,
                  handler: None,
                  loader: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Duplicate event detected: MyEvent2 for contract TestContract on chain 0",
      },
    )
  })

  it("Fails when contract has multiple burn events", () => {
    Assert.throws(
      () => {
        mock(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  name: "MyEvent",
                  kind: Burn,
                  isWildcard: false,
                  handler: None,
                  loader: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
                },
                {
                  name: "MyEvent2",
                  kind: Burn,
                  isWildcard: false,
                  handler: None,
                  loader: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Duplicate event detected: MyEvent2 for contract TestContract on chain 0",
      },
    )
  })

  it("Fails with wildcard mint and non-wildcard mint together in the same contract", () => {
    Assert.throws(
      () => {
        mock(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  name: "WildcardMint",
                  kind: Mint,
                  isWildcard: true,
                  handler: None,
                  loader: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
                },
                {
                  name: "Mint",
                  kind: Mint,
                  isWildcard: false,
                  handler: None,
                  loader: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Duplicate event detected: Mint for contract TestContract on chain 0",
      },
    )
  })

  it("Fails with wildcard burn and non-wildcard burn together in the same contract", () => {
    Assert.throws(
      () => {
        mock(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  name: "WildcardBurn",
                  kind: Burn,
                  isWildcard: true,
                  handler: None,
                  loader: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
                },
                {
                  name: "Burn",
                  kind: Burn,
                  isWildcard: false,
                  handler: None,
                  loader: None,
                  contractRegister: None,
                  paramsRawEventSchema: %raw(`"Not relevat"`),
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Duplicate event detected: Burn for contract TestContract on chain 0",
      },
    )
  })

  it("Works with wildcard mint and non-wildcard mint together in different contract", () => {
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract2",
          events: [
            {
              name: "Mint",
              kind: Mint,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract",
          events: [
            {
              name: "Mint",
              kind: Mint,
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [
        {
          receiptType: [Mint],
          rootContractId: [address3],
          txStatus: [1],
        },
        {
          receiptType: [Mint],
          txStatus: [1],
        },
      ],
    )

    // The same but with different event registration order
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "Mint",
              kind: Mint,
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              name: "Mint",
              kind: Mint,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [
        {
          receiptType: [Mint],
          rootContractId: [address3],
          txStatus: [1],
        },
        {
          receiptType: [Mint],
          txStatus: [1],
        },
      ],
    )
  })

  it("Works with wildcard burn and non-wildcard burn together in different contract", () => {
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract2",
          events: [
            {
              name: "Burn",
              kind: Burn,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract",
          events: [
            {
              name: "Burn",
              kind: Burn,
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [
        {
          receiptType: [Burn],
          rootContractId: [address3],
          txStatus: [1],
        },
        {
          receiptType: [Burn],
          txStatus: [1],
        },
      ],
    )

    // The same but with different event registration order
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "Burn",
              kind: Burn,
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              name: "Burn",
              kind: Burn,
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [
        {
          receiptType: [Burn],
          rootContractId: [address3],
          txStatus: [1],
        },
        {
          receiptType: [Burn],
          txStatus: [1],
        },
      ],
    )
  })

  it("Removes wildcard selection with shouldApplyWildcards (needed for partitioning)", () => {
    let getRecieptsSelection = mock(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "Mint",
              kind: Mint,
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
            {
              name: "Burn",
              kind: Burn,
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
            {
              name: "WildcardLog",
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
            {
              name: "NonWildcardLog",
              kind: LogData({
                logId: "2",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
              handler: None,
              loader: None,
              contractRegister: None,
              paramsRawEventSchema: %raw(`"Not relevat"`),
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [
        {
          rb: [2n],
          receiptType: [LogData],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
        {
          receiptType: [Mint, Burn],
          txStatus: [1],
        },
        {
          rb: [1n],
          receiptType: [LogData],
          txStatus: [1],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelection(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=false,
      ),
      [
        {
          rb: [2n],
          receiptType: [LogData],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
      ],
    )
  })
})
