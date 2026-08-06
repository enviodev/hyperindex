// The write plans the CLI compiles from `tables:` in config.yaml, as they cross
// the public-config JSON boundary.
//
// Declared as one schema rather than hand-walked JSON so a plan from a CLI the
// runtime doesn't match is rejected at startup with the offending path, instead
// of surfacing as a missing field on the first event that reaches it.

type numeric =
  | @as("int") Int | @as("float") Float | @as("bigint") BigInt | @as("bigdecimal") BigDecimal

let numericSchema = S.enum([Int, Float, BigInt, BigDecimal])

type rec expr =
  | Path(array<string>)
  | LitString(string)
  | LitBool(bool)
  // `int` and `float` both arrive as JSON numbers and stay JS numbers.
  | LitNumber(float)
  // Decimal text: JSON has no bigint, and the value has to stay exact.
  | LitBigInt(string)
  | LitBigDecimal(string)
  | LitNull
  | Negate(numeric, expr)
  | Concat(option<string>, array<expr>)

let exprSchema = S.recursive(self =>
  S.union([
    S.object(s => {
      s.tag("kind", "path")
      Path(s.field("path", S.array(S.string)))
    }),
    S.object(s => {
      s.tag("kind", "string")
      LitString(s.field("value", S.string))
    }),
    S.object(s => {
      s.tag("kind", "bool")
      LitBool(s.field("value", S.bool))
    }),
    S.object(s => {
      s.tag("kind", "int")
      LitNumber(s.field("value", S.float))
    }),
    S.object(s => {
      s.tag("kind", "float")
      LitNumber(s.field("value", S.float))
    }),
    S.object(s => {
      s.tag("kind", "bigint")
      LitBigInt(s.field("value", S.string))
    }),
    S.object(s => {
      s.tag("kind", "bigdecimal")
      LitBigDecimal(s.field("value", S.string))
    }),
    S.object(s => {
      s.tag("kind", "null")
      LitNull
    }),
    S.object(s => {
      s.tag("kind", "negate")
      Negate(s.field("type", numericSchema), s.field("expr", self))
    }),
    S.object(s => {
      s.tag("kind", "concat")
      Concat(s.field("separator", S.option(S.string)), s.field("values", S.array(self)))
    }),
  ])
)

type comparison =
  | @as("eq") Eq
  | @as("ne") Ne
  | @as("gt") Gt
  | @as("gte") Gte
  | @as("lt") Lt
  | @as("lte") Lte

let comparisonSchema = S.enum([Eq, Ne, Gt, Gte, Lt, Lte])

type rec filter =
  | And(array<filter>)
  | Or(array<filter>)
  | Cmp(array<string>, comparison, expr)
  | In({path: array<string>, negated: bool, values: array<expr>})

let filterSchema = S.recursive(self =>
  S.union([
    S.object(s => {
      s.tag("kind", "and")
      And(s.field("filters", S.array(self)))
    }),
    S.object(s => {
      s.tag("kind", "or")
      Or(s.field("filters", S.array(self)))
    }),
    S.object(s => {
      s.tag("kind", "cmp")
      Cmp(
        s.field("path", S.array(S.string)),
        s.field("op", comparisonSchema),
        s.field("value", exprSchema),
      )
    }),
    S.object(s => {
      s.tag("kind", "in")
      In({
        path: s.field("path", S.array(S.string)),
        negated: s.fieldOr("negated", S.bool, false),
        values: s.field("values", S.array(exprSchema)),
      })
    }),
  ])
)

// `set` overwrites the column; `sum` adds to whatever the row already holds,
// which is why only `sum` carries the numeric type its zero comes from.
type fieldWrite =
  | Set({name: string, expr: expr})
  | Sum({name: string, numeric: numeric, expr: expr})

let fieldWriteSchema = S.union([
  S.object(s => {
    s.tag("op", "set")
    Set({name: s.field("name", S.string), expr: s.field("expr", exprSchema)})
  }),
  S.object(s => {
    s.tag("op", "sum")
    Sum({
      name: s.field("name", S.string),
      numeric: s.field("type", numericSchema),
      expr: s.field("expr", exprSchema),
    })
  }),
])

type t = {
  table: string,
  contractName: string,
  eventName: string,
  wildcard: bool,
  filter: option<filter>,
  id: expr,
  fields: array<fieldWrite>,
}

let schema = S.object(s => {
  table: s.field("table", S.string),
  contractName: s.field("contractName", S.string),
  eventName: s.field("eventName", S.string),
  wildcard: s.fieldOr("wildcard", S.bool, false),
  filter: s.field("filter", S.option(filterSchema)),
  id: s.field("id", exprSchema),
  fields: s.field("fields", S.array(fieldWriteSchema)),
})

let parseAllOrThrow = (json: JSON.t) =>
  try json->S.parseJsonOrThrow(S.array(schema)) catch {
  | S.Raised(error) =>
    JsError.throwWithMessage(
      `Invalid indexer config: the materialization plans don't match this envio version. ${error->S.Error.message}. Run \`envio codegen\` again.`,
    )
  }
