type sql

type undefinedTransform = | @as(undefined) Undefined | @as(null) Null

type transformConfig = {
  undefined?: undefinedTransform, // Transforms undefined values (eg. to null) (default: undefined)
  // column?: 'c => 'd, // Transforms incoming column names (default: fn)
  // value?: 'e => 'f, // Transforms incoming row values (default: fn)
  // row?: 'g => 'h, // Transforms entire rows (default: fn)
}

type connectionConfig = {
  applicationName?: string, // Default application_name (default: 'postgres.js')
  // Other connection parameters, see https://www.postgresql.org/docs/current/runtime-config-client.html
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
  @as("ALPNProtocols") alpnProtocols?: array<string>, //| array<Buffer> | array<typedArray> | array<DataView> | Buffer | typedArray | DataView,
  servername?: string,
  checkServerIdentity?: 'a. (string, 'a) => option<Js.Exn.t>,
  session?: buffer,
  minDHSize?: int /* Default: 1024 */,
  highWaterMark?: int /* Default: 16 * 1024 */,
  secureContext?: secureContext,
  onread?: onread,
  /* Additional properties from tls.createSecureContext() and socket.connect() */
  // [key: string]: Js.Json.t,
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
  host?: string, // Postgres ip address[es] or domain name[s] (default: '')
  port?: int, // Postgres server port[s] (default: 5432)
  path?: string, // unix socket path (usually '/tmp') (default: '')
  database?: string, // Name of database to connect to (default: '')
  username?: string, // Username of database user (default: '')
  password?: string, // Password of database user (default: '')
  ssl?: sslOptions, // true, prefer, require, tls.connect options (default: false)
  max?: int, // Max number of connections (default: 10)
  maxLifetime?: option<int>, // Max lifetime in seconds (more info below) (default: null)
  idleTimeout?: int, // Idle connection timeout in seconds (default: 0)
  connectTimeout?: int, // Connect timeout in seconds (default: 30)
  prepare?: bool, // Automatic creation of prepared statements (default: true)
  // types?: array<'a>, // Array of custom types, see more below (default: [])
  onnotice?: string => unit, // Default console.log, set false to silence NOTICE (default: fn)
  onParameter?: (string, string) => unit, // (key, value) when server param change (default: fn)
  debug?: (~connection: unknown, ~query: unknown, ~params: unknown, ~types: unknown) => unit, // Is called with (connection, query, params, types)
  socket?: unit => unit, // fn returning custom socket to use (default: fn)
  transform?: transformConfig,
  connection?: connectionConfig,
  targetSessionAttrs?: option<string>, // Use 'read-write' with multiple hosts to ensure only connecting to primary (default: null)
  fetchTypes?: bool, // Automatically fetches types on connect on initial connection. (default: true)
}

@module
external makeSql: (~config: poolConfig) => sql = "postgres"

@send external beginSql: (sql, sql => promise<'result>) => promise<'result> = "begin"

// TODO: can explore this approach (https://forum.rescript-lang.org/t/rfc-support-for-tagged-template-literals/3744)
// @send @variadic
// external sql:  array<string>  => (sql, array<string>) => int = "sql"

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
