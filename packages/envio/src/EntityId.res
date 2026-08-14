// Opaque representation of an entity id. The generated per-entity types expose
// the real scalar (string / int / bigint); the generic storage and in-memory
// layers work with any entity's id through this type without knowing which
// scalar backs it. The runtime value is always the real id, never a stringified
// form — `toKey` derives the string only where a JS object/dict key is needed.
type t

external unsafeOfAny: 'a => t = "%identity"
external unsafeToAny: t => 'a = "%identity"
external unsafeOfString: string => t = "%identity"

// Stringified id used as a JS object/dict key. `String` matches how JS coerces
// a value used as an object key, so an id indexes the same whether the raw
// value or its key form is used for lookup, across string/int/bigint.
let toKey: t => string = %raw(`String`)
