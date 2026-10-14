// Rows cross in arenas both ways. A write stages its rows into memory the addon
// lends (`beginStage` to `commitStage`); a read lands its rows in a Rust-owned
// arena that `lendResult` hands over and `releaseResult` takes back. Reading or
// writing through a buffer after it has been handed back is what detaching
// prevents — the rules are the ones at the top of
// `packages/cli/src/columnar/mod.rs`.

type t

type postgresOptions = {
  host: string,
  port: int,
  user: string,
  password: string,
  database: string,
  // As `ENVIO_PG_SSL_MODE` spells it.
  ssl: string,
  maxConnections: int,
  applicationName: string,
  pgSchema: string,
  isHasuraEnabled: bool,
}

type clickHouseOptions = {
  url: string,
  username: string,
  password: string,
  database: string,
  replicated: bool,
  databaseEngine?: string,
}

type options = {
  chainIdMode: string,
  postgres: postgresOptions,
  clickhouse?: clickHouseOptions,
}

type queryResult = {
  handle: int,
  names: array<string>,
  kinds: array<Reading.kind>,
  // What a list column's elements are; null for a column that is not a list.
  elementKinds: array<Null.t<Reading.kind>>,
  rows: int,
}

// A ClickHouse column. The rows read back are keyed by `rowName`, the name the
// read schemas parse every store's rows by.
type clickHouseColumn = {
  name: string,
  rowName?: string,
  // The schema field, which `@storage(clickhouse: {...})` expressions name a
  // column by even when a rename is configured.
  fieldName?: string,
  fieldType: string,
  isNullable?: bool,
  isArray?: bool,
  precision?: int,
  scale?: int,
  enumVariants?: array<string>,
}

type skippingIndex = {
  name: string,
  expr: string,
  indexType: string,
  granularity?: int,
}

type clickHouseTable = {
  name: string,
  historyTable: string,
  columns: array<clickHouseColumn>,
  chainIdColumn?: string,
  partitionBy?: string,
  orderBy?: array<string>,
  ttl?: string,
  skippingIndexes?: array<skippingIndex>,
}

// A table described for every store that keeps it: an entity for each store its
// schema names, the indexer's own tables for Postgres alone.
type tableInput = {
  name: string,
  postgres?: Core.pgTableInput,
  clickhouse?: clickHouseTable,
}

type postgresRegistered = {kinds?: array<int>}

type clickHouseRegistered = {
  names: array<string>,
  kinds: array<int>,
  nullable: array<bool>,
}

type store = | @as("Postgres") Postgres | @as("ClickHouse") ClickHouse

// What each store made of a table: present for the stores that keep it.
type registeredTable = {
  handle: int,
  // The store the table is read from, and its own rows staged for.
  home: store,
  postgres?: postgresRegistered,
  clickhouse?: clickHouseRegistered,
}

type bounds = {
  sequence: string,
  chainIds: array<ChainId.t>,
  checkpointIds: array<string>,
}

type progress = {
  chainId: ChainId.t,
  progressBlock: int,
  // Unix seconds.
  progressBlockTime?: int,
  eventsProcessed: float,
  sourceBlock: int,
}

type chainMeta = {
  chainId: ChainId.t,
  firstEventBlock?: int,
  bufferBlock: int,
  // Unix milliseconds.
  readyAt?: float,
  isHyperSync: bool,
}

type addresses = {
  chainIds: array<ChainId.t>,
  addresses: array<NodeJs.Buffer.t>,
  contractIds: array<int>,
  // Left out for a key.
  registrationBlocks?: array<int>,
}

type chainConfig = {
  id: ChainId.t,
  ecosystem: string,
  startBlock: int,
  endBlock?: int,
  maxReorgDepth: int,
}

type partition = {table: int, chainId: ChainId.t, name: string}

type enum = {name: string, variants: array<string>}

type initialize = {
  sequence: string,
  tables: array<int>,
  partitions: array<partition>,
  enums: array<enum>,
  chains: array<chainConfig>,
  envioInfo: string,
  contractNames: array<string>,
  addresses: addresses,
}

type addChain = {
  chain: chainConfig,
  partitions: array<partition>,
  addresses: addresses,
}

