open RescriptMocha
open Mocha

type arecord = {a: int}
type logLike = {blockNum: int, logIndex: int}

describe("Merge Sorted", () => {
  it("sorts integers based on identity", () => {
    Assert.deep_equal(
      [1, 2, 3, 4, 6, 7, 8, 10, 13, 19],
      Utils.mergeSorted(x => x, [1, 3, 7, 13, 19], [2, 4, 6, 8, 10]),
    )
  })

  it("sorts records based on a comparable key", () => {
    Assert.deep_equal(
      [{a: 1}, {a: 2}, {a: 3}],
      Utils.mergeSorted(x => x.a, [{a: 1}, {a: 3}], [{a: 2}]),
    )
  })

  it("sorts log-like items", () => {
    Assert.deep_equal(
      [{blockNum: 1, logIndex: 0}, {blockNum: 1, logIndex: 2}, {blockNum: 2, logIndex: 0}],
      Utils.mergeSorted(
        x => (x.blockNum, x.logIndex),
        [{blockNum: 1, logIndex: 0}, {blockNum: 2, logIndex: 0}],
        [{blockNum: 1, logIndex: 2}],
      ),
    )
  })

  it("does not allocate in degenerate cases", () => {
    let left = [1, 3, 7, 13, 19]
    let right = [2, 4, 6, 8, 10]
    Assert.strict_equal(left, Utils.mergeSorted(x => x, left, []))
    Assert.strict_equal(right, Utils.mergeSorted(x => x, [], right))
  })
})
