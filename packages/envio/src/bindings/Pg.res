// Internal: both pg.Pool and pg.Client share the query interface at JS level
type rawHandle

@unboxed
type sslOptions =
  | Bool(bool)
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
])

type poolConfig = {
  host?: string,
  port?: int,
  database?: string,
  username?: string,
  password?: string,
  ssl?: sslOptions,
  max?: int,
}

// Raw pg bindings (internal)
@unboxed type ssl = Bool(bool) | Options({rejectUnauthorized: bool})
type pgConfig = {
  host?: string,
  port?: int,
  user?: string,
  password?: string,
  database?: string,
  ssl?: ssl,
  max?: int,
  allowExitOnIdle?: bool,
}
type queryConfig = {
  text: string,
  values?: unknown,
  name?: string,
}
type queryResult = {
  rows: array<unknown>,
}
@module("pg") @new external _makePool: pgConfig => rawHandle = "Pool"
@send external _query: (rawHandle, queryConfig) => promise<queryResult> = "query"
// Pool-only: acquire a client for transactions
@send external _connect: rawHandle => promise<rawHandle> = "connect"
// Client-only: release back to pool.
// Pass true to destroy the client instead of returning it to the pool.
@send external _release: (rawHandle, @as(json`false`) _) => unit = "release"
@send external _releaseAndDestroy: (rawHandle, @as(json`true`) _) => unit = "release"
// Event emitter (both Pool and Client)
@send external _on: (rawHandle, string, 'handler) => unit = "on"

// Postgres limits query names to 63 characters
let maxStatementNameLength = 63

// Hash long statement names to prevent collisions when truncating
let hashName: string => string = %raw(`
  function(name) {
    return name.slice(0, 31) + require('node:crypto').createHash('md5').update(name).digest('hex').slice(0, 32);
  }
`)

type sql = {
  query: queryConfig => promise<array<unknown>>,
}

let makeSql = (raw: rawHandle): sql => {
  query: config => {
    let config = switch config.name {
    | Some(name) if name->String.length > maxStatementNameLength => {
        ...config,
        name: hashName(name),
      }
    | _ => config
    }
    raw->_query(config)->Promise.thenResolve(r => r.rows)
  },
}

type pool = {
  sql: sql,
  raw: rawHandle,
}

let makePool = (~config: poolConfig): pool => {
  let pgConfig: pgConfig = {
    host: ?config.host,
    port: ?config.port,
    user: ?config.username,
    password: ?config.password,
    database: ?config.database,
    max: ?config.max,
    ssl: ?switch config.ssl {
    | Some(Require) => Some(Options({rejectUnauthorized: false}))
    | Some(VerifyFull) => Some(Options({rejectUnauthorized: true}))
    | Some(Prefer | Allow | Bool(true)) => Some(Bool(true))
    | Some(Bool(false)) => Some(Bool(false))
    | None => None
    },
  }

  let raw = _makePool({...pgConfig, allowExitOnIdle: true})

  // Prevent unhandled error events from crashing the process.
  // Individual query errors are still propagated through promises.
  raw->_on("error", (err: Js.Exn.t) => {
    Js.Console.error2("Pool error:", err->Js.Exn.message->Belt.Option.getWithDefault("Unknown error"))
  })

  {
    sql: makeSql(raw),
    raw,
  }
}

let beginSql = async (pool: pool, fn: sql => promise<'a>) => {
  let client = await pool.raw->_connect
  let clientSql = makeSql(client)
  try {
    let _ = await clientSql.query({text: "BEGIN"})
    let result = await fn(clientSql)
    let _ = await clientSql.query({text: "COMMIT"})
    client->_release
    result
  } catch {
  | exn =>
    try {
      let _ = await clientSql.query({text: "ROLLBACK"})
    } catch {
    | _ => ()
    }
    // Destroy the client instead of returning it to the pool
    // to avoid reusing a client in a potentially bad state after a failed transaction.
    client->_releaseAndDestroy
    raise(exn)
  }
}

@unboxed
type columnType =
  | @as("INTEGER") Integer
  | @as("BIGINT") BigInt
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