type resume = {
  sequence: string,
  // Every entity table.
  tables: array<int>,
  // The chains this run drives, which are the only ones trimmed.
  chainIds: array<ChainId.t>,
}

type storedChain = {
  id: float,
  ecosystem: string,
  startBlock: int,
  endBlock?: int,
  maxReorgDepth: int,
}

type storedConfig = {
  envioInfo?: string,
  contractNames?: array<string>,
  chains: array<storedChain>,
  configAddresses: queryResult,
}

type resumedChain = {
  id: float,
  startBlock: int,
  endBlock?: int,
  maxReorgDepth: int,
  firstEventBlock?: int,
  // Unix milliseconds.
  readyAt?: float,
  eventsProcessed: float,
  progressBlock: int,
  // Unix seconds.
  progressBlockTime?: float,
  sourceBlock: int,
  checkpointId: string,
}

type reorgCheckpoint = {
  id: string,
  chainId: float,
  blockNumber: int,
  blockHash: string,
}

type resumed = {
  chains: array<resumedChain>,
  addresses: queryResult,
  reorgCheckpoints: array<reorgCheckpoint>,
}

type progressDiff = {
  chainId: float,
  eventsProcessed: string,
  progressBlock: int,
}

type rollbackData = {removed: queryResult, restored: queryResult}

type cacheTable = {tableName: string, rows: int}

// An optional field is left out rather than null, both ways: the addon refuses
// a null for one, and leaves out one it has no value for.

// Rows of a batch: staged into an arena, or one rendered parameter per cell,
// every row's first column first.
type rows = {
  staged?: int,
  cells?: array<Null.t<string>>,
  rows: int,
}

type historyWrite = {
  backfill: array<string>,
  sets?: rows,
  setCheckpointIds: array<string>,
  deleteIds: array<string>,
  deleteCheckpointIds: array<string>,
}

type postgresEntityWrite = {
  sets?: rows,
  deletes: array<string>,
  history?: historyWrite,
}

type entityWrite = {
  table: int,
  chainId?: ChainId.t,
  postgres?: postgresEntityWrite,
  // Every change as a history row, staged.
  clickhouse?: int,
}

type diffCheckpoint = {
  chainId: ChainId.t,
  checkpointId: string,
  blockNumber: int,
}

type rollbackWrite = {
  bounds: bounds,
  tables: array<int>,
  progress: array<progress>,
  removedAddresses: addresses,
  diffCheckpoints: array<diffCheckpoint>,
}

type checkpoints = {
  ids: array<string>,
  chainIds: array<ChainId.t>,
  blockNumbers: array<int>,
  blockHashes: array<Null.t<string>>,
  eventsProcessed: array<int>,
  keepsHistory: array<bool>,
}

type frontier = {chainIds: array<ChainId.t>, checkpointIds: array<string>}

type tableWrite = {table: int, rows: rows}

type effectCacheWrite = {table: int, create: bool, rows: rows}

type batch = {
  rollback?: rollbackWrite,
  progress: array<progress>,
  rawEvents?: tableWrite,
  entities: array<entityWrite>,
  chainMeta: array<chainMeta>,
  addresses: addresses,
  frontier: frontier,
  checkpoints: checkpoints,
  effectCaches: array<effectCacheWrite>,
}

type writeTiming = {store: store, seconds: float}

// What a build was for, which decides how much an existing index has to match.
type indexPurpose = | @as("Query") Query | @as("Schema") Schema

@tag("kind")
type indexEvent =
  | Invalid({names: array<string>})
  | Planned({declared: int, missing: array<string>, rebuilt: array<string>})
  | Building({purpose: indexPurpose, name: string, tableName: string, isRebuild: bool})
  | Built({purpose: indexPurpose, name: string, seconds: float})
  | Failed({
      purpose: indexPurpose,
      name: string,
      tableName: string,
      columns: array<string>,
      error: string,
      code?: string,
    })
  | ResyncFailed({name: string, error: string, code?: string})
  | Committed({count: int, seconds: float})

@send
external classCreate: (Core.storageCtor, options, indexEvent => unit, string => unit) => t =
  "create"

