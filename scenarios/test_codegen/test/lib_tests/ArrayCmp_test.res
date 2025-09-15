open RescriptMocha

describe_only("Array cmp tests", () => {
  it("same arr is eq", () => {
    let arr = [1, 2, 3]
    let arr2 = [1, 2, 3]
    Utils.Array.int.eq(arr, arr2)->Assert.ok
    Utils.Array.int.cmp(arr, arr2)->Assert.deepEqual(0)
  })

  it("handles empty arrays", () => {
    let arr = []
    let arr2 = []
    Utils.Array.int.eq(arr, arr2)->Assert.ok(~message="empty arrays should be equal")
    let arr3 = [1, 2, 3]
    Utils.Array.int.lt(arr, arr3)->Assert.ok(~message="empty arrays should be less than non-empty")
  })

  it("handles different length arrays", () => {
    let arr = [1, 2, 3]
    let arr2 = [1, 2]
    Utils.Array.int.gt(arr, arr2)->Assert.ok(~message="same array but longer should be greater")

    let arr = [1, 2, 3]
    let arr2 = [3, 1]
    Utils.Array.int.lt(arr, arr2)->Assert.ok(
      ~message="items in array should take precedence over length",
    )
  })

  it("handles ordering correctly", () => {
    let arr = [20, 10, 3]
    let arr2 = [19, 10, 3]
    Utils.Array.int.gt(arr, arr2)->Assert.ok(~message="should be greater on first item")
    let arr2 = [20, 9, 3]
    Utils.Array.int.gt(arr, arr2)->Assert.ok(~message="should be greater on second item")
    let arr2 = [20, 10, 2]
    Utils.Array.int.gt(arr, arr2)->Assert.ok(~message="should be greater on third item")
  })
})

describe_only("Tuple cmp tests", () => {
  it("equality works", () => {
    let tuple1 = (1, 2, 3)
    let tuple2 = (1, 2, 3)
    Utils.Tuple.int3.eq(tuple1, tuple2)->Assert.ok(~message="should be equal")
    let tuple2 = (1, 2, 4)
    Utils.Tuple.int3.eq(tuple1, tuple2)->not->Assert.ok(~message="should not be equal")
  })

  it("cmp works", () => {
    let tuple1 = (1, 2, 3)
    let tuple2 = (1, 2, 3)
    Utils.Tuple.int3.cmp(tuple1, tuple2)->Assert.deepEqual(0, ~message="should be equal")
    let tuple2 = (1, 2, 2)
    Utils.Tuple.int3.cmp(tuple1, tuple2)->Assert.deepEqual(1, ~message="should be positive")
    let tuple2 = (1, 2, 4)
    Utils.Tuple.int3.cmp(tuple1, tuple2)->Assert.deepEqual(-1, ~message="should be negative")
  })
})
