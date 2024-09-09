open RescriptMocha
module SingleOrMultiple = Types.SingleOrMultiple
type tupleWithArrays = (array<bigint>, array<string>)

describe("Single or Multiple", () => {
  it("Single nested", () => {
    let tupleWithArrays: tupleWithArrays = ([1n, 2n], ["test", "test2"])
    let single: SingleOrMultiple.t<tupleWithArrays> = SingleOrMultiple.single(tupleWithArrays)
    let multiple: SingleOrMultiple.t<tupleWithArrays> = SingleOrMultiple.multiple([tupleWithArrays])

    let expectedNormalized = [tupleWithArrays]

    let normalizedSingle = SingleOrMultiple.normalizeOrThrow(single, ~nestedArrayDepth=2)
    let normalizedMultiple = SingleOrMultiple.normalizeOrThrow(multiple, ~nestedArrayDepth=2)

    Assert.deepEqual(
      multiple->Utils.magic,
      expectedNormalized,
      ~message="Multiple should be the same as normalized",
    )
    Assert.deepEqual(normalizedSingle, expectedNormalized, ~message="Single should be normalized")
    Assert.deepEqual(
      normalizedMultiple,
      expectedNormalized,
      ~message="Multiple should be normalized",
    )
  })
})
