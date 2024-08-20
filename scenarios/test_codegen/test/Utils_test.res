open RescriptMocha

type arecord = {a: int}
type logLike = {blockNum: int, logIndex: int}

describe("Merge Sorted", () => {
  it("sorts integers based on identity", () => {
    Assert.deepEqual(
      [1, 2, 3, 4, 6, 7, 8, 10, 13, 19],
      Utils.mergeSorted((a, b) => a <= b, [1, 3, 7, 13, 19], [2, 4, 6, 8, 10]),
    )
  })

  it("sorts records based on a comparable key", () => {
    Assert.deepEqual(
      [{a: 1}, {a: 2}, {a: 3}],
      Utils.mergeSorted((x, y) => x.a <= y.a, [{a: 1}, {a: 3}], [{a: 2}]),
    )
  })

  it("sorts log-like items", () => {
    Assert.deepEqual(
      [{blockNum: 1, logIndex: 0}, {blockNum: 1, logIndex: 2}, {blockNum: 2, logIndex: 0}],
      Utils.mergeSorted(
        (x, y) => (x.blockNum, x.logIndex) <= (y.blockNum, y.logIndex),
        [{blockNum: 1, logIndex: 0}, {blockNum: 2, logIndex: 0}],
        [{blockNum: 1, logIndex: 2}],
      ),
    )
  })

  it("does not allocate in degenerate cases", () => {
    let left = [1, 3, 7, 13, 19]
    let right = [2, 4, 6, 8, 10]
    Assert.strictEqual(left, Utils.mergeSorted((x, y) => x <= y, left, []))
    Assert.strictEqual(right, Utils.mergeSorted((x, y) => x <= y, [], right))
  })
})

describe("Array removeIndex", () => {
  it("array of length 1", () => {
    let arr = [1]
    Assert.deepEqual(
      arr->Utils.Array.removeAtIndex(0),
      [],
      ~message="Should have removed single value",
    )
    Assert.deepEqual(arr, [1], ~message="Original array should not have changed")
  })

  it("array of length 0", () => {
    let arr = []
    Assert.deepEqual(arr->Utils.Array.removeAtIndex(0), [], ~message="Should remain empty")
    Assert.deepEqual(arr, [], ~message="Original array should not have changed")
  })

  it("happy case", () => {
    let arr = [1, 2, 3]
    Assert.deepEqual(arr->Utils.Array.removeAtIndex(1), [1, 3])
    Assert.deepEqual(arr, [1, 2, 3], ~message="Original array should not have changed")
  })

  it("index out of bounds", () => {
    let arr = [1, 2, 3]
    Assert.deepEqual(arr->Utils.Array.removeAtIndex(3), [1, 2, 3])
  })

  it("negative index", () => {
    let arr = [1, 2, 3]
    Assert.deepEqual(arr->Utils.Array.removeAtIndex(-2), [1, 2, 3])
  })
})
