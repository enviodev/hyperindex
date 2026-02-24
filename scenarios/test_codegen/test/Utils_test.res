open Vitest

type arecord = {a: int}
type logLike = {blockNum: int, logIndex: int}

describe("Merge Sorted", () => {
  it("sorts integers based on identity", t => {
    t.expect(
      Utils.Array.mergeSorted((a, b) => a <= b, [1, 3, 7, 13, 19], [2, 4, 6, 8, 10]),
    ).toEqual(
      [1, 2, 3, 4, 6, 7, 8, 10, 13, 19],
    )
  })

  it("sorts records based on a comparable key", t => {
    t.expect(
      Utils.Array.mergeSorted((x, y) => x.a <= y.a, [{a: 1}, {a: 3}], [{a: 2}]),
    ).toEqual(
      [{a: 1}, {a: 2}, {a: 3}],
    )
  })

  it("sorts log-like items", t => {
    t.expect(
      Utils.Array.mergeSorted(
        (x, y) => (x.blockNum, x.logIndex) <= (y.blockNum, y.logIndex),
        [{blockNum: 1, logIndex: 0}, {blockNum: 2, logIndex: 0}],
        [{blockNum: 1, logIndex: 2}],
      ),
    ).toEqual(
      [{blockNum: 1, logIndex: 0}, {blockNum: 1, logIndex: 2}, {blockNum: 2, logIndex: 0}],
    )
  })

  it("does not allocate in degenerate cases", t => {
    let left = [1, 3, 7, 13, 19]
    let right = [2, 4, 6, 8, 10]
    t.expect(Utils.Array.mergeSorted((x, y) => x <= y, left, [])).toBe(left)
    t.expect(Utils.Array.mergeSorted((x, y) => x <= y, [], right)).toBe(right)
  })
})

describe("Array removeIndex", () => {
  it("array of length 1", t => {
    let arr = [1]
    t.expect(
      arr->Utils.Array.removeAtIndex(0),
      ~message="Should have removed single value",
    ).toEqual(
      [],
    )
    t.expect(arr, ~message="Original array should not have changed").toEqual([1])
  })

  it("array of length 0", t => {
    let arr = []
    t.expect(arr->Utils.Array.removeAtIndex(0), ~message="Should remain empty").toEqual([])
    t.expect(arr, ~message="Original array should not have changed").toEqual([])
  })

  it("happy case", t => {
    let arr = [1, 2, 3]
    t.expect(arr->Utils.Array.removeAtIndex(1)).toEqual([1, 3])
    t.expect(arr, ~message="Original array should not have changed").toEqual([1, 2, 3])
  })

  it("index out of bounds", t => {
    let arr = [1, 2, 3]
    t.expect(arr->Utils.Array.removeAtIndex(3)).toEqual([1, 2, 3])
  })

  it("negative index", t => {
    let arr = [1, 2, 3]
    t.expect(arr->Utils.Array.removeAtIndex(-2)).toEqual([1, 2, 3])
  })
})

describe("Hash", () => {
  it("string", t => {
    t.expect(Utils.Hash.makeOrThrow("hello")).toEqual(`"hello"`)
  })

  it("number", t => {
    t.expect(Utils.Hash.makeOrThrow(123)).toEqual(`123`)
  })

  it("boolean", t => {
    t.expect(Utils.Hash.makeOrThrow(true)).toEqual(`true`)
    t.expect(Utils.Hash.makeOrThrow(false)).toEqual(`false`)
  })

  it("null", t => {
    t.expect(Utils.Hash.makeOrThrow(%raw(`null`))).toEqual(`null`)
  })

  it("array", t => {
    t.expect(Utils.Hash.makeOrThrow(%raw(`[1,2,true]`))).toEqual(`[1,2,true]`)
  })

  it("object", t => {
    t.expect(Utils.Hash.makeOrThrow(%raw(`{a:1,b:2,}`))).toEqual(`{"a":1,"b":2}`)
    t.expect(
      Utils.Hash.makeOrThrow(%raw(`{b:2,a:1,}`)),
      ~message="Order of keys should not matter",
    ).toEqual(
      `{"a":1,"b":2}`,
    )
  })

  it("object with undefined field", t => {
    t.expect(Utils.Hash.makeOrThrow(%raw(`{a:1,b:undefined,c:3}`))).toEqual(`{"a":1,"c":3}`)
    t.expect(Utils.Hash.makeOrThrow(%raw(`{a:undefined,b:2,c:3}`))).toEqual(`{"b":2,"c":3}`)
  })

  it("bigint", t => {
    t.expect(Utils.Hash.makeOrThrow(%raw(`BigInt(123)`))).toEqual(`"123"`)
  })

  it("bigdecimal", t => {
    t.expect(Utils.Hash.makeOrThrow(BigDecimal.fromString("123"))).toEqual(`"123"`)
  })

  it("set", t => {
    t.expect(
      () => {
        Utils.Hash.makeOrThrow(Utils.Set.fromArray(["1", "2"]))
      },
    ).toThrowError(`Failed to get hash for Set. If you're using a custom rescript-schema schema make it based on the string type with a decoder: const myTypeSchema = S.transform(S.string, undefined, (yourType) => yourType.toString())`)
  })

  it("symbol", t => {
    t.expect(Utils.Hash.makeOrThrow(%raw(`Symbol("hello")`))).toEqual(`Symbol(hello)`)
  })

  it("function", t => {
    t.expect(Utils.Hash.makeOrThrow(%raw(`function() {}`))).toEqual(`function() {}`)
  })

  it("undefined", t => {
    t.expect(Utils.Hash.makeOrThrow(%raw(`undefined`))).toEqual(`null`)
  })

  it("nested object", t => {
    t.expect(Utils.Hash.makeOrThrow(%raw(`{a: {b: 1}}`))).toEqual(`{"a":{"b":1}}`)
  })

  it("nested array", t => {
    t.expect(Utils.Hash.makeOrThrow(%raw(`[1, [2, 3]]`))).toEqual(`[1,[2,3]]`)
  })
})
