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

let sslOptionsSchema: S.schema<sslOptions> = Utils.Schema.enum([
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
  schema?: string, // Name of schema to connect to (default: 'public')
  ssl?: sslOptions, // true, prefer, require, tls.connect options (default: false)
  max?: int, // Max number of connections (default: 10)
  maxLifetime?: option<int>, // Max lifetime in seconds (more info below) (default: null)
  idleTimeout?: int, // Idle connection timeout in seconds (default: 0)
  connectTimeout?: int, // Connect timeout in seconds (default: 30)
  prepare?: bool, // Automatic creation of prepared statements (default: true)
  // types?: array<'a>, // Array of custom types, see more below (default: [])
  onnotice?: string => unit, // Default console.log, set false to silence NOTICE (default: fn)
  onParameter?: (string, string) => unit, // (key, value) when server param change (default: fn)
  debug?: 'a. 'a => unit, //(connection, query, params, types) => unit, // Is called with (connection, query, params, types) (default: fn)
  socket?: unit => unit, // fn returning custom socket to use (default: fn)
  transform?: transformConfig,
  connection?: connectionConfig,
  targetSessionAttrs?: option<string>, // Use 'read-write' with multiple hosts to ensure only connecting to primary (default: null)
  fetchTypes?: bool, // Automatically fetches types on connect on initial connection. (default: true)
}

let makeConnectionString = (config: poolConfig) => {
  let parts = ["postgres://"]
  
  switch (config.username, config.password) {
  | (Some(username), Some(password)) => parts->Js.Array2.push(`${username}:${password}@`)->ignore
  | (Some(username), None) => parts->Js.Array2.push(`${username}@`)->ignore
  | _ => ()
  }

  switch config.host {
  | Some(host) => parts->Js.Array2.push(host)->ignore
  | None => ()
  }

  switch config.port {
  | Some(port) => parts->Js.Array2.push(`:${port->Belt.Int.toString}`)->ignore
  | None => ()
  }

  switch config.database {
  | Some(database) => parts->Js.Array2.push(`/${database}`)->ignore
  | None => ()
  }

  switch config.schema {
  | Some(schema) => parts->Js.Array2.push(`?search_path=${schema}`)->ignore
  | None => ()
  }

  let connectionString = parts->Js.Array2.joinWith("")
  connectionString
}

@module
external makeSql: (~config: poolConfig) => sql = "postgres"

@module
external makeSqlWithConnectionString: (string, poolConfig) => sql = "postgres"

let makeSql = (~config: poolConfig) => {
  let connectionString = makeConnectionString(config)

  Js.Console.log(`Connection string: ${connectionString}`)

  makeSqlWithConnectionString(connectionString, config)
}

@send external beginSql: (sql, sql => array<promise<unit>>) => promise<unit> = "begin"

// TODO: can explore this approach (https://forum.rescript-lang.org/t/rfc-support-for-tagged-template-literals/3744)
// @send @variadic
// external sql:  array<string>  => (sql, array<string>) => int = "sql"

@send external unsafe: (sql, string) => promise<'a> = "unsafe"
