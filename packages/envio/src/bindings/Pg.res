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
  values?: array<unknown>,
  name?: string,
}
type queryResult = {
  rows: array<unknown>,
}

type sql = {query: queryConfig => promise<queryResult>}
type client = {
  ...sql,
  release: (~destroy: bool=?) => unit,
}
type pool = {
  ...sql,
  connect: unit => promise<client>,
  on: (string, Js.Exn.t => unit) => unit,
}
external poolToSql: pool => sql = "%identity"
external clientToSql: client => sql = "%identity"
@module("pg") @new external makeRawPool: pgConfig => pool = "Pool"

let makePool = (~config: poolConfig): pool => {
  let pgConfig: pgConfig = {
    host: ?config.host,
    port: ?config.port,
    user: ?config.username,
    password: ?config.password,
    database: ?config.database,
    max: ?config.max,
    allowExitOnIdle: true,
    ssl: ?switch config.ssl {
    | Some(Require) => Some(Options({rejectUnauthorized: false}))
    | Some(VerifyFull) => Some(Options({rejectUnauthorized: true}))
    | Some(Prefer | Allow | Bool(true)) => Some(Bool(true))
    | Some(Bool(false)) => Some(Bool(false))
    | None => None
    },
  }

  let pool = makeRawPool(pgConfig)

  // Prevent unhandled error events from crashing the process.
  // Individual query errors are still propagated through promises.
  pool.on("error", (err: Js.Exn.t) => {
    Js.Console.error2("Pool error:", err->Js.Exn.message->Belt.Option.getWithDefault("Unknown error"))
  })

  pool
}

let beginSql = async (pool: pool, fn: sql => promise<'a>) => {
  let client = await pool.connect()
  try {
    let _ = await client.query({text: "BEGIN"})
    let result = await fn(client->clientToSql)
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
    client.release(~destroy=true)
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
