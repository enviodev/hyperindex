// Per-chain runtime state. `t` is opaque: other modules read it through the
// accessors and change it only through the mutators exposed here.

type t

let configStorageRows: (
  Config.chain,
  ~ecosystem: Ecosystem.name,
  ~contractMapping: ContractMapping.t,
) => array<AddressRows.row>

let seedConfigAddresses: (
  AddressRows.Table.t,
  ~chainConfigs: array<Config.chain>,
  ~ecosystem: Ecosystem.name,
  ~contractMapping: ContractMapping.t,
) => unit

let makeFromDbState: (
  Config.chain,
  ~resumedChainState: Persistence.initialChainState,
  ~reorgCheckpoints: array<Internal.reorgCheckpoint>,
  ~isInReorgThreshold: bool,
  ~isRealtime: bool,
  ~config: Config.t,
  ~contractMapping: ContractMapping.t,
  ~registrationsByChainId: HandlerRegister.registrationsByChainId,
  ~logger: Logger.t,
  ~sourceTiming: SourceManager.timing=?,
  ~indexingPlan: IndexingPlan.t,
) => t

// Accessors.
let logger: t => Logger.t
let chainBuffer: t => ChainBuffer.t
// The chain's registrations by the index built items carry.
let itemContext: t => StoredItems.context
// Where builds read from: the last block a batch has taken.
let processingBlockNumber: t => int
let indexingPlan: t => IndexingPlan.t
let addressStore: t => AddressStore.t
let shouldChecksum: t => bool
let entities: t => EntityTables.t
let resetEntities: (t, ~perChainEntities: array<Internal.entityConfig>) => unit
let sourceManager: t => SourceManager.t
let chainConfig: t => Config.chain
let shouldRollbackOnReorg: t => bool
// Reorg-scan reads over the chain's buffered blocks, for the rollback flow.
let getReorgThresholdBlockNumbersBelow: (t, ~blockNumber: int) => array<int>
let getLatestValidScannedBlock: (t, ~page: BufferPage.t, ~blockNumbers: array<int>) => option<int>
let safeCheckpointTracking: t => option<SafeCheckpointTracking.t>
let committedProgressBlockNumber: t => int
let committedProgressBlockTime: t => option<int>
let numEventsProcessed: t => float
// Items per block that batches have measured, before the ready buffer's.
let processedDensity: t => option<float>

// Metric counters, rendered by Metrics at scrape time.
let recordBlockRangeFetch: (
  t,
  ~totalTimeElapsed: float,
  ~numEvents: int,
  ~blockRangeSize: int,
) => unit
let recordReorgDetected: (t, ~blockNumber: int) => unit
let setRollbackTargetBlock: (t, ~blockNumber: int) => unit

// Fetch-frontier reads.
let knownHeight: t => int
let endBlock: t => option<int>
let readyThroughBlock: t => int
let contractAddresses: (t, ~contractName: string) => array<Address.t>
let drainAddressesForWrite: (
  t,
  ~toBlockInclusive: int,
  ~checkpointBlockNumbers: array<int>,
) => array<AddressStore.drainedAddress>
let hasAddressesToWrite: t => bool
let bufferReadyCount: t => int
let hasReadyItem: t => bool
let progressPercentage: t => float

// Views.
let toMetrics: t => Metrics.chainMetrics
let toChainMetadata: t => InternalTable.Chains.metaFields
let toChainBeforeBatch: (t, ~isRealtime: bool) => Batch.chainBeforeBatch
let isReadyToEnterReorgThreshold: t => bool
let isReadyToEnterReorgThresholdAfterBatch: (t, ~batch: Batch.t) => bool

// Derived (pure).
type finished = EndBlock(int) | Backfill(int)
let takeFinished: t => option<finished>
let reorgThresholdLiftsCeiling: t => bool
let reorgThresholdEntryMessage: string
let hasProcessedToEndblock: t => bool
let hasCaughtUp: t => bool
let getHighestBlockBelowThreshold: t => int
let isReady: t => bool
let isFetchingAtHead: t => bool
let isAtHeadWithoutEndBlock: t => bool

// State transitions. The chain state is mutated only through these.
// Merges the response's page and moves the request's needs to the block the
// source reached. None for a request a rollback dropped.
let completeFetchRequest: (
  t,
  ~request: IndexingPlan.fetchRequest,
  ~response: Source.blockRangeFetchResponse,
) => option<IndexingPlan.completion>
let abandonFetchRequest: (t, ~request: IndexingPlan.fetchRequest) => unit
let hasContractRegisterBacklog: t => bool
let isRegisteringContracts: t => bool
// Starts a contractRegister run, returning the backlog blocks it reads.
let beginContractRegisterRun: t => array<int>
let endContractRegisterRun: t => unit
// Registers what a contractRegister run added, and takes the backlog blocks
// it covered out of the backlog, unless a response brought them a registering
// event meanwhile.
let registerContracts: (
  t,
  ~registrations: array<AddressStore.registration>,
  ~builtBlockNumbers: array<int>,
) => unit
let prepareReorg: (t, ~eventsProcessedDiff: option<float>) => unit
let abandonFetchRequestsInFlight: t => unit
let updateKnownHeight: (t, ~knownHeight: int) => unit
let setEndBlockToFirstEvent: (t, ~blockNumber: int) => unit
let enterReorgThreshold: t => unit
let isInReorgThreshold: t => bool
let reorgableFrom: (t, ~isRealtime: bool) => option<int>
let shouldSaveHistory: t => bool
let advanceAfterBatch: (t, ~batch: Batch.t, ~enteringReorgThreshold: bool) => unit
// Starts building the next batch's items while the current batch runs.
let prebuildItems: (t, ~targetItems: int) => unit
let applyBatchProgress: (t, ~batch: Batch.t, ~blockTimestampName: string) => unit
let markReady: (t, ~readyAt: Date.t) => unit
// What a rollback's progress diff says about one chain: the block its surviving
// checkpoints put it back to, and the events the deleted ones carried away. One
// record because one diff row yields both — they are never known separately.
type progressDiff = {blockNumber: int, eventsProcessed: float}

// Where a rollback leaves one chain.
type rolledBackTo =
  | RecomputedProgress(progressDiff)
  // The reorg chain with no checkpoint left at or below the target, so only the
  // fork block says where it goes.
  | ForkBlock(int)
  // A chain this rollback doesn't reach.
  | Untouched

let rollback: (t, ~rolledBackTo: rolledBackTo) => array<AddressRows.key>
