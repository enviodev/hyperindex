open Vitest

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
  it("flat encodes some type", t => {
    t.expect(mock1->S.reverseConvertToJsonStringOrThrow(testRecordSchema)).toEqual(mock1raw)
  })
  it("encodes None as null", t => {
    // TODO: Test if it's a problem not to send null
    t.expect(mock2->S.reverseConvertToJsonStringOrThrow(testRecordSchema)).toEqual(mock3raw)
  })
  it("decodes null as None", t => {
    t.expect(mock2raw->S.parseJsonStringOrThrow(testRecordSchema)).toEqual(mock2)
  })
  it("decodes undefined as None", t => {
    t.expect(mock3raw->S.parseJsonStringOrThrow(testRecordSchema)).toEqual(mock2)
  })
  it("decodes val as Some", t => {
    t.expect(mock1raw->S.parseJsonStringOrThrow(testRecordSchema)).toEqual(mock1)
  })
})
