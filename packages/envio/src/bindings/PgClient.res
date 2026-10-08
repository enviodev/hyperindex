// The addon's Postgres storage: its connections, and every statement the
// indexer runs against one schema. A storage operation is one call here.
//
// Rows cross in arenas both ways. A write stages its rows into memory the addon
// lends (`beginStage` to `commitStage`); a read lands its rows in a Rust-owned
// arena that `lendResult` hands over and `releaseResult` takes back. Reading or
// writing through a buffer after it has been handed back is what detaching
// prevents — the rules are the ones at the top of
// `packages/cli/src/columnar/mod.rs`.

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
  pgSchema: string,
  chainIdMode: string,
  isHasuraEnabled: bool,
}

type queryResult = {
  handle: int,
  names: array<string>,
  kinds: array<Reading.kind>,
  // What a list column's elements are; null for a column that is not a list.
  elementKinds: array<Null.t<Reading.kind>>,
  rows: int,
}

// A table the storage writes or creates, and the slot each of its write
// columns travels in when its batches can be staged.
type registeredTable = {handle: int, kinds?: array<Staging.kind>}

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
  isEmptySchema: bool,
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

type entityWrite = {
  table: int,
  chainId?: ChainId.t,
  sets?: rows,
  deletes: array<string>,
  history?: historyWrite,
}

type rollbackWrite = {
  bounds: bounds,
  histories: array<int>,
  progress: array<progress>,
  removedAddresses: addresses,
}

type checkpoints = {
  ids: array<string>,
  chainIds: array<ChainId.t>,
  blockNumbers: array<int>,
  blockHashes: array<Null.t<string>>,
  eventsProcessed: array<int>,
}

type frontier = {chainIds: array<ChainId.t>, checkpointIds: array<string>}

type tableWrite = {table: int, create: bool, rows: rows}

type rawEventsWrite = {table: int, rows: rows}

type batch = {
  rollback?: rollbackWrite,
  progress: array<progress>,
  rawEvents?: rawEventsWrite,
  entities: array<entityWrite>,
  chainMeta: array<chainMeta>,
  addresses: addresses,
  frontier: frontier,
  checkpoints: checkpoints,
  effectCaches: array<tableWrite>,
}

@send external classCreate: (Core.pgStorageCtor, options) => t = "create"

let make = options => Core.getAddon().pgStorage->classCreate(options)

@send external registerTable: (t, Core.pgTableInput) => registeredTable = "registerTable"

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

@send external discardStaged: (t, array<int>) => unit = "discardStaged"

let arena = (client): Staging.arena => {
  beginStage: (~table, ~rows) => client->beginStage(~table, ~rows),
  growStage: (~handle, ~column, ~needed, ~stale) =>
    client->growStage(~handle, ~column, ~needed, ~stale),
  commitStage: (~handle, ~buffers) => client->commitStage(~handle, ~buffers),
  abortStage: (~handle, ~buffers) => client->abortStage(~handle, ~buffers),
}

@send external queryRaw: (t, string, array<Null.t<string>>) => promise<queryResult> = "query"

@send external execute: (t, string, array<Null.t<string>>) => promise<unit> = "execute"

@send external batch: (t, string) => promise<unit> = "batch"

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

let query = async (client, sql, ~params=[]) => client->read(await client->queryRaw(sql, params))

@send external isInitialized: t => promise<bool> = "isInitialized"

@send external checkSchemaForInitialize: t => promise<bool> = "checkSchemaForInitialize"

@send external initialize: (t, initialize) => promise<unit> = "initialize"

@send external addChain: (t, addChain) => promise<unit> = "addChain"

@send external readStoredConfig: t => promise<storedConfig> = "readStoredConfig"

@send external resume: t => promise<resumed> = "resume"

@send external setChainMeta: (t, array<chainMeta>) => promise<unit> = "setChainMeta"

@send external setReadyAt: (t, array<ChainId.t>, float) => promise<unit> = "setReadyAt"

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

// `sink` settles once the sink has written its half: `true` lets the batch
// commit, `false` rolls it back. A failed statement rejects with what it was
// doing as the message and the server's error as the `cause`.
@send
external writeBatch: (t, batch, Null.t<promise<bool>>) => promise<unit> = "writeBatch"

@send external close: t => promise<unit> = "close"
