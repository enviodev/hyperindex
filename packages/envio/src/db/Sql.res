type t = PgClient.t

// The SQLSTATE of a failure the server raised. napi keeps an error's `code` for
// its own statuses, so the addon carries it as the message of the `cause`.
let sqlState = (exn: exn): option<string> =>
  switch exn->JsExn.anyToExnInternal {
  | JsExn(error) =>
    (error->(Utils.magic: JsExn.t => {"cause": Nullable.t<{"message": string}>}))["cause"]
    ->Nullable.toOption
    ->Option.map(cause => cause["message"])
  | _ => None
  }

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

// A document as the text a jsonb column stores. `JSON.stringify` escapes the
// two characters jsonb refuses however they are spelled: the NUL character,
// as `\u0000`, which is left out so the rest of the document can be stored;
// and half a surrogate pair, as `\ud800` and the like, which becomes the
// replacement character a text column stores for it. Either is an escape only
// after an even run of backslashes. A raw NUL byte never reaches here escaped,
// and the addon leaves those out of every parameter.
let stringifyDocument = (value: unknown): string =>
  value
  ->stringify
  ->String.replaceRegExp(/(?<=(?:^|[^\\])(?:\\\\)*)\\u0000/g, "")
  ->String.replaceRegExp(/(?<=(?:^|[^\\])(?:\\\\)*)\\ud[89a-f][0-9a-f]{2}/g, "\\ufffd")

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
let query = (client, sql, ~params as values: array<unknown>=[]): promise<array<'row>> =>
  client
  ->PgClient.query(sql, ~params=params(values))
  ->(Utils.magic: promise<array<dict<unknown>>> => promise<array<'row>>)

let exec = (client, sql, ~params as values: array<unknown>=[]) =>
  client->PgClient.execute(sql, params(values))

// Statements that take no parameters and return nothing worth reading. More
// than one may be given at once.
let batch = (client, sql) => client->PgClient.batch(sql)

let close = client => client->PgClient.close
