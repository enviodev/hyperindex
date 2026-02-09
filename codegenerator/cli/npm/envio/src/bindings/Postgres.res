// Only needed for some old tests
// Remove @genType in the future
@genType.import(("./PgAdapter.js", "Sql"))
type sql

type connectionConfig = {
  applicationName?: string,
}

type streamDuplex
type buffer
type secureContext

type onread = {
  buffer: Js.Nullable.t<array<int>> => array<int>,
  callback: (int, array<int>) => unit,
}

type tlsConnectOptions = {
  enableTrace?: bool,
  host?: string /* Default: "localhost" */,
  port?: int,
  path?: string,
  socket?: streamDuplex,
  allowHalfOpen?: bool /* Default: false */,
  rejectUnauthorized?: bool /* Default: true */,
  pskCallback?: unit => unit,
  @as("ALPNProtocols") alpnProtocols?: array<string>,
  servername?: string,
  checkServerIdentity?: 'a. (string, 'a) => option<Js.Exn.t>,
  session?: buffer,
  minDHSize?: int /* Default: 1024 */,
  highWaterMark?: int /* Default: 16 * 1024 */,
  secureContext?: secureContext,
  onread?: onread,
}

@unboxed
type sslOptions =
  | Bool(bool)
  | TLSConnectOptions(tlsConnectOptions)
  | @as("require") Require
  | @as("allow") Allow
  | @as("prefer") Prefer
  | @as("verify-full") VerifyFull

let sslOptionsSchema: S.schema<sslOptions> = S.enum([
  Bool(true),
  Bool(false),
  Require,
  Allow,
  Prefer,
  VerifyFull,
  //No schema created for tlsConnectOptions obj
])

type poolConfig = {
  host?: string,
  port?: int,
  database?: string,
  username?: string,
  password?: string,
  ssl?: sslOptions,
  max?: int,
  idleTimeout?: int,
  connectTimeout?: int,
  onnotice?: string => unit,
  connection?: connectionConfig,
}

@module("./PgAdapter.js")
external makeSql: (~config: poolConfig) => sql = "default"

@send external beginSql: (sql, sql => promise<'result>) => promise<'result> = "begin"

@send external unsafe: (sql, string) => promise<'a> = "unsafe"
@send
external preparedUnsafe: (sql, string, unknown, @as(json`{prepare: true}`) _) => promise<'a> =
  "unsafe"

@unboxed
type columnType =
  | @as("INTEGER") Integer
  | @as("BIGINT") BigInt
  | @as("BOOLEAN") Boolean
  | @as("NUMERIC") Numeric
  | @as("DOUBLE PRECISION") DoublePrecision
  | @as("TEXT") Text
  | @as("SERIAL") Serial
  | @as("JSONB") JsonB
  | @as("TIMESTAMP WITH TIME ZONE") TimestampWithTimezone
  | @as("TIMESTAMP WITH TIME ZONE NULL") TimestampWithTimezoneNull
  | @as("TIMESTAMP") TimestampWithoutTimezone
  | Custom(string)
