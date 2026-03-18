// Internal: the underlying pg.Pool/pg.Client JS object
type _handle

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
@module("pg") @new external _makePool: pgConfig => _handle = "Pool"
@send external _query: (_handle, queryConfig) => promise<queryResult> = "query"
// Pool-only: acquire a client for transactions
@send external _connect: _handle => promise<_handle> = "connect"
// Client-only: release back to pool.
// Pass true to destroy the client instead of returning it to the pool.
@send external _release: (_handle, @as(json`false`) _) => unit = "release"
@send external _releaseAndDestroy: (_handle, @as(json`true`) _) => unit = "release"
// Event emitter (both Pool and Client)
@send external _on: (_handle, string, 'handler) => unit = "on"

type pool = {
  query: queryConfig => promise<array<unknown>>,
}
type client = pool

// WeakMap to store the raw pg.Pool handle for beginSql
let _rawHandles: Utils.WeakMap.t<pool, _handle> = Utils.WeakMap.make()

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

  let pool = {
    query: config => raw->_query(config)->Promise.thenResolve(r => r.rows),
  }
  _rawHandles->Utils.WeakMap.set(pool, raw)->ignore
  pool
}

let beginSql = async (pool: pool, fn: client => promise<'a>) => {
  let raw = _rawHandles->Utils.WeakMap.get(pool)->Belt.Option.getUnsafe
  let rawClient = await raw->_connect
  let client: client = {
    query: config => rawClient->_query(config)->Promise.thenResolve(r => r.rows),
  }
  try {
    let _ = await client.query({text: "BEGIN"})
    let result = await fn(client)
    let _ = await client.query({text: "COMMIT"})
    rawClient->_release
    result
  } catch {
  | exn =>
    try {
      let _ = await client.query({text: "ROLLBACK"})
    } catch {
    | _ => ()
    }
    // Destroy the client instead of returning it to the pool
    // to avoid reusing a client in a potentially bad state after a failed transaction.
    rawClient->_releaseAndDestroy
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
