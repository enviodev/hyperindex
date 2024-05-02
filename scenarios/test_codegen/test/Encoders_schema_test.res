open RescriptMocha
open Mocha

type testRecord = {optNumber: option<int>}
let testRecordSchema = S.object((. s) => {
  optNumber: s.field("optNumber", S.nullable(S.int)),
})

describe("nullable encodes and decodes successfully", () => {
  let mock1 = {
    optNumber: Some(1),
  }
  let mock2 = {
    optNumber: None,
  }

  let mock1raw = `{"optNumber":1}`
  let mock2raw = `{"optNumber":null}`
  let mock3raw = `{}`
  it("flat encodes some type", () => {
    Assert.deep_equal(mock1->S.serializeToJsonStringWith(. testRecordSchema), Ok(mock1raw))
  })
  it("encodes None as null", () => {
    // TODO: Test if it's a problem not to send null
    Assert.deep_equal(mock2->S.serializeToJsonStringWith(. testRecordSchema), Ok(mock3raw))
  })
  it("decodes null as None", () => {
    Assert.deep_equal(mock2raw->S.parseJsonStringWith(. testRecordSchema), Ok(mock2))
  })
  it("decodes undefined as None", () => {
    Assert.deep_equal(mock3raw->S.parseJsonStringWith(. testRecordSchema), Ok(mock2))
  })
  it("decodes val as Some", () => {
    Assert.deep_equal(mock1raw->S.parseJsonStringWith(. testRecordSchema), Ok(mock1))
  })
})
