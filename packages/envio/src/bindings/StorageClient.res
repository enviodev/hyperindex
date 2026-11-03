// Rows cross in arenas both ways. A write stages its rows into memory the addon
// lends (`beginChanges`/`beginRows` to `commitStage`); a read lands its rows in
// a Rust-owned arena that `lendResult` hands over and `releaseResult` takes
// back. Reading or writing through a buffer after it has been handed back is
// what detaching prevents — the rules are the ones at the top of
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
  // An `envio start --chain` process: builds and looks for a per-chain
  // entity's indexes on its own chains' partitions only.
  isolated: bool,
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

type store = Postgres | ClickHouse

type stagedField = Staging.stagedField

type entityLayout = {
  name: string,
  // The store the entity is read from; none when no configured store keeps it.
  home?: store,
  fields: array<stagedField>,
}

// How every batch is laid out: an entity's change set is its fields, then each
// change's checkpoint and whether it deletes.
type layouts = {
  // By entity index.
  entities: array<entityLayout>,
  rawEvents: array<stagedField>,
  effectCache: array<stagedField>,
}

type stagedTable = RawEvents | EffectCache

type bounds = {
  chainIds: array<ChainId.t>,
  checkpointIds: array<bigint>,
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

type initialize = {
  chains: array<chainConfig>,
  envioInfo: string,
  contractNames: array<string>,
  addresses: addresses,
}

type addChain = {
  chain: chainConfig,
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
  checkpointId: bigint,
}

type reorgCheckpoint = {
  id: bigint,
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

// `chainId` is left out for a cross-chain cache.
type storedEffectCache = {
  effectName: string,
  chainId?: ChainId.t,
  tableName: string,
  rows: int,
}

// An optional field is left out rather than null, both ways: the addon refuses
// a null for one, and leaves out one it has no value for.

// One entity's changes within one chain scope, staged.
type changes = {
  entity: int,
  chainId?: ChainId.t,
  keepsHistory: bool,
  changes: int,
}

type diffCheckpoint = {
  chainId: ChainId.t,
  checkpointId: bigint,
  blockNumber: int,
}

type rollbackWrite = {
  bounds: bounds,
  progress: array<progress>,
  removedAddresses: addresses,
  diffCheckpoints: array<diffCheckpoint>,
}

type checkpoints = {
  ids: array<bigint>,
  chainIds: array<ChainId.t>,
  blockNumbers: array<int>,
  blockHashes: array<Null.t<string>>,
  eventsProcessed: array<int>,
  keepsHistory: array<bool>,
}

type frontier = {chainIds: array<ChainId.t>, checkpointIds: array<bigint>}

type effectCacheWrite = {table: string, create: bool, rows: int}

type batch = {
  rollback?: rollbackWrite,
  progress: array<progress>,
  rawEvents?: int,
  changes: array<changes>,
  chainMeta: array<chainMeta>,
  addresses: addresses,
  frontier: frontier,
  checkpoints: checkpoints,
  effectCaches: array<effectCacheWrite>,
}

type writeTiming = {store: store, seconds: float}

@send
external classCreate: (
  Core.storageCtor,
  options,
  Null.t<string>,
  Logger.native,
  array<string>,
) => t = "create"

// The storage of the entities `configJson` declares — the config the CLI
// wrote — or of none. The addon logs through `logger` itself, with the fields
// bound to it.
let make = (options, ~configJson=?, ~logger: Logger.t) =>
  Core.getAddon().storage->classCreate(
    options,
    configJson->Null.fromOption,
    logger.output.native,
    logger.boundFieldsJson,
  )

@send external layouts: t => layouts = "layouts"

@send external beginChanges: (t, ~entity: int, ~rows: int) => Staging.begun = "beginChanges"

@send external beginRows: (t, ~table: stagedTable, ~rows: int) => Staging.begun = "beginRows"

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

let arena = (client, begin): Staging.arena => {
  beginStage: (~rows) => begin(~rows),
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

let loadWhere = async (client, ~entity, ~conditions) =>
  client->read(await client->loadWhereRaw(entity, conditions))

@send
external loadEffectCacheRaw: (t, string, array<LoadCondition.t>) => promise<queryResult> =
  "loadEffectCache"

let loadEffectCache = async (client, ~table, ~conditions) =>
  client->read(await client->loadEffectCacheRaw(table, conditions))

@send
external clickHouseRowsForTestsRaw: (t, int) => promise<queryResult> = "clickhouseRowsForTests"

let clickHouseRowsForTests = async (client, ~entity) =>
  client->read(await client->clickHouseRowsForTestsRaw(entity))

@send external historyForTestsRaw: (t, int) => promise<queryResult> = "historyForTests"

let historyForTests = async (client, ~entity) =>
  client->read(await client->historyForTestsRaw(entity))

// What the storage holds before anything is initialized or resumed.
type holding =
  | Nothing
  | Initialized
  // ClickHouse holds indexed data Postgres has none of.
  | Stranded
  // Postgres holds indexed data the ClickHouse beside it doesn't.
  | Diverged
  // Postgres was built by an older envio, which kept nothing to pair it with
  // the ClickHouse beside it.
  | Outdated

@send external holding: t => promise<holding> = "holding"

@send external initialize: (t, initialize) => promise<unit> = "initialize"

@send external addChain: (t, addChain) => promise<unit> = "addChain"

@send external readStoredConfig: t => promise<storedConfig> = "readStoredConfig"

// Resumes the chains this run drives, the only ones ClickHouse trims.
@send external resume: (t, array<ChainId.t>) => promise<resumed> = "resume"

@send external setChainMeta: (t, array<chainMeta>) => promise<unit> = "setChainMeta"

// Builds every index the schema promises for the chains, then stamps them
// ready at the given unix milliseconds.
@send
external finalizeBackfill: (t, array<ChainId.t>, float) => promise<unit> = "finalizeBackfill"

@send external ensureSchemaIndexes: (t, array<ChainId.t>) => promise<unit> = "ensureSchemaIndexes"

// Null when the indexes are already there, which is every call but the first,
// and every call for an entity Postgres doesn't keep.
@send
external ensureQueryIndexes: (
  t,
  ~entity: int,
  ~chainId: Null.t<ChainId.t>,
  ~columns: array<string>,
) => Null.t<promise<unit>> = "ensureQueryIndexes"

@send external pruneCheckpoints: (t, bounds) => promise<unit> = "pruneCheckpoints"

@send external pruneHistory: (t, int, bounds) => promise<unit> = "pruneHistory"

@send
external rollbackTargetCheckpoint: (t, ChainId.t, int) => promise<Nullable.t<bigint>> =
  "rollbackTargetCheckpoint"

@send
external rollbackProgressDiff: (t, bounds) => promise<array<progressDiff>> = "rollbackProgressDiff"

@send external rollbackData: (t, int, bounds) => promise<rollbackData> = "rollbackData"

// Uploads the caches saved under the directory first when `upload` says to,
// logging how that went.
@send
external restoreEffectCache: (t, string, bool) => promise<array<storedEffectCache>> =
  "restoreEffectCache"

// Never rejects: a dump that doesn't finish is logged.
@send external dumpEffectCache: (t, string) => promise<unit> = "dumpEffectCache"

@send external reset: t => promise<unit> = "reset"

// Writes the batch to every store, answering how long each took. A failed
// write rejects with what it was doing as the message and the store's error as
// the `cause`.
@send external writeBatch: (t, batch) => promise<array<writeTiming>> = "writeBatch"

@send external close: t => promise<unit> = "close"
