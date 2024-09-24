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
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
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
          rb: [1n],
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
              kind: Mint,
              isWildcard: false,
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
              kind: Mint,
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
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
            },
            {
              name: "BoolLog",
              kind: LogData({
                logId: "2",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
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
          rb: [1n, 2n, 3n],
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
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
            },
            {
              name: "BoolLog",
              kind: LogData({
                logId: "2",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
            },
            {
              name: "Mint",
              kind: Mint,
              isWildcard: false,
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
          rb: [1n],
          receiptType: [LogData],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
        {
          rb: [3n],
          receiptType: [LogData],
          rootContractId: [address3],
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
                  kind: Mint,
                  isWildcard: false
                },
                {
                  name: "MyEvent2",
                  kind: Mint,
                  isWildcard: false
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
                  kind: Mint,
                  isWildcard: true,
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
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Failed to register Mint for contract TestContract2 because Mint is already registered in wildcard mode",
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
                  kind: Mint,
                  isWildcard: false,
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
              kind: Mint,
              isWildcard: true,
            },
            {
              name: "WildcardLog",
              kind: LogData({
                logId: "1",
                decode: _ => %raw(`null`),
              }),
              isWildcard: true,
            },
            {
              name: "NonWildcardLog",
              kind: LogData({
                logId: "2",
                decode: _ => %raw(`null`),
              }),
              isWildcard: false,
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
          rb: [2n],
          receiptType: [LogData],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
        {
          receiptType: [Mint],
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
      getRecieptsSelectionOrThrow(
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
