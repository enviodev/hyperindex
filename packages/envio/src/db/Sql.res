// Statements go to the server through the addon's client. A `t` carries the
// client and, when one is open, the transaction a statement runs in, so the
// same value can be passed down whether or not there is one.

type t = {client: PgClient.t, transaction: Null.t<int>}

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
    | #boolean => value === %raw(`true`) ? "t" : "f"
    | #object =>
      switch value->Utils.Bytes.asUint8Array {
      | Some(bytes) => "\\x" ++ bytes->Utils.Bytes.toHex
      | None => isDate(value) ? value->toISOString : stringify(value)
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
// selected. The server decides what is in them, so the caller names their
// shape, as it did under the driver this replaces.
let query = ({client, transaction}, sql, ~params as values: array<unknown>=[]): promise<
  array<'row>,
> => {
  let params = params(values)
  switch transaction {
  | Null => client->PgClient.query(sql, ~params)
  | Value(handle) => client->PgClient.transactionQuery(handle, sql, ~params)
  }->(Utils.magic: promise<array<dict<unknown>>> => promise<array<'row>>)
}

// A statement with nothing to read back. It goes through the addon's own
// execute rather than a query whose rows are then dropped: an insert describes
// no columns at all, and building a result for it would be an arena, a handle
// and a pair of boundary crossings for nothing.
let exec = ({client, transaction}, sql, ~params as values: array<unknown>=[]) => {
  let params = params(values)
  switch transaction {
  | Null => client->PgClient.execute(sql, params)
  | Value(handle) => client->PgClient.transactionExecute(handle, sql, params)
  }->Utils.Promise.ignoreValue
}

// Statements that take no parameters and return nothing worth reading. More
// than one may be given at once, which the schema initialization relies on.
let batch = ({client, transaction}, sql) =>
  switch transaction {
  | Null => client->PgClient.batch(sql)
  | Value(handle) => client->PgClient.transactionBatch(handle, sql)
  }

// Runs `body` in a transaction, committing it unless something throws. A `t`
// that already carries one stays in it: the statements inside belong to the
// transaction that is open, and opening a second would put them on a different
// connection than the work they have to land with.
let begin = (self, body) =>
  switch self.transaction {
  | Value(_) => body(self)
  | Null =>
    self.client->PgClient.transaction(handle => body({...self, transaction: Null.make(handle)}))
  }

let close = ({client}) => client->PgClient.close

@unboxed
type columnType =
  | @as("SMALLINT") SmallInt
  | @as("INTEGER") Integer
  | @as("BIGINT") BigInt
  | @as("BYTEA") Bytea
  | @as("BOOLEAN") Boolean
  | @as("NUMERIC") Numeric
  | @as("DOUBLE PRECISION") DoublePrecision
  | @as("TEXT") Text
  | @as("SERIAL") Serial
  | @as("BIGSERIAL") BigSerial
  | @as("JSONB") JsonB
  | @as("TIMESTAMP WITH TIME ZONE") TimestampWithTimezone
  | @as("TIMESTAMP WITH TIME ZONE NULL") TimestampWithTimezoneNull
  | @as("TIMESTAMP") TimestampWithoutTimezone
  | Custom(string)
