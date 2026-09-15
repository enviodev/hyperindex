// The Postgres client in the addon.
//
// A query lands its rows in a Rust-owned arena rather than returning them:
// `query` says what shape they are, `lendResult` hands over the buffers they
// live in, and `releaseResult` takes them back. Reading through a buffer after
// it has been handed back is what detaching prevents — the rules are the ones
// at the top of `packages/cli/src/columnar/mod.rs`.

type t

type options = {
  host: string,
  port: int,
  user: string,
  password: string,
  database: string,
  // As `ENVIO_PG_SSL_MODE` spells it.
  ssl: string,
  maxConnections: int,
  applicationName?: string,
}

type queryResult = {
  handle: int,
  names: array<string>,
  kinds: array<int>,
  // What a list column's elements are; -1 for a column that is not a list.
  elementKinds: array<int>,
  rows: int,
}

@send external classCreate: (Core.pgClientCtor, options) => t = "create"

@send external batch: (t, string) => promise<unit> = "batch"

@send external execute: (t, string, array<Null.t<string>>) => promise<int> = "execute"

@send external queryRaw: (t, string, array<Null.t<string>>) => promise<queryResult> = "query"

@send external lendResult: (t, int) => array<ArrayBuffer.t> = "lendResult"

@send external releaseResult: (t, int, array<ArrayBuffer.t>) => unit = "releaseResult"

@send external close: t => promise<unit> = "close"

let make = options => Core.getAddon().pgClient->classCreate(options)

// Runs the query and reads its rows out of the arena, handing the buffers back
// before returning. Nothing outside this function holds a view into them, which
// is what makes the memory safe to free.
let query = async (client, sql, ~params=[]) => {
  let {handle, names, kinds, elementKinds, rows} = await client->queryRaw(sql, params)
  let buffers = client->lendResult(handle)
  let result = try {
    Reading.columns(~buffers, ~names, ~kinds, ~elementKinds)->Reading.rows(~rows)
  } catch {
  | exn =>
    client->releaseResult(handle, buffers)
    throw(exn)
  }
  client->releaseResult(handle, buffers)
  result
}
