type t

type sourceRole = Primary | Secondary

let getSourceRole: (
  ~sourceFor: Source.sourceFor,
  ~isRealtime: bool,
  ~hasRealtime: bool,
) => option<sourceRole>

let make: (
  ~sources: array<Source.t>,
  ~maxPartitionConcurrency: int,
  ~isRealtime: bool,
  ~newBlockStallTimeout: int=?,
  ~newBlockStallTimeoutRealtime: int=?,
  ~stalledPollingInterval: int=?,
  ~reducedPollingInterval: int=?,
  ~recoveryTimeout: float=?,
  ~getHeightRetryInterval: (~retry: int) => int=?,
) => t

let getActiveSource: t => Source.t

let onReorg: (t, ~rollbackTargetBlock: int) => unit

let fetchNext: (
  t,
  ~fetchState: FetchState.t,
  ~executeQuery: FetchState.query => promise<unit>,
  ~waitForNewBlock: (~knownHeight: int) => promise<int>,
  ~onNewBlock: (~knownHeight: int) => unit,
  ~stateId: int,
) => promise<unit>

let waitForNewBlock: (
  t,
  ~knownHeight: int,
  ~isRealtime: bool,
  ~reducedPolling: bool,
) => promise<int>

let executeQuery: (
  t,
  ~query: FetchState.query,
  ~knownHeight: int,
  ~isRealtime: bool,
) => promise<Source.blockRangeFetchResponse>

let makeGetHeightRetryInterval: (
  ~initialRetryInterval: int,
  ~backoffMultiplicative: int,
  ~maxRetryInterval: int,
) => (~retry: int) => int

let getBlockHashes: (
  t,
  ~blockNumbers: array<int>,
  ~isRealtime: bool,
) => promise<array<ReorgDetection.blockDataWithTimestamp>>

// Total time the indexer spent waiting on rate limits, including any
// currently-in-progress window measured against Date.now() at call time.
let getRateLimitTimeMs: t => float

// Cumulative time from completed rate-limit windows. Stable between
// calls — does NOT include the current in-progress window.
let getCommittedRateLimitTimeMs: t => float

// Wall-clock timestamp (Date.now() ms) when the current rate-limit
// window started, or None if not currently rate-limited. Pair with
// Date.now() in the consumer to compute live elapsed time.
let getActiveRateLimitStartMs: t => option<float>
