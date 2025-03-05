type t

let make: (~sources: array<Source.t>, ~maxPartitionConcurrency: int, ~logger: Pino.t) => t

let getActiveSource: t => Source.t

let fetchNext: (
  t,
  ~fetchState: FetchState.t,
  ~currentBlockHeight: int,
  ~executeQuery: (FetchState.query, ~source: Source.t) => promise<unit>,
  ~waitForNewBlock: (~source: Source.t, ~currentBlockHeight: int, ~logger: Pino.t) => promise<int>,
  ~onNewBlock: (~currentBlockHeight: int) => unit,
  ~maxPerChainQueueSize: int,
  ~stateId: int,
) => promise<unit>
