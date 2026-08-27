// Bindings to the resolver `db` handle, `packages/envio/src/resolvers/db.js`.
// It is the surface user resolver code is handed, so it is shaped for JS rather
// than for ReScript; these follow that shape instead of wrapping it.

type pool
type db
type sqlFn

type connection = {
  host: string,
  port: int,
  username: string,
  password: string,
  database: string,
  ssl: Postgres.sslOptions,
}

type poolOptions = {
  connection: connection,
  entities: dict<Internal.entityConfig>,
  pgSchema: string,
  poolSize?: int,
  poolerBacked?: bool,
  poolWaitTimeoutMs?: int,
  onWarn?: string => unit,
}

@module("envio/src/resolvers/db.js")
external createPool: poolOptions => pool = "createResolverPool"

type resolverOptions = {name: string, timeoutMs: int}

@send external forResolver: (pool, resolverOptions) => db = "forResolver"

// The declaration the runtime has to reject. Typed apart from `forResolver` so
// a test can make one without the binding letting every other caller do so too.
@send external forResolverUnchecked: (pool, {"name": string}) => db = "forResolver"

type orderBy = {field: string, direction: string}

type findOptions = {
  where?: dict<unknown>,
  orderBy?: array<orderBy>,
  limit?: int,
  offset?: int,
}

@send external find: (db, string, findOptions) => promise<array<'entity>> = "find"
@send external get: (db, string, string) => promise<Nullable.t<'entity>> = "get"

@get external sqlOf: db => sqlFn = "sql"

// `db.sql` is a tagged template, which ReScript has no syntax for.
let taggedSelectOne: db => promise<array<{"n": int}>> = %raw("(db) => db.sql`SELECT 1::int AS n`")

@send external transaction: (db, Postgres.sql => promise<'a>) => promise<'a> = "transaction"
@send external unsafe: (sqlFn, string, array<JSON.t>) => promise<'rows> = "unsafe"

type chainHeight = {
  chainId: ChainId.t,
  ecosystem: string,
  startBlock: int,
  endBlock: Null.t<int>,
  sourceBlock: int,
  bufferBlock: int,
  progressBlock: int,
  readyAt: Null.t<Date.t>,
  isReady: bool,
}

@send external chainHeights: db => promise<dict<chainHeight>> = "chainHeights"

type causedError = {code?: string}

type poolStats = {poolSize: int, inUse: int, peakInUse: int, waiting: int}

@send external stats: pool => poolStats = "stats"
@send external endPool: pool => promise<unit> = "end"
