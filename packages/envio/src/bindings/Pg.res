type sql

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
  onnotice?: string => unit,
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
}
type queryConfig = {
  text: string,
  values: unknown,
  name?: string,
}
type pool
@module("pg") @new external makePool: pgConfig => pool = "Pool"

// Internal bindings on the opaque sql type.
// Both pg.Pool and pg.Client support .query()
@send external _query: (sql, string) => promise<{"rows": 'a}> = "query"
@send external _queryWithConfig: (sql, queryConfig) => promise<{"rows": 'a}> = "query"
// Pool-only: acquire a client for transactions
@send external _connect: sql => promise<sql> = "connect"
// Client-only: release back to pool
@send external _release: sql => unit = "release"
// Event emitter (both Pool and Client)
@send external _on: (sql, string, 'handler) => unit = "on"

// Statement name cache for prepared queries.
// Uses an incrementing counter for collision-free, stable names.
let statementNameCounter = ref(0)
let statementNameCache = Js.Dict.empty()

let getStatementName = (text: string): string => {
  switch statementNameCache->Js.Dict.get(text) {
  | Some(name) => name
  | None =>
    let name = `s${statementNameCounter.contents->Js.Int.toString}`
    statementNameCounter := statementNameCounter.contents + 1
    statementNameCache->Js.Dict.set(text, name)
    name
  }
}

let makeSql = (~config: poolConfig): sql => {
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

  let sql = makePool(pgConfig)->(Utils.magic: pool => sql)

  switch config.onnotice {
  | Some(handler) =>
    sql->_on("connect", (client: sql) => {
      client->_on("notice", (msg: {"message": string}) => handler(msg["message"]))
    })
  | None => ()
  }

  // Prevent unhandled error events from crashing the process.
  // Individual query errors are still propagated through promises.
  sql->_on("error", () => ())

  sql
}

let unsafe = (sql: sql, text: string): promise<'a> => {
  sql->_query(text)->Promise.thenResolve(r => r["rows"])
}

let preparedUnsafe = (sql: sql, text: string, values: unknown): promise<'a> => {
  sql
  ->_queryWithConfig({text, values, name: getStatementName(text)})
  ->Promise.thenResolve(r => r["rows"])
}

let beginSql = async (sql: sql, fn: sql => promise<'a>) => {
  let client = await sql->_connect
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
    client->_release
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
