type pool

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
  values: unknown,
  name?: string,
}
@module("pg") @new external _makePool: pgConfig => pool = "Pool"

// Both pg.Pool and pg.Client support .query()
@send external _query: (pool, string) => promise<{"rows": 'a}> = "query"
@send external _queryWithConfig: (pool, queryConfig) => promise<{"rows": 'a}> = "query"
// Pool-only: acquire a client for transactions
@send external _connect: pool => promise<pool> = "connect"
// Client-only: release back to pool.
// Pass true to destroy the client instead of returning it to the pool.
@send external _release: (pool, @as(json`false`) _) => unit = "release"
@send external _releaseAndDestroy: (pool, @as(json`true`) _) => unit = "release"
// Event emitter (both Pool and Client)
@send external _on: (pool, string, 'handler) => unit = "on"

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

  let pool = _makePool({...pgConfig, allowExitOnIdle: true})

  // Prevent unhandled error events from crashing the process.
  // Individual query errors are still propagated through promises.
  pool->_on("error", (err: Js.Exn.t) => {
    Js.Console.error2("Pool error:", err->Js.Exn.message->Belt.Option.getWithDefault("Unknown error"))
  })

  pool
}

let unsafe = (pool: pool, text: string): promise<'a> => {
  pool->_query(text)->Promise.thenResolve(r => r["rows"])
}

// Postgres limits query names to 63 characters
let maxStatementNameLength = 63

let preparedUnsafe = (pool: pool, ~name: string, text: string, values: unknown): promise<'a> => {
  let name = if name->String.length > maxStatementNameLength {
    name->Js.String.slice(~from=0, ~to_=maxStatementNameLength)
  } else {
    name
  }
  pool
  ->_queryWithConfig({text, values, name})
  ->Promise.thenResolve(r => r["rows"])
}

let beginSql = async (pool: pool, fn: pool => promise<'a>) => {
  let client = await pool->_connect
  try {
    let _ = await client->_query("BEGIN")
    let result = await fn(client)
    let _ = await client->_query("COMMIT")
    client->_release
    result
  } catch {
  | exn =>
    try {
      let _ = await client->_query("ROLLBACK")
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
