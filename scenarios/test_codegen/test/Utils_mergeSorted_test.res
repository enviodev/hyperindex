open Ava

type arecord = {a: int}
type logLike = {blockNum: int, logIndex: int}

test("Sorts integers based on identity", (. t) => {
  t->Assert.deepEqual(.
    [1, 2, 3, 4, 6, 7, 8, 10, 13, 19],
    Utils.mergeSorted(x => x, [1, 3, 7, 13, 19], [2, 4, 6, 8, 10]),
  )
})

test("Sorts records based on a comparable key", (. t) => {
  t->Assert.deepEqual(.
    [{a: 1}, {a: 2}, {a: 3}],
    Utils.mergeSorted(x => x.a, [{a: 1}, {a: 3}], [{a: 2}]),
  )
})

test("Sorts log-like items", (. t) => {
  t->Assert.deepEqual(.
    [{blockNum: 1, logIndex: 0}, {blockNum: 1, logIndex: 2}, {blockNum: 2, logIndex: 0}],
    Utils.mergeSorted(
      x => (x.blockNum, x.logIndex),
      [{blockNum: 1, logIndex: 0}, {blockNum: 2, logIndex: 0}],
      [{blockNum: 1, logIndex: 2}],
    ),
  )
})

test("Does not allocate in degenerate cases", (. t) => {
  let left = [1, 3, 7, 13, 19]
  let right = [2, 4, 6, 8, 10]
  t->Assert.deepEqual(. left, Utils.mergeSorted(x => x, left, []))
  t->Assert.deepEqual(. right, Utils.mergeSorted(x => x, [], right))
})
