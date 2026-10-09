type t = PgClient.t

// As `SslSetting::parse` in packages/cli/src/postgres/client.rs spells them.
@unboxed
type sslMode =
  | Bool(bool)
  | @as("require") Require
  | @as("allow") Allow
  | @as("prefer") Prefer
  | @as("verify-full") VerifyFull

let sslModeSchema: S.schema<sslMode> = S.enum([
  Bool(true),
  Bool(false),
  Require,
  Allow,
  Prefer,
  VerifyFull,
])

let sslModeToString = mode =>
  switch mode {
  | Bool(true) => "true"
  | Bool(false) => "false"
  | Require => "require"
  | Allow => "allow"
  | Prefer => "prefer"
  | VerifyFull => "verify-full"
  }

@val @scope("JSON") external stringify: unknown => string = "stringify"
@val @scope("Array") external isArray: unknown => bool = "isArray"
%%private(let isDate: unknown => bool = %raw(`(value) => value instanceof Date`))
@send external toISOString: unknown => string = "toISOString"

// A document as the text a jsonb column stores. jsonb refuses the NUL
// character however it is spelled, and `JSON.stringify` spells it `\u0000`: an
// escape after an even run of backslashes, which leaving out is what lets the
// rest of the document be stored. A raw NUL byte never reaches here escaped,
// and the addon leaves those out of every parameter.
let stringifyDocument = (value: unknown): string =>
  value
  ->stringify
  ->String.replaceRegExp(/(?<=(?:^|[^\\])(?:\\\\)*)\\u0000/g, "")
  ->Utils.replaceLoneSurrogateEscapes

// Every parameter reaches the server as text — the statement's own casts say
// what type to read it back as, so a value only has to render itself.
let rec render = (value: unknown): string =>
  if isArray(value) {
    let elements = value->(Utils.magic: unknown => array<unknown>)
    let rendered = Array.make(~length=elements->Array.length, "")
    elements->Array.forEachWithIndex((element, index) =>
      rendered->Array.setUnsafe(
        index,
        switch element->(Utils.magic: unknown => Nullable.t<unknown>)->Nullable.toOption {
        | None => "NULL"
        // A sub-array is written unquoted: that is how Postgres spells a
        // further dimension rather than an element of this one.
        | Some(element) if isArray(element) => render(element)
        | Some(element) => quote(render(element))
        },
      )
    )
    "{" ++ rendered->Array.join(",") ++ "}"
  } else {
    switch value->typeof {
    | #string => value->(Utils.magic: unknown => string)
    | #boolean => value->(Utils.magic: unknown => bool) ? "t" : "f"
    | #object =>
      switch value->Utils.Bytes.asUint8Array {
      | Some(bytes) => "\\x" ++ bytes->Utils.Bytes.toHex
      | None => isDate(value) ? value->toISOString : stringifyDocument(value)
      }
    // A number, or a bigint that would refuse a number's own `toString`.
    | _ => String.make(value)
    }
  }
// Inside quotes only the quote and the backslash still mean anything, so
// quoting spares this from knowing which characters the element type treats as
// special — a comma in a text element, a brace in JSON, the `\x` a bytea
// literal starts with.
and quote = rendered => {
  let escaped = rendered->String.replaceAll("\\", "\\\\")->String.replaceAll("\"", "\\\"")
  `"${escaped}"`
}

let params = (values: array<unknown>): array<Null.t<string>> =>
  values->Array.map(value =>
    switch value->(Utils.magic: unknown => Nullable.t<unknown>)->Nullable.toOption {
    | None => Null.null
    | Some(value) => Null.make(render(value))
    }
  )

// The rows come back as plain objects keyed by the column names the statement
// selected. The server decides what is in them, so the caller names their shape.
let queryForTests = (client, sql, ~params as values: array<unknown>=[]): promise<array<'row>> =>
  client
  ->PgClient.queryForTests(sql, ~params=params(values))
  ->(Utils.magic: promise<array<dict<unknown>>> => promise<array<'row>>)

let close = client => client->PgClient.close
