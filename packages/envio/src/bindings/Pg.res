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

// Internal handle for raw pg.Pool JS object, used only in makePool
type _handle
@module("pg") @new external _makePool: pgConfig => _handle = "Pool"
@send external _query: (_handle, queryConfig) => promise<queryResult> = "query"
@send external _connect: _handle => promise<_handle> = "connect"
@send external _release: (_handle, bool) => unit = "release"
@send external _on: (_handle, string, 'handler) => unit = "on"

type client = {
  query: queryConfig => promise<array<unknown>>,
  release: unit => unit,
  releaseAndDestroy: unit => unit,
}

type pool = {
  query: queryConfig => promise<array<unknown>>,
  connect: unit => promise<client>,
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
    query: config => raw->_query(config)->Promise.thenResolve(r => r.rows),
    connect: () =>
      raw->_connect->Promise.thenResolve(rawClient => {
        {
          query: config => rawClient->_query(config)->Promise.thenResolve(r => r.rows),
          release: () => rawClient->_release(false),
          releaseAndDestroy: () => rawClient->_release(true),
        }
      }),
  }
}

let beginSql = async (pool: pool, fn: client => promise<'a>) => {
  let client = await pool.connect()
  try {
    let _ = await client.query({text: "BEGIN"})
    let result = await fn(client)
    let _ = await client.query({text: "COMMIT"})
    client.release()
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
    client.releaseAndDestroy()
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
