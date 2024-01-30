open RescriptMocha
open Mocha
open Belt

@spice
type testRecord = {optNumber: option<int>}

describe("nullable encodes and decodes successfully", () => {
  let mock1 = {
    optNumber: Some(1),
  }
  let mock2 = {
    optNumber: None,
  }

  let mock1raw = `{"optNumber":1}`
  let mock2raw = `{"optNumber":null}`
  it("flat encodes some type", () => {
    Assert.equal(mock1->testRecord_encode->Js.Json.stringify, mock1raw)
  })

  it("encodes None as null", () => {
    Assert.equal(mock2->testRecord_encode->Js.Json.stringify, mock2raw)
  })

  it("decodes null as None", () => {
    let decoded = mock2raw->Js.Json.parseExn->testRecord_decode->Result.getExn
    Assert.deep_equal(decoded, mock2)
  })
  it("decodes val as Some", () => {
    let decoded = mock1raw->Js.Json.parseExn->testRecord_decode->Result.getExn
    Assert.deep_equal(decoded, mock1)
  })
})
