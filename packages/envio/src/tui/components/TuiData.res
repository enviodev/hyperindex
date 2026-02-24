type syncing = {
  firstEventBlockNumber: int,
  latestProcessedBlock: int,
  numEventsProcessed: int,
}
type synced = {
  ...syncing,
  timestampCaughtUpToHeadOrEndblock: Js.Date.t,
}

type progress = SearchingForEvents | Syncing(syncing) | Synced(synced)

let getNumberOfEventsProccessed = (progress: progress) => {
  switch progress {
  | SearchingForEvents => 0
  | Syncing(syncing) => syncing.numEventsProcessed
  | Synced(synced) => synced.numEventsProcessed
  }
}
type chain = {
  chainId: string,
  eventsProcessed: int,
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
  numBatchesFetched: int,
}

let minOfOption: (int, option<int>) => int = (a: int, b: option<int>) => {
  switch (a, b) {
  | (a, Some(b)) => min(a, b)
  | (a, None) => a
  }
}

type number
@val external number: int => number = "Number"
@send external toLocaleString: number => string = "toLocaleString"
let formatLocaleString = n => n->number->toLocaleString
