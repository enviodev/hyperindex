type t

type mode = | @as("int32") Int32 | @as("int64") Int64

let modeSchema: S.t<mode>

// Escapes for the boundaries that stay `int`: the handler-facing
// `context.chain.id` / `Envio.effectChain.id`, and int literals in configs and
// tests. Both are the identity at runtime — an `int` is already a JS number.
external fromInt: int => t = "%identity"
external toInt: t => int = "%identity"

let toString: t => string
let compare: (t, t) => int

let schema: S.t<t>

// Dicts keyed by chain id. JS coerces the number key to its decimal string,
// which is exactly what `toString` produces, so the two key forms interoperate.
module Dict: {
  @get_index external dangerouslyGetNonOption: (dict<'a>, t) => option<'a> = ""
  @set_index external set: (dict<'a>, t, 'a) => unit = ""
}

// Postgres returns BIGINT columns as strings, so raw (schema-less) reads of a
// chain-id column go through this instead of trusting the driver's type.
let normalizeOrThrow: 'a => t
