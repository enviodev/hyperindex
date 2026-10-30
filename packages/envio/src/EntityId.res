// Opaque representation of an entity id. The generated per-entity types expose
// the real scalar (string / int / bigint / Uint8Array); the generic storage and in-memory
// layers work with any entity's id through this type without knowing which
// scalar backs it. The runtime value is always the real id, never a stringified
// form — `Table.idKey` derives the string only where a dict or Set key is needed.
type t

external unsafeOfAny: 'a => t = "%identity"
external unsafeToAny: t => 'a = "%identity"
external unsafeOfString: string => t = "%identity"
