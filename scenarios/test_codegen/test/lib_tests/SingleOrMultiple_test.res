open Vitest
module SingleOrMultiple = Indexer.SingleOrMultiple
type tupleWithArrays = (array<bigint>, array<string>)

describe("Single or Multiple", () => {
  it("Single nested", t => {
    let tupleWithArrays: tupleWithArrays = ([1n, 2n], ["test", "test2"])
    let single: SingleOrMultiple.t<tupleWithArrays> = SingleOrMultiple.single(tupleWithArrays)
    let multiple: SingleOrMultiple.t<tupleWithArrays> = SingleOrMultiple.multiple([tupleWithArrays])

    let expectedNormalized = [tupleWithArrays]

    let normalizedSingle = SingleOrMultiple.normalizeOrThrow(single, ~nestedArrayDepth=2)
    let normalizedMultiple = SingleOrMultiple.normalizeOrThrow(multiple, ~nestedArrayDepth=2)

    t.expect(
      multiple->Utils.magic,
      ~message="Multiple should be the same as normalized",
    ).toEqual(expectedNormalized)
    t.expect(normalizedSingle, ~message="Single should be normalized").toEqual(expectedNormalized)
    t.expect(
      normalizedMultiple,
      ~message="Multiple should be normalized",
    ).toEqual(expectedNormalized)
  })
})
