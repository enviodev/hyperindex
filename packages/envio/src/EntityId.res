// Opaque representation of an entity id. The generated per-entity types expose
// the real scalar (string / int / bigint / Uint8Array); the generic storage and in-memory
// layers work with any entity's id through this type without knowing which
// scalar backs it. The runtime value is always the real id, never a stringified
// form — `toKey` derives the string only where a JS object/dict key is needed.
type t

external unsafeOfAny: 'a => t = "%identity"
external unsafeToAny: t => 'a = "%identity"
external unsafeOfString: string => t = "%identity"

// Stringified id used as a JS object/dict key. Every keyed lookup goes through
// this rather than letting JS coerce the raw id: a Uint8Array keys as its hex
// bytes, so two arrays holding the same bytes share a key. `String` would get
// that wrong for a `Buffer`, which stringifies by decoding UTF-8, so distinct
// byte sequences can collide and the same bytes key differently from a plain
// Uint8Array.
let toKey = (id: t): string =>
  switch id->(Utils.magic: t => unknown)->Utils.Bytes.asUint8Array {
  | Some(bytes) => bytes->Utils.Bytes.toHex
  | None => id->(Utils.magic: t => unknown)->String.make
  }
