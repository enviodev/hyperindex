type t

type sourceRole = Primary | Secondary

let getSourceRole: (
  ~sourceFor: Source.sourceFor,
  ~isLive: bool,
  ~hasLive: bool,
) => option<sourceRole>

let make: (
  ~sources: array<Source.t>,
  ~maxPartitionConcurrency: int,
  ~newBlockFallbackStallTimeout: int=?,
  ~newBlockFallbackStallTimeoutLive: int=?,
  ~stalledPollingInterval: int=?,
  ~fallbackRecoveryTimeout: int=?,
  ~getHeightRetryInterval: (~retry: int) => int=?,
) => t

let getActiveSource: t => Source.t

let fetchNext: (
  t,
  ~fetchState: FetchState.t,
  ~executeQuery: FetchState.query => promise<unit>,
  ~waitForNewBlock: (~knownHeight: int) => promise<int>,
  ~onNewBlock: (~knownHeight: int) => unit,
  ~stateId: int,
) => promise<unit>

let waitForNewBlock: (t, ~knownHeight: int, ~isLive: bool) => promise<int>

let executeQuery: (
  t,
  ~query: FetchState.query,
  ~knownHeight: int,
  ~isLive: bool,
) => promise<Source.blockRangeFetchResponse>

let makeGetHeightRetryInterval: (
  ~initialRetryInterval: int,
  ~backoffMultiplicative: int,
  ~maxRetryInterval: int,
) => (~retry: int) => int
