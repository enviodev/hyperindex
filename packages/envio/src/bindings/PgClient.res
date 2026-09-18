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

@send external begin: t => promise<int> = "begin"

@send external transactionBatch: (t, int, string) => promise<unit> = "transactionBatch"

@send
external transactionExecute: (t, int, string, array<Null.t<string>>) => promise<int> =
  "transactionExecute"

@send
external transactionQueryRaw: (t, int, string, array<Null.t<string>>) => promise<queryResult> =
  "transactionQuery"

@send external commit: (t, int) => promise<unit> = "commit"

@send external rollback: (t, int) => promise<unit> = "rollback"

@send
external registerWriteTable: (t, array<string>, array<int>) => int = "registerWriteTable"

@send external beginStage: (t, ~table: int, ~rows: int) => Staging.begun = "beginStage"

@send
external growStage: (
  t,
  ~handle: int,
  ~column: int,
  ~needed: int,
  ~stale: ArrayBuffer.t,
) => ArrayBuffer.t = "growStage"

@send
external commitStage: (t, ~handle: int, ~buffers: array<ArrayBuffer.t>) => unit = "commitStage"

@send external abortStage: (t, ~handle: int, ~buffers: array<ArrayBuffer.t>) => unit = "abortStage"

@send
external executeStaged: (
  t,
  ~transaction: Null.t<int>,
  ~sql: string,
  ~handle: int,
) => promise<unit> = "executeStaged"

let arena = (client): Staging.arena => {
  beginStage: (~table, ~rows) => client->beginStage(~table, ~rows),
  growStage: (~handle, ~column, ~needed, ~stale) =>
    client->growStage(~handle, ~column, ~needed, ~stale),
  commitStage: (~handle, ~buffers) => client->commitStage(~handle, ~buffers),
  abortStage: (~handle, ~buffers) => client->abortStage(~handle, ~buffers),
}

@send external forgetPrepared: t => unit = "forgetPrepared"

@send external copyOut: (t, string, string) => promise<unit> = "copyOut"

@send external copyIn: (t, string, string) => promise<int> = "copyIn"

@send external close: t => promise<unit> = "close"

let make = options => Core.getAddon().pgClient->classCreate(options)

// Reads a result out of the arena and hands the buffers back. Nothing outside
// this function keeps a view into them, which is what makes the memory safe to
// free.
%%private(
  let read = (client, {handle, names, kinds, elementKinds, rows}) => {
    let buffers = client->lendResult(handle)
    let result = try {
      Reading.rows(~buffers, ~names, ~kinds, ~elementKinds, ~rows)
    } catch {
    | exn =>
      client->releaseResult(handle, buffers)
      throw(exn)
    }
    client->releaseResult(handle, buffers)
    result
  }
)

let query = async (client, sql, ~params=[]) => client->read(await client->queryRaw(sql, params))

let transactionQuery = async (client, transaction, sql, ~params=[]) =>
  client->read(await client->transactionQueryRaw(transaction, sql, params))

// Opens a transaction, runs `body` in it, and commits. Anything thrown rolls
// back instead and is re-thrown — the transaction holds a connection until one
// or the other happens, so neither path may leave without ending it.
let transaction = async (client, body) => {
  let handle = await client->begin
  let result = try await body(handle) catch {
  | exn =>
    // The rollback is what frees the connection. If it fails too, that failure
    // would otherwise replace the one worth reporting.
    try await client->rollback(handle) catch {
    | _ => ()
    }
    throw(exn)
  }
  await client->commit(handle)
  result
}
