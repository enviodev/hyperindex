type t

type mode = | @as("int32") Int32 | @as("int64") Int64

let modeSchema: S.t<mode>

let maxSafe: float

external fromInt: int => t = "%identity"
external toInt: t => int = "%identity"
external toFloat: t => float = "%identity"

let toString: t => string
let compare: (t, t) => float
let equal: (t, t) => bool

let schema: S.t<t>

// The same runtime schema, typed for the modules that still annotate chain ids
// as `int`. Safe because ReScript's `int` is a JS number at runtime — chain ids
// are only ever compared and stringified, never used in int32 arithmetic.
let intSchema: S.t<int>

// Postgres returns BIGINT columns as strings, so raw (schema-less) reads of a
// chain-id column go through this instead of trusting the driver's type.
let normalizeOrThrow: 'a => t
