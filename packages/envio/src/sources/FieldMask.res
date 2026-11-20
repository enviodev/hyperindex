// Selection-bitmask helpers for the transaction and block fields an event
// selects. A field's bit index is its position in the ecosystem's ordered
// field-name array: the same code the buffer's columns use.

// Field-name → bit-index map from an ordered field-name array.
let fieldCodes = (fields: array<string>): dict<int> => {
  let codes = Dict.make()
  fields->Array.forEachWithIndex((name, i) => codes->Dict.set(name, i))
  codes
}

let pow2: int => float = %raw(`c => Math.pow(2, c)`)

// One event's selected fields as a bitmask float (bit `code` set ⇔ selected).
// Each field appears once, so summing `pow2(code)` sets distinct bits with no
// overlap; the result stays exact in f64 while every code is below 53.
let maskFromFields = (selectedFields: Utils.Set.t<string>, ~codes: dict<int>): float => {
  let mask = ref(0.)
  selectedFields->Utils.Set.forEach(name =>
    switch codes->Utils.Dict.dangerouslyGetNonOption(name) {
    | Some(code) => mask := mask.contents +. pow2(code)
    | None => ()
    }
  )
  mask.contents
}

// Build an ecosystem's per-event mask function from its ordered field-name
// array. The field codes are derived once and closed over.
let makeMaskFn = (fields: array<string>): (Utils.Set.t<string> => float) => {
  let codes = fieldCodes(fields)
  selectedFields => selectedFields->maskFromFields(~codes)
}

// Bitwise OR of two per-event masks. JS bitwise operators truncate to 32 bits,
// so the high and low halves are ORed apart; `>>> 0` keeps bit 31 unsigned.
let orMask: (float, float) => float = %raw(`(a, b) => {
  const half = 4294967296;
  const high = (Math.floor(a / half) | Math.floor(b / half)) >>> 0;
  const low = ((a % half) | (b % half)) >>> 0;
  return high * half + low;
}`)
