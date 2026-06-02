type syncing = {
  firstEventBlockNumber: int,
  latestProcessedBlock: int,
  numEventsProcessed: float,
}
type synced = {
  ...syncing,
  timestampCaughtUpToHeadOrEndblock: Date.t,
}

type progress = SearchingForEvents | Syncing(syncing) | Synced(synced)

let getNumberOfEventsProccessed = (progress: progress) => {
  switch progress {
  | SearchingForEvents => 0.
  | Syncing(syncing) => syncing.numEventsProcessed
  | Synced(synced) => synced.numEventsProcessed
  }
}
type chain = {
  chainId: string,
  eventsProcessed: float,
  progressBlock: option<int>,
  bufferBlock: option<int>,
  sourceBlock: option<int>,
  startBlock: int,
  endBlock: option<int>,
  firstEventBlockNumber: option<int>,
  poweredByHyperSync: bool,
  progress: progress,
  latestFetchedBlockNumber: int,
  knownHeight: int,
  // Committed rate-limit time across closed windows. The TUI adds the
  // in-progress portion via (Date.now() - activeRateLimitStartMs) so the
  // display ticks up every render without SourceManager doing UI math.
  committedRateLimitTimeMs: float,
  activeRateLimitStartMs: option<float>,
}

let minOfOption: (int, option<int>) => int = (a: int, b: option<int>) => {
  switch (a, b) {
  | (a, Some(b)) => min(a, b)
  | (a, None) => a
  }
}

type number
@val external number: int => number = "Number"
@val external floatNumber: float => number = "Number"
@send external toLocaleString: number => string = "toLocaleString"
let formatLocaleString = n => n->number->toLocaleString
let formatFloatLocaleString = n => n->floatNumber->toLocaleString
