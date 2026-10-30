type t

type sourceRole = Primary | Secondary

let getSourceRole: (
  ~sourceFor: Source.sourceFor,
  ~isRealtime: bool,
  ~hasRealtime: bool,
) => option<sourceRole>

// Every field defaults to the production value. Only tests set them, to reach
// a stall, a recovery or a retry schedule without waiting out the real window.
type timing = {
  newBlockStallTimeout?: int,
  newBlockStallTimeoutRealtime?: int,
  stalledPollingInterval?: int,
  reducedPollingInterval?: int,
  recoveryTimeout?: float,
  getHeightRetryInterval?: (~retry: int) => int,
  // Multiplies the sleep before retrying an items query or a block-hash
  // lookup, but not the backoff it logs. A rate limit's wait is the server's
  // to set and isn't scaled.
  retryBackoffScale?: float,
  heightPollTimeout?: int,
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

type heightStreamSample = {
  sourceName: string,
  chainId: ChainId.t,
  stream: HeightFeed.streamSample,
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
  ~action: FetchState.nextQuery,
  ~stateId: int,
) => promise<unit>

let waitForNewBlock: (
  t,
  ~knownHeight: int,
  ~isRealtime: bool,
  ~reducedPolling: bool,
) => promise<int>

// The retry at which a query that no source can answer stops being a hiccup
// and gets reported as a stalled chain.
let stallRetries: int

let executeQuery: (
  t,
  ~query: FetchState.query,
  ~knownHeight: int,
  ~isRealtime: bool,
  ~reorgableFrom: option<int>,
) => promise<Source.blockRangeFetchResponse>

let makeGetHeightRetryInterval: (
  ~initialRetryInterval: int,
  ~backoffMultiplicative: int,
  ~maxRetryInterval: int,
) => (~retry: int) => int

let getBlockHashes: (t, ~blockNumbers: array<int>, ~isRealtime: bool) => promise<BlockStore.t>

// Total time the indexer spent waiting on rate limits, including any
// currently-in-progress window measured against Date.now() at call time.
let getRateLimitTimeMs: t => float

// Milliseconds remaining until the longest active rate-limit window resets,
// or None if not currently waiting (or the window has already elapsed).
let getRateLimitResetInMs: t => option<float>
