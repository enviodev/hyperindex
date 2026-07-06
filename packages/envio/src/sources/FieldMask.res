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

// Group store-backed items sharing a key, in arrival order, by extending the
// current run when the key repeats adjacently rather than hashing a key per
// item — safe because store-backed items arrive already sorted by their group
// key, so equal keys are adjacent; a key recurring non-adjacently just splits
// into two groups (one redundant decode later), never incorrect. Items whose
// payload already carries an inline value (`hasInline`, e.g. RPC/simulate/Fuel)
// are skipped. Each group's mask is the OR of its items' individual masks.
// `sameKey` is taken explicitly (rather than relying on `==` over `'key`)
// so callers with a tuple key compare its components, not the tuple itself.
let groupAdjacent = (
  items: array<Internal.item>,
  ~hasInline: Internal.eventPayload => bool,
  ~key: Internal.eventItem => 'key,
  ~sameKey: ('key, 'key) => bool,
  ~mask: Internal.eventItem => float,
): (array<'key>, array<float>, array<array<Internal.eventItem>>) => {
  let keys = []
  let masks = []
  let groups = []
  items->Array.forEach(item =>
    switch item {
    | Internal.Event(_) =>
      let eventItem = item->Internal.castUnsafeEventItem
      if !(eventItem.payload->hasInline) {
        let k = eventItem->key
        let m = eventItem->mask
        let last = groups->Array.length - 1
        if last >= 0 && keys->Array.getUnsafe(last)->sameKey(k) {
          groups->Array.getUnsafe(last)->Array.push(eventItem)
          masks->Array.setUnsafe(last, orMask(masks->Array.getUnsafe(last), m))
        } else {
          keys->Array.push(k)
          masks->Array.push(m)
          groups->Array.push([eventItem])
        }
      }
    | Internal.Block(_) => ()
    }
  )
  (keys, masks, groups)
}
