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

let getRateLimitTimeMs: t => float
