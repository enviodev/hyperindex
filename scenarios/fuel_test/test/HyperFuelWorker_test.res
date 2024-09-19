open RescriptMocha

describe("HyperFuelWorker - getRecieptsSelectionOrThrow", () => {
  let contractName1 = "TestContract"
  let contractName2 = "TestContract2"
  let address1 = Address.unsafeFromString("0x1234567890abcdef1234567890abcdef1234567890abcde1")
  let address2 = Address.unsafeFromString("0x1234567890abcdef1234567890abcdef1234567890abcde2")
  let address3 = Address.unsafeFromString("0x1234567890abcdef1234567890abcdef1234567890abcde3")

  let mockContractAddressMapping = () => {
    ContractAddressingMap.fromArray([
      (address1, contractName1),
      (address2, contractName1),
      (address3, contractName2),
    ])
  }

  it("Receipts Selection with no contracts", () => {
    let getRecieptsSelectionOrThrow = HyperFuelWorker.makeGetRecieptsSelectionOrThrow(~contracts=[])
    Assert.deepEqual(
      getRecieptsSelectionOrThrow(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [],
    )
  })

  it("Receipts Selection with no events", () => {
    let getRecieptsSelectionOrThrow = HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
      ~contracts=[
        {
          name: "TestContract",
          events: [],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelectionOrThrow(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [],
    )
  })

  it("Receipts Selection with single non-wildcard log event", () => {
    let getRecieptsSelectionOrThrow = HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "StrLog",
              logId: Types.AllEvents.StrLog.sighash,
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelectionOrThrow(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [
        {
          rb: [10732353433239600734n],
          receiptType: [LogData],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
      ],
    )
  })

  it("Receipts Selection with non-wildcard mint event", () => {
    let getRecieptsSelectionOrThrow = HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "Mint",
              mint: true,
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              name: "Mint",
              mint: true,
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelectionOrThrow(
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

  it("Receipts Selection with wildcard mint event", () => {
    let getRecieptsSelectionOrThrow = HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "Mint",
              mint: true,
              isWildcard: true,
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelectionOrThrow(
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

  it("Receipts Selection with multiple wildcard log event", () => {
    let getRecieptsSelectionOrThrow = HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "StrLog",
              logId: Types.AllEvents.StrLog.sighash,
              isWildcard: true,
            },
            {
              name: "BoolLog",
              logId: Types.AllEvents.BoolLog.sighash,
              isWildcard: true,
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              name: "UnitLog",
              logId: Types.AllEvents.UnitLog.sighash,
              isWildcard: true,
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelectionOrThrow(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [
        {
          rb: [10732353433239600734n, 13213829929622723620n, 3330666440490685604n],
          receiptType: [LogData],
          txStatus: [1],
        },
      ],
    )
  })

  it("Receipts Selection with all possible events together", () => {
    let getRecieptsSelectionOrThrow = HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "StrLog",
              logId: Types.AllEvents.StrLog.sighash,
            },
            {
              name: "BoolLog",
              logId: Types.AllEvents.BoolLog.sighash,
              isWildcard: true,
            },
            {
              name: "Mint",
              mint: true,
            },
          ],
        },
        {
          name: "TestContract2",
          events: [
            {
              name: "UnitLog",
              logId: Types.AllEvents.UnitLog.sighash,
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelectionOrThrow(
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
          rb: [10732353433239600734n],
          receiptType: [LogData],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
        {
          rb: [3330666440490685604n],
          receiptType: [LogData],
          rootContractId: [address3],
          txStatus: [1],
        },
        {
          rb: [13213829929622723620n],
          receiptType: [LogData],
          txStatus: [1],
        },
      ],
    )
  })

  it("Fails when event doesn't have either mint: true or logId", () => {
    Assert.throws(
      () => {
        HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  name: "MyEvent",
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Event MyEvent is not a log or mint",
      },
    )
  })

  it("Fails when event has both mint: true and logId", () => {
    Assert.throws(
      () => {
        HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  name: "MyEvent",
                  mint: true,
                  logId: "12345",
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Mint event MyEvent is not allowed to have a logId",
      },
    )
  })

  it("Fails when contract has multiple mint events", () => {
    Assert.throws(
      () => {
        HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  name: "MyEvent",
                  mint: true,
                },
                {
                  name: "MyEvent2",
                  mint: true,
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Only one Mint event is allowed per contract",
      },
    )
  })

  it("Fails when contract has mint event, when wildcard mint already defined", () => {
    Assert.throws(
      () => {
        HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  name: "Mint",
                  mint: true,
                  isWildcard: true,
                },
              ],
            },
            {
              name: "TestContract2",
              events: [
                {
                  name: "Mint",
                  mint: true,
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Failed to register Mint for contract TestContract2 because it is already registered as a wildcard",
      },
    )
  })

  it("Fails register wildcard with there's a non-wildcard mint", () => {
    Assert.throws(
      () => {
        HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
          ~contracts=[
            {
              name: "TestContract2",
              events: [
                {
                  name: "Mint",
                  mint: true,
                },
              ],
            },
            {
              name: "TestContract",
              events: [
                {
                  name: "Mint",
                  mint: true,
                  isWildcard: true,
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Wildcard Mint event is not allowed together with non-wildcard Mint events",
      },
    )
  })

  it("Removes wildcard selection with shouldApplyWildcards (needed for partitioning)", () => {
    let getRecieptsSelectionOrThrow = HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
      ~contracts=[
        {
          name: "TestContract",
          events: [
            {
              name: "Mint",
              mint: true,
              isWildcard: true,
            },
            {
              name: "WildcardLog",
              logId: "123",
              isWildcard: true,
            },
            {
              name: "NonWildcardLog",
              logId: "321",
            },
          ],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelectionOrThrow(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=true,
      ),
      [
        {
          rb: [321n],
          receiptType: [LogData],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
        {
          receiptType: [Mint],
          txStatus: [1],
        },
        {
          rb: [123n],
          receiptType: [LogData],
          txStatus: [1],
        },
      ],
    )
    Assert.deepEqual(
      getRecieptsSelectionOrThrow(
        ~contractAddressMapping=mockContractAddressMapping(),
        ~shouldApplyWildcards=false,
      ),
      [
        {
          rb: [321n],
          receiptType: [LogData],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
      ],
    )
  })
})
