@genType.import(("pg", "Pool"))
type sql

type queryResult<'a> = {rows: array<'a>}

type poolConfig = {
  host?: string,
  port?: int,
  user?: string,
  password?: string,
  database?: string,
  ssl?: unknown,
  max?: int,
}

@module("pg") @new
external makeSql: poolConfig => sql = "Pool"

// .query() works on both Pool and PoolClient
@send external _query: (sql, string) => promise<queryResult<'a>> = "query"
@send external _queryWithParams: (sql, string, unknown) => promise<queryResult<'a>> = "query"

type namedQuery = {name: string, text: string, values: unknown}
@send external _queryNamed: (sql, namedQuery) => promise<queryResult<'a>> = "query"

// Pool-only: get a client for transactions
@send external _connect: sql => promise<sql> = "connect"
// PoolClient-only: return to pool
@send external _release: sql => unit = "release"

type notice = {message: string}
@send external onNotice: (sql, @as("notice") _, notice => unit) => unit = "on"

// Prepared statement name cache
let _counter = ref(0)
let _names: dict<string> = Js.Dict.empty()

let _getName = query =>
  switch _names->Js.Dict.get(query) {
  | Some(n) => n
  | None =>
    _counter := _counter.contents + 1
    let n = `q${_counter.contents->Belt.Int.toString}`
    _names->Js.Dict.set(query, n)
    n
  }

let unsafe = async (sql, query) =>
  (await sql->_query(query)).rows->Utils.magic

let preparedUnsafe = async (sql, query, params) =>
  (await sql->_queryNamed({name: _getName(query), text: query, values: params})).rows->Utils.magic

let beginSql = async (sql, callback) => {
  let client = await sql->_connect
  try {
    let _ = await client->_query("BEGIN")
    let result = await callback(client)
    let _ = await client->_query("COMMIT")
    client->_release
    result
  } catch {
  | exn =>
    (try {
      let _ = await client->_query("ROLLBACK")
    } catch {
    | _ => ()
    })
    client->_release
    raise(exn)
  }
}

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

let sslToConfig = (ssl: sslOptions): unknown =>
  switch ssl {
  | Bool(v) => v->(Utils.magic: bool => unknown)
  | Require | Allow | Prefer => {"rejectUnauthorized": false}->(Utils.magic: {"rejectUnauthorized": bool} => unknown)
  | VerifyFull => true->(Utils.magic: bool => unknown)
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
  | @as("JSONB") JsonB
  | @as("TIMESTAMP WITH TIME ZONE") TimestampWithTimezone
  | @as("TIMESTAMP WITH TIME ZONE NULL") TimestampWithTimezoneNull
  | @as("TIMESTAMP") TimestampWithoutTimezone
  | Custom(string)
