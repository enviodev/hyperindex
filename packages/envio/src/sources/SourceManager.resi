type t

// Every field defaults to the production value. Only tests set them, to reach
// a stall, a recovery or a retry schedule without waiting out the real window.
type timing = {
  newBlockStallTimeout?: int,
  newBlockStallTimeoutRealtime?: int,
  stalledPollingInterval?: int,
  reducedPollingInterval?: int,
  recoveryTimeout?: float,
  // The height poll's backoff: the initial delay, multiplied by the retry count
  // from the second retry on, up to the max.
  heightRetryInitialMillis?: int,
  heightRetryMultiplier?: int,
  heightRetryMaxMillis?: int,
  heightPollTimeout?: int,
  // Every timer the manager arms, and every time it reads. A test passes one
  // that only moves when the test advances it.
  clock?: Clock.t,
}

let make: (~sources: array<Source.t>, ~logger: Logger.t, ~isRealtime: bool, ~timing: timing=?) => t

let getActiveSource: t => Source.t

type requestStatSample = {
  sourceName: string,
  chainId: ChainId.t,
  method: string,
  count: int,
  seconds: float,
  responseBlocks: option<int>,
  emptyResponseCount: int,
}

let getRequestStatSamples: t => array<requestStatSample>

type sourceHeightSample = {
  sourceName: string,
  chainId: ChainId.t,
  height: int,
}

let getSourceHeightSamples: t => array<sourceHeightSample>

type streamSample = {connectCount: int, disconnectsByReason: array<(string, int)>}

type heightStreamSample = {
  sourceName: string,
  chainId: ChainId.t,
  stream: streamSample,
}

let getHeightStreamSamples: t => array<heightStreamSample>

let idleSeconds: t => float
let waitingForNewBlockSeconds: t => float
let queryingSeconds: t => float

let inFlightCount: t => int

let onReorg: t => unit

let dispatch: (
  t,
  ~fetchState: FetchState.t,
  ~executeQuery: FetchState.query => promise<unit>,
  ~waitForNewBlock: (~knownHeight: int) => promise<int>,
  ~onNewBlock: (~knownHeight: int) => unit,
  ~action: FetchState.Dispatched.t,
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
  ~reorgableFrom: option<int>,
) => promise<Source.blockRangeFetchResponse>

let getBlockHashes: (t, ~blockNumbers: array<int>, ~isRealtime: bool) => promise<BlockStore.t>

// Total time the indexer spent waiting on rate limits, including any
// currently-in-progress window.
let getRateLimitTimeMs: t => float

// Milliseconds remaining until the longest active rate-limit window resets,
// or None if not currently waiting (or the window has already elapsed).
let getRateLimitResetInMs: t => option<float>
