open RescriptMocha

describe_only("HyperFuelWorker - getRecieptsSelectionOrThrow", () => {
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
              // LogId is ignored for mint events
              logId: "12345",
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
              // LogId is ignored for mint events
              logId: "12345",
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
          rb: [10732353433239600734n],
          receiptType: [LogData],
          rootContractId: [address1, address2],
          txStatus: [1],
        },
        {
          receiptType: [Mint],
          rootContractId: [address3],
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

  it("Fails with invalid event config", () => {
    Assert.throws(
      () => {
        HyperFuelWorker.makeGetRecieptsSelectionOrThrow(
          ~contracts=[
            {
              name: "TestContract",
              events: [
                {
                  name: "NoLogIdOrMintSpecified",
                },
              ],
            },
          ],
        )
      },
      ~error={
        "message": "Event NoLogIdOrMintSpecified is not a mint or log",
      },
    )
  })
})
