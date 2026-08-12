/**
A set of stats for logging about the block range fetch
*/
type blockRangeFetchStats = {
  @as("total time elapsed (s)") totalTimeElapsed: float,
  @as("parsing time (s)") parsingTimeElapsed?: float,
  @as("page fetch time (s)") pageFetchTime?: float,
}

// A single backend request a source method actually made (cache/dedup hits
// aren't requests), with the time it took. SourceManager aggregates these
// per (source, method) into the envio_source_request_* metrics.
type requestStat = RequestStat.t = {method: string, seconds: float}

// Native clients wrap a failure of a multi-request operation in a structured
// payload, so the source can still return timings when SourceManager retries
// it. `cause` carries the inner message as a plain error, ready for logging.
type nativeRequestFailure = {
  cause: exn,
  message: option<string>,
  requestStats: array<requestStat>,
}

// Prefix marking a napi error reason as a structured native-failure envelope.
// Keep in sync with `request_stats.rs` `NATIVE_FAILURE_PREFIX`.
let nativeFailurePrefix = "ENVIO_NATIVE_FAILURE:"

// The envelope `request_stats.rs` writes after the prefix.
type nativeFailurePayload = {message: string, requestStats: array<requestStat>}

let nativeFailurePayloadSchema = S.schema(s => {
  message: s.matches(S.string),
  requestStats: s.matches(
    S.array(
      S.schema(s => {
        method: s.matches(S.string),
        seconds: s.matches(S.float),
      }),
    ),
  ),
})

let unpackNativeRequestFailure = (exn: exn): nativeRequestFailure => {
  let originalMessage = switch exn->JsExn.anyToExnInternal {
  | JsExn(jsExn) => jsExn->JsExn.message
  | _ => None
  }
  // Only a reason carrying our prefix is one of our envelopes; anything else
  // keeps its original message and cause untouched.
  let decoded = switch originalMessage {
  | Some(message) if message->String.startsWith(nativeFailurePrefix) =>
    try Some(
      message
      ->String.slice(~start=nativeFailurePrefix->String.length, ~end=message->String.length)
      ->JSON.parseOrThrow
      ->S.parseOrThrow(nativeFailurePayloadSchema),
    ) catch {
    | _ => None
    }
  | _ => None
  }
  switch decoded {
  | Some({message, requestStats}) => {
      cause: JsError.make(message)->(Utils.magic: JsError.t => exn),
      message: Some(message),
      requestStats,
    }
  | None => {cause: exn, message: originalMessage, requestStats: []}
  }
}

/**
Thes response returned from a block range fetch
*/
type blockRangeFetchResponse = {
  knownHeight: int,
  parsedQueueItems: array<Internal.item>,
  // Page of transactions for this response's items, keyed by (blockNumber,
  // transactionIndex); merged into the chain's store on apply. `None` for
  // sources that keep the transaction inline on the payload (RPC/Fuel/Simulate).
  transactionStore: option<TransactionStore.t>,
  // Page of blocks observed while fetching this range, keyed by block number;
  // merged into the chain's store on apply, where its hashes drive reorg
  // detection. Sources that keep the block inline on the payload (RPC/Simulate)
  // contribute hash-only rows built from the block hashes they saw.
  blockStore: BlockStore.t,
  fromBlockQueried: int,
  latestFetchedBlockNumber: int,
  stats: blockRangeFetchStats,
  requestStats: array<requestStat>,
}

type getHeightResponse = {height: int, requestStats: array<requestStat>}

type getBlockHashesResponse = {
  result: result<BlockStore.t, exn>,
  requestStats: array<requestStat>,
}

exception InconsistentResponse({
  method: string,
  blockNumber: option<int>,
  storedHash: option<string>,
  receivedHash: option<string>,
  missingBlockNumbers: array<int>,
})

// The queried block hasn't reached the backend instance that served the
// request. Load-balanced backends drift from each other around the head, so
// this is expected there and resolves by retrying — SourceManager owns the
// backoff and the decision to fail over, identically for every ecosystem.
// Carries the timings of the requests the failed operation did make, so a
// retried request still counts towards the source's metrics.
exception SourceBehindHead({blockNumber: int, requestStats: array<requestStat>})

type getItemsRetry =
  | WithSuggestedToBlock({toBlock: int})
  | WithBackoff({message: string, backoffMillis: int})
  | ImpossibleForTheQuery({message: string})

type rateLimited = {resetMs: int, requestStats: array<requestStat>}
exception RateLimited(rateLimited)

type getItemsError =
  | UnsupportedSelection({message: string})
  | FailedGettingFieldSelection({exn: exn, blockNumber: int, logIndex: int, message: string})
  | FailedGettingItems({exn: exn, attemptedToBlock: int, retry: getItemsRetry})

exception GetItemsError(getItemsError)

type sourceFor = Sync | Fallback | Realtime

type t = {
  name: string,
  sourceFor: sourceFor,
  chainId: ChainId.t,
  poweredByHyperSync: bool,
  /* Frequency (in ms) used when polling for new events on this network. */
  pollingInterval: int,
  getBlockHashes: (~blockNumbers: array<int>, ~logger: Pino.t) => promise<getBlockHashesResponse>,
  getHeightOrThrow: unit => promise<getHeightResponse>,
  getItemsOrThrow: (
    ~fromBlock: int,
    ~toBlock: option<int>,
    // The partition's slice of the chain's address index. The source hands it
    // straight to its Rust client, which builds the query's address filter from
    // it and gates every returned item against the chain-wide store.
    ~addressSet: AddressSet.t,
    ~knownHeight: int,
    ~partitionId: string,
    ~selection: FetchState.selection,
    // Soft cap on the number of primary items (logs/instructions/receipts) the
    // source should ask its backend for, from the query's own estResponseSize.
    // A HyperSync-backed source enforces it server-side, so a wrong estimate
    // truncates the response instead of overshooting the shared buffer. Sources
    // without an equivalent lever (RPC, Fuel, Simulate) ignore it. None means no
    // cap: bounded chunk queries fetch their whole range even if denser than
    // expected, so client-side-filtered items can't truncate the range short.
    ~itemsTarget: option<int>,
    ~retry: int,
    ~logger: Pino.t,
  ) => promise<blockRangeFetchResponse>,
  createHeightSubscription?: (~onHeight: int => unit) => unit => unit,
  // Invoked when a reorg or internally inconsistent response means local state
  // may point at an orphaned chain (e.g. the RPC block cache): drop all of it.
  // Deliberately takes no rollback target — the deepest reorged block isn't
  // known until the depth search runs, and that search reads back through this
  // very state, so pruning relative to a target would keep exactly the entries
  // that make it answer wrong.
  onReorg?: unit => unit,
}
