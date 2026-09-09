// Selection-bitmask helpers shared by the per-chain field stores
// (`TransactionStore`, `BlockStore`). A field's bit index is its position in the
// ecosystem's ordered field-name array — the same code the Rust store uses.

// Field-name → bit-index map from an ordered field-name array.
let fieldCodes = (fields: array<string>): dict<int> => {
  let codes = Dict.make()
  fields->Array.forEachWithIndex((name, i) => codes->Dict.set(name, i))
  codes
}

let pow2: int => float = %raw(`c => Math.pow(2, c)`)

// One event's selected fields as a bitmask float (bit `code` set ⇔ selected).
// Each field appears once, so summing `pow2(code)` sets distinct bits with no
// overlap; the result stays exact in f64 (codes span 0..31, so a mask is at most
// 2^32-1).
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

// Bitwise OR of two per-event masks. Masks fit in 32 bits (≤32 fields), so
// `>>> 0` recovers the unsigned value that a plain `|` renders negative once bit
// 31 is set.
let orMask: (float, float) => float = %raw(`(a, b) => (a | b) >>> 0`)
