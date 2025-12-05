type t

let make: (
  ~sources: array<Source.t>,
  ~maxPartitionConcurrency: int,
  ~newBlockFallbackStallTimeout: int=?,
  ~stalledPollingInterval: int=?,
  ~getHeightRetryInterval: (~retry: int) => int=?,
) => t

let getActiveSource: t => Source.t

let fetchNext: (
  t,
  ~fetchState: FetchState.t,
  ~knownHeight: int,
  ~executeQuery: FetchState.query => promise<unit>,
  ~waitForNewBlock: (~knownHeight: int) => promise<int>,
  ~onNewBlock: (~knownHeight: int) => unit,
  ~stateId: int,
) => promise<unit>

let waitForNewBlock: (t, ~knownHeight: int) => promise<int>

let executeQuery: (
  t,
  ~query: FetchState.query,
  ~knownHeight: int,
) => promise<Source.blockRangeFetchResponse>

let makeGetHeightRetryInterval: (
  ~initialRetryInterval: int,
  ~backoffMultiplicative: int,
  ~maxRetryInterval: int,
) => (~retry: int) => int
