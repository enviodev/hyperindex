open RescriptMocha

type testRecord = {optNumber: option<int>}
let testRecordSchema = S.object(s => {
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
    Assert.deepEqual(mock1->S.reverseConvertToJsonStringWith(testRecordSchema), mock1raw)
  })
  it("encodes None as null", () => {
    // TODO: Test if it's a problem not to send null
    Assert.deepEqual(mock2->S.reverseConvertToJsonStringWith(testRecordSchema), mock3raw)
  })
  it("decodes null as None", () => {
    Assert.deepEqual(mock2raw->S.parseJsonStringWith(testRecordSchema), Ok(mock2))
  })
  it("decodes undefined as None", () => {
    Assert.deepEqual(mock3raw->S.parseJsonStringWith(testRecordSchema), Ok(mock2))
  })
  it("decodes val as Some", () => {
    Assert.deepEqual(mock1raw->S.parseJsonStringWith(testRecordSchema), Ok(mock1))
  })
})
