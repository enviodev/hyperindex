// Per-chain runtime state. `t` is opaque: other modules read it through the
// accessors and change it only through the mutators exposed here.

type t

let configAddresses: Config.chain => array<Internal.indexingAddress>

let make: (
  ~chainConfig: Config.chain,
  ~fetchState: FetchState.t,
  ~sourceManager: SourceManager.t,
  ~reorgDetection: ReorgDetection.t,
  ~committedProgressBlockNumber: int,
  ~safeCheckpointTracking: option<SafeCheckpointTracking.t>=?,
  ~numEventsProcessed: float=?,
  ~timestampCaughtUpToHeadOrEndblock: option<Date.t>=?,
  ~isProgressAtHead: bool=?,
  ~logger: Pino.t,
) => t

let makeFromConfig: (
  Config.chain,
  ~config: Config.t,
  ~registrations: HandlerRegister.registrations,
  ~targetBufferSize: int,
  ~knownHeight: int,
) => t

let makeFromDbState: (
  Config.chain,
  ~resumedChainState: Persistence.initialChainState,
  ~reorgCheckpoints: array<Internal.reorgCheckpoint>,
  ~isInReorgThreshold: bool,
  ~isRealtime: bool,
  ~config: Config.t,
  ~registrations: HandlerRegister.registrations,
  ~targetBufferSize: int,
  ~reducedPollingInterval: int=?,
) => t

// Accessors.
let logger: t => Pino.t
let fetchState: t => FetchState.t
let sourceManager: t => SourceManager.t
let chainConfig: t => Config.chain
let reorgDetection: t => ReorgDetection.t
let safeCheckpointTracking: t => option<SafeCheckpointTracking.t>
let isProgressAtHead: t => bool
let committedProgressBlockNumber: t => int
let numEventsProcessed: t => float
let timestampCaughtUpToHeadOrEndblock: t => option<Date.t>

// Mutators.
let setFetchState: (t, FetchState.t) => unit
let setReorgDetection: (t, ReorgDetection.t) => unit
let setSafeCheckpointTracking: (t, option<SafeCheckpointTracking.t>) => unit
let setIsProgressAtHead: (t, bool) => unit
let setCommittedProgressBlockNumber: (t, int) => unit
let setNumEventsProcessed: (t, float) => unit
let setTimestampCaughtUpToHeadOrEndblock: (t, option<Date.t>) => unit
let handleQueryResult: (
  t,
  ~query: FetchState.query,
  ~newItems: array<Internal.item>,
  ~newItemsWithDcs: array<Internal.item>,
  ~latestFetchedBlock: FetchState.blockNumberAndTimestamp,
  ~knownHeight: int,
) => unit

// Derived (pure).
let hasProcessedToEndblock: t => bool
let hasNoMoreEventsToProcess: t => bool
let getHighestBlockBelowThreshold: t => int
let isActivelyIndexing: t => bool
let isReady: t => bool
