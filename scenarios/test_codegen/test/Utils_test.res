open RescriptMocha

type arecord = {a: int}
type logLike = {blockNum: int, logIndex: int}

describe("Merge Sorted", () => {
  it("sorts integers based on identity", () => {
    Assert.deepEqual(
      [1, 2, 3, 4, 6, 7, 8, 10, 13, 19],
      Utils.Array.mergeSorted((a, b) => a <= b, [1, 3, 7, 13, 19], [2, 4, 6, 8, 10]),
    )
  })

  it("sorts records based on a comparable key", () => {
    Assert.deepEqual(
      [{a: 1}, {a: 2}, {a: 3}],
      Utils.Array.mergeSorted((x, y) => x.a <= y.a, [{a: 1}, {a: 3}], [{a: 2}]),
    )
  })

  it("sorts log-like items", () => {
    Assert.deepEqual(
      [{blockNum: 1, logIndex: 0}, {blockNum: 1, logIndex: 2}, {blockNum: 2, logIndex: 0}],
      Utils.Array.mergeSorted(
        (x, y) => (x.blockNum, x.logIndex) <= (y.blockNum, y.logIndex),
        [{blockNum: 1, logIndex: 0}, {blockNum: 2, logIndex: 0}],
        [{blockNum: 1, logIndex: 2}],
      ),
    )
  })

  it("does not allocate in degenerate cases", () => {
    let left = [1, 3, 7, 13, 19]
    let right = [2, 4, 6, 8, 10]
    Assert.strictEqual(left, Utils.Array.mergeSorted((x, y) => x <= y, left, []))
    Assert.strictEqual(right, Utils.Array.mergeSorted((x, y) => x <= y, [], right))
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

describe("Hash", () => {
  it("string", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow("hello"), `"hello"`)
  })

  it("number", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(123), `123`)
  })

  it("boolean", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(true), `true`)
    Assert.deepEqual(Utils.Hash.makeOrThrow(false), `false`)
  })

  it("null", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(%raw(`null`)), `null`)
  })

  it("array", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(%raw(`[1,2,true]`)), `[1,2,true]`)
  })

  it("object", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(%raw(`{a:1,b:2,}`)), `{"a":1,"b":2}`)
    Assert.deepEqual(
      Utils.Hash.makeOrThrow(%raw(`{b:2,a:1,}`)),
      `{"a":1,"b":2}`,
      ~message="Order of keys should not matter",
    )
  })

  it("object with undefined field", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(%raw(`{a:1,b:undefined,c:3}`)), `{"a":1,"c":3}`)
    Assert.deepEqual(Utils.Hash.makeOrThrow(%raw(`{a:undefined,b:2,c:3}`)), `{"b":2,"c":3}`)
  })

  it("bigint", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(%raw(`BigInt(123)`)), `"123"`)
  })

  it("bigdecimal", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(BigDecimal.fromString("123")), `"123"`)
  })

  it("set", () => {
    Assert.throws(
      () => {
        Utils.Hash.makeOrThrow(Utils.Set.fromArray(["1", "2"]))
      },
      ~error={
        "message": `Failed to get hash for Set. If you're using a custom Sury schema make it based on the string type with a decoder: const myTypeSchema = S.transform(S.string, undefined, (yourType) => yourType.toString())`,
      },
    )
  })

  it("symbol", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(%raw(`Symbol("hello")`)), `Symbol(hello)`)
  })

  it("function", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(%raw(`function() {}`)), `function () { }`)
  })

  it("undefined", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(%raw(`undefined`)), `null`)
  })

  it("nested object", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(%raw(`{a: {b: 1}}`)), `{"a":{"b":1}}`)
  })

  it("nested array", () => {
    Assert.deepEqual(Utils.Hash.makeOrThrow(%raw(`[1, [2, 3]]`)), `[1,[2,3]]`)
  })
})
