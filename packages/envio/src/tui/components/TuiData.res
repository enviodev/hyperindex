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

type chain = {
  chainId: string,
  eventsProcessed: float,
  progressBlock: int,
  sourceBlock: int,
  startBlock: int,
  endBlock: option<int>,
  poweredByHyperSync: bool,
  progress: progress,
  latestFetchedBlockNumber: int,
  knownHeight: int,
  /** Localized unit noun for this chain's progress. `"Slots"` on SVM,
   `"Blocks"` everywhere else. Drives the per-chain progress label. */
  blockUnit: string,
  rateLimitTimeMs: float,
  rateLimitResetInMs: option<float>,
}

let fromChainMetrics = (m: Metrics.chainMetrics, ~blockUnit): chain => {
  // A chain can reach its end block without ever matching an event, so it
  // still has to render as synced with no first event block to report.
  let firstEventBlockNumber = m.firstEventBlockNumber->Option.getOr(0)
  let syncing: syncing = {
    firstEventBlockNumber,
    latestProcessedBlock: m.progressBlockNumber,
    numEventsProcessed: m.numEventsProcessed,
  }
  let synced = (~timestampCaughtUpToHeadOrEndblock): progress => Synced({
    firstEventBlockNumber,
    latestProcessedBlock: m.progressBlockNumber,
    numEventsProcessed: m.numEventsProcessed,
    timestampCaughtUpToHeadOrEndblock,
  })
  let progress = if m->Metrics.hasProcessedToEndblock {
    synced(
      ~timestampCaughtUpToHeadOrEndblock=m.timestampCaughtUpToHeadOrEndblock->Option.getOr(
        Date.now()->Date.fromTime,
      ),
    )
  } else {
    switch (m.firstEventBlockNumber, m.timestampCaughtUpToHeadOrEndblock) {
    | (Some(_), Some(timestampCaughtUpToHeadOrEndblock)) =>
      synced(~timestampCaughtUpToHeadOrEndblock)
    | (Some(_), None) => Syncing(syncing)
    | (None, _) => SearchingForEvents
    }
  }

  {
    progress,
    chainId: m.chainId->ChainId.toString,
    eventsProcessed: m.numEventsProcessed,
    progressBlock: Pervasives.max(m.progressBlockNumber, m.startBlock),
    sourceBlock: m.sourceBlockNumber,
    startBlock: m.startBlock,
    endBlock: m.endBlock,
    poweredByHyperSync: m.poweredByHyperSync,
    latestFetchedBlockNumber: m.latestFetchedBlockNumber,
    knownHeight: m.knownHeight,
    blockUnit,
    rateLimitTimeMs: m.rateLimitTimeMs,
    rateLimitResetInMs: m.rateLimitResetInMs,
  }
}

type number
@val external number: int => number = "Number"
@val external floatNumber: float => number = "Number"
@send external toLocaleString: number => string = "toLocaleString"
let formatLocaleString = n => n->number->toLocaleString
let formatFloatLocaleString = n => n->floatNumber->toLocaleString