let make = (options, ~onIndexEvent, ~onWarning) =>
  Core.getAddon().storage->classCreate(options, onIndexEvent, onWarning)

@send external registerTable: (t, tableInput) => registeredTable = "registerTable"

@send
external beginStage: (t, ~table: int, ~store: store, ~rows: int) => Staging.begun = "beginStage"

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

@send external discardStaged: (t, array<int>) => unit = "discardStaged"

let arena = (client, ~store): Staging.arena => {
  beginStage: (~table, ~rows) => client->beginStage(~table, ~store, ~rows),
  growStage: (~handle, ~column, ~needed, ~stale) =>
    client->growStage(~handle, ~column, ~needed, ~stale),
  commitStage: (~handle, ~buffers) => client->commitStage(~handle, ~buffers),
  abortStage: (~handle, ~buffers) => client->abortStage(~handle, ~buffers),
}

@send
external queryForTestsRaw: (t, string, array<Null.t<string>>) => promise<queryResult> =
  "queryForTests"

@send external lendResult: (t, int) => array<ArrayBuffer.t> = "lendResult"

@send external releaseResult: (t, int, array<ArrayBuffer.t>) => unit = "releaseResult"

// Reads a result out of the arena and hands the buffers back. Nothing outside
// this function keeps a view into them, which is what makes the memory safe to
// free.
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

let queryForTests = async (client, sql, ~params=[]) =>
  client->read(await client->queryForTestsRaw(sql, params))

@send
external loadWhereRaw: (t, int, array<LoadCondition.t>) => promise<queryResult> = "loadWhere"

let loadWhere = async (client, ~table, ~conditions) =>
  client->read(await client->loadWhereRaw(table, conditions))

// What the storage holds before anything is initialized or resumed.
type holding =
  | Nothing
  | Initialized
  // ClickHouse holds indexed data Postgres has none of.
  | Stranded
  // Postgres holds indexed data the ClickHouse beside it doesn't.
  | Diverged

@send external holding: t => promise<holding> = "holding"

@send external initialize: (t, initialize) => promise<unit> = "initialize"

@send external addChain: (t, addChain) => promise<unit> = "addChain"

@send external readStoredConfig: t => promise<storedConfig> = "readStoredConfig"

@send external resume: (t, resume) => promise<resumed> = "resume"

@send external setChainMeta: (t, array<chainMeta>) => promise<unit> = "setChainMeta"

@send
external finalizeBackfill: (t, array<Core.pgIndexInput>, array<ChainId.t>, float) => promise<unit> =
  "finalizeBackfill"

@send
external ensureSchemaIndexes: (t, array<Core.pgIndexInput>) => promise<unit> = "ensureSchemaIndexes"

// Null when the indexes are already there, which is every call but the first,
// and every call for a table no store builds query indexes for.
@send
external ensureQueryIndexes: (t, int, string, array<string>) => Null.t<promise<unit>> =
  "ensureQueryIndexes"

@send external pruneCheckpoints: (t, bounds) => promise<unit> = "pruneCheckpoints"

@send external pruneHistory: (t, int, bounds) => promise<unit> = "pruneHistory"

@send
external rollbackTargetCheckpoint: (t, ChainId.t, int) => promise<Nullable.t<string>> =
  "rollbackTargetCheckpoint"

@send
external rollbackProgressDiff: (t, bounds) => promise<array<progressDiff>> = "rollbackProgressDiff"

@send external rollbackData: (t, int, bounds) => promise<rollbackData> = "rollbackData"

@send external effectCacheTables: t => promise<array<cacheTable>> = "effectCacheTables"

type cacheUpload = {table: int, path: string}

@send external uploadEffectCache: (t, array<cacheUpload>) => promise<unit> = "uploadEffectCache"

type cacheDump = {tableName: string, path: string}

@send external dumpEffectCache: (t, array<cacheDump>) => promise<unit> = "dumpEffectCache"

@send external reset: t => promise<unit> = "reset"

// Writes the batch to every store, answering how long each took. A failed
// write rejects with what it was doing as the message and the store's error as
// the `cause`.
@send external writeBatch: (t, batch) => promise<array<writeTiming>> = "writeBatch"

@send external close: t => promise<unit> = "close"
