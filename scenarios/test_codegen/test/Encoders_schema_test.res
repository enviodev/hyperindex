open Ava

type testRecord = {optNumber: option<int>}
let testRecordSchema = S.object((. s) => {
  optNumber: s.field("optNumber", S.nullable(S.int)),
})

let mock1 = {
  optNumber: Some(1),
}
let mock2 = {
  optNumber: None,
}

let mock1raw = `{"optNumber":1}`
let mock2raw = `{"optNumber":null}`
let mock3raw = `{}`

// nullable encodes and decodes successfully
test("flat encodes some type", (. t) => {
  t->Assert.deepEqual(. mock1->S.serializeToJsonStringWith(. testRecordSchema), Ok(mock1raw))
})
test("encodes None as null", (. t) => {
  // TODO: Test if it's a problem not to send null
  t->Assert.deepEqual(. mock2->S.serializeToJsonStringWith(. testRecordSchema), Ok(mock3raw))
})
test("decodes null as None", (. t) => {
  t->Assert.deepEqual(. mock2raw->S.parseJsonStringWith(. testRecordSchema), Ok(mock2))
})
test("decodes undefined as None", (. t) => {
  t->Assert.deepEqual(. mock3raw->S.parseJsonStringWith(. testRecordSchema), Ok(mock2))
})
test("decodes val as Some", (. t) => {
  t->Assert.deepEqual(. mock1raw->S.parseJsonStringWith(. testRecordSchema), Ok(mock1))
})
