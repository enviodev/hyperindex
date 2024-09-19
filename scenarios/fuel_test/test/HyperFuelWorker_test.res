open RescriptMocha

describe_only("HyperFuelWorker - getRecieptsSelectionOrThrow", () => {
  it("Receipts Selection with no contracts", () => {
    let getRecieptsSelectionOrThrow = HyperFuelWorker.makeGetRecieptsSelectionOrThrow(~contracts=[])
    Assert.deepEqual(
      getRecieptsSelectionOrThrow(
        ~contractAddressMapping=ContractAddressingMap.make(),
        ~shouldApplyWildcards=true,
      ),
      [],
    )
  })
})
