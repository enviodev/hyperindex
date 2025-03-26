open RescriptMocha

describe("Copy on write", () => {
  it("Should not copy without mutation", () => {
    let arr = [1, 2, 3]
    let cowA = arr->Cow.Array.make
    let cowB = cowA->Cow.copy

    Assert.ok(
      cowA->Cow.getDataRef === cowB->Cow.getDataRef && cowA->Cow.getDataRef === arr,
      ~message="Should be a reference to the same array",
    )

    cowB->Cow.Array.push(4)

    let cowBRefA = cowB->Cow.getDataRef

    Assert.ok(
      cowA->Cow.getDataRef === arr && arr !== cowB->Cow.getDataRef,
      ~message="Should be a new array after mutation",
    )

    cowB->Cow.Array.push(5)
    Assert.ok(
      cowB->Cow.getDataRef === cowBRefA,
      ~message="Should continue to be the same ref after mutation",
    )

    let cowC = cowB->Cow.copy

    Assert.ok(
      cowB->Cow.getDataRef === cowC->Cow.getDataRef,
      ~message="Should be the same ref after copy",
    )

    cowB->Cow.Array.push(6)
    Assert.ok(
      cowB->Cow.getDataRef !== cowC->Cow.getDataRef,
      ~message="Should not be the same ref after mutation",
    )
    Assert.ok(
      cowC->Cow.getDataRef === cowBRefA,
      ~message="See still has the original ref when it was copied",
    )

    Assert.deepEqual(cowA->Cow.getData, arr)
    Assert.deepEqual(cowB->Cow.getData, [1, 2, 3, 4, 5, 6])
    Assert.deepEqual(cowC->Cow.getData, [1, 2, 3, 4, 5])
  })
})
