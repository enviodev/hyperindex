type t

let make: (
  ~sources: array<Source.t>,
  ~maxPartitionConcurrency: int,
  ~newBlockFallbackStallTimeout: int=?,
  ~stalledPollingInterval: int=?,
) => t

let getActiveSource: t => Source.t

let fetchNext: (
  t,
  ~fetchState: FetchState.t,
  ~currentBlockHeight: int,
  ~executeQuery: (FetchState.query, ~source: Source.t) => promise<unit>,
  ~waitForNewBlock: (~currentBlockHeight: int) => promise<int>,
  ~onNewBlock: (~currentBlockHeight: int) => unit,
  ~maxPerChainQueueSize: int,
  ~stateId: int,
) => promise<unit>

let waitForNewBlock: (t, ~currentBlockHeight: int) => promise<int>
