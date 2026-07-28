// Chain ids are identifiers, never arithmetic operands, so the runtime
// representation is a plain JS number. ReScript's `int` would cap them at
// 2^31-1, which networks like Tron Shasta (2494104990) already exceed.
type t = float

// Widest scalar the internal chain-id columns need. Resolved by the CLI from
// the maximum active chain id and carried through the public config, so a
// resume against a schema built for the other mode is rejected instead of
// silently truncating ids.
type mode = | @as("int32") Int32 | @as("int64") Int64

let modeSchema = S.enum([Int32, Int64])

// Number.MAX_SAFE_INTEGER — above this a chain id can't round-trip through
// JSON or a JS number at all.
let maxSafe = 9007199254740991.

@scope("Number") @val external isSafeInteger: float => bool = "isSafeInteger"

external fromInt: int => t = "%identity"
external toInt: t => int = "%identity"
external toFloat: t => float = "%identity"

let toString = (chainId: t) => chainId->Float.toString
let compare = (a: t, b: t) => a < b ? -1. : a > b ? 1. : 0.
let equal = (a: t, b: t) => a === b

// PostgreSQL BIGINT and ClickHouse UInt64 columns come back as strings (a
// JS number can't hold their full range), so the parser accepts both and
// range-checks the result rather than trusting the driver.
let schema: S.t<t> = S.float->S.preprocess(s => {
  parser: value => {
    let number = switch value->typeof {
    | #string => value->(Utils.magic: unknown => string)->Float.parseFloat
    | _ => value->(Utils.magic: unknown => float)
    }
    if !isSafeInteger(number) || number < 0. {
      s.fail(
        `Expected a chain id between 0 and ${maxSafe->Float.toString}, received ${value->(
            Utils.magic: unknown => string
          )}`,
      )
    }
    number
  },
})

// The same runtime schema, typed for the modules that still annotate chain ids
// as `int`. Safe because ReScript's `int` is a JS number at runtime — chain ids
// are only ever compared and stringified, never used in int32 arithmetic.
let intSchema = schema->(Utils.magic: S.t<t> => S.t<int>)

// Postgres returns BIGINT columns as strings, so raw (schema-less) reads of a
// chain-id column go through this instead of trusting the driver's type.
let normalizeOrThrow = (value: 'a): t => value->S.parseOrThrow(schema)
