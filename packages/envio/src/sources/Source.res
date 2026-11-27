// A single backend request a source method actually made (cache/dedup hits
// aren't requests), with the time it took and how much it brought back.
// SourceManager aggregates these per (source, method) into the
// envio_source_request_* and envio_source_response_* metrics.
type requestStat = {
  method: string,
  seconds: float,
  // Blocks the backend returned for this request, before any matching drops
  // them. Absent for methods whose responses aren't measured in blocks, so a
  // zero always means the request came back empty.
  responseBlocks?: int,
}

// Every way a source call can fail that the caller is expected to handle. A
// source never throws for one of these; an exception escaping a source is a
// bug and stops the indexer.
@tag("kind")
type failure =
  // The backend asked to be left alone until its window resets.
  | RateLimited({resetMs: int})
  // The queried block hasn't reached the backend instance that served the
  // request. Load-balanced backends drift from each other around the head, so
  // this is expected there and resolves by retrying.
  | BehindHead({blockNumber: int})
  // Ask again for the same range ending at `toBlock`, with no wait.
  // `attemptedToBlock` is where the refused attempt ended, which tells a
  // suggestion that doesn't narrow anything apart from one that does.
  | NarrowRange({toBlock: int, attemptedToBlock: int})
  // Wait, then ask the same thing again. Without `backoffMillis` the caller's
  // retry schedule decides how long.
  | Backoff({message: string, backoffMillis?: int, cause?: string})
  // This source cannot answer this query, though it is not broken: the caller
  // tries another source for it.
  | WrongSourceForQuery({message: string})
  // This source can never serve the chain's selection, so the caller stops
  // using it.
  | Unusable({message: string, blockNumber?: int})

let failureMessage = (failure: failure) =>
  switch failure {
  | RateLimited({resetMs}) => `Rate limited for ${resetMs->Int.toString}ms`
  | BehindHead({blockNumber}) => `Hasn't reached block ${blockNumber->Int.toString} yet`
  | NarrowRange({toBlock}) => `Asked for a range ending at block ${toBlock->Int.toString} instead`
  | Backoff({message}) | WrongSourceForQuery({message}) | Unusable({message}) => message
  }

// A call's result with the requests it made, which count towards the source's
// metrics whether or not the call succeeded.
type outcome<'a> = {result: result<'a, failure>, requestStats: array<requestStat>}

// What a block range fetch brings back.
type itemsPage = {
  // The response's rows, kept in Rust: what some registration matches, the
  // transactions and blocks they belong to, and the blocks seen while fetching
  // the range, whose hashes drive reorg detection. Merged into the chain's
  // buffer on apply.
  page: BufferPage.t,
  // The highest block the query accounted for, which is not necessarily the
  // block of its last item.
  latestFetchedBlockNumber: int,
  // The chain height the backend reported alongside the page, if it did.
  knownHeight: option<int>,
}

// A fetched range as SourceManager hands it on.
type blockRangeFetchResponse = {
  page: BufferPage.t,
  latestFetchedBlockNumber: int,
  knownHeight: int,
  totalTimeElapsed: float,
  // The manager's index of the source that answered, whose range capacity the
  // plan learns from it.
  sourceIndex: int,
}

type sourceFor = Sync | Fallback | Realtime

// Why a height subscription's connection ended. Closed, so a consumer decides
// what a failure means by matching on it rather than by recognising a string,
// and so every transport describes an outage in the same words.
type heightSubscriptionDownReason =
  // Ended cleanly after serving long enough to have been worth making: a load
  // balancer moving a connection, and routine.
  | Rotated
  // Ended cleanly without having served: a server dropping connections it
  // ought to be keeping.
  | Closed
  // Delivered nothing at all for a whole staleness window.
  | Stale
  // Sent frames the transport could not read. Alone among these it never heals
  // on its own, which is why consumers tell an operator about it.
  | Unreadable
  // No connection was established to begin with.
  | ConnectFailed
  // The provider refused the subscription.
  | SubscribeRejected
  // The socket itself reported an error.
  | TransportError
  // Refused with an HTTP status, which is the whole of what an SSE stream is
  // told about a refusal.
  | Http(int)
  // The consumer gave the source up. Not an outage, but the connection is gone
  // and a count that omitted it would leave the source looking connected.
  | Unsubscribed

// Bounded, so it is safe as a metric label. Whatever the provider said about
// one failure belongs in `detail` and in a log line, never here.
let downReasonLabel = reason =>
  switch reason {
  | Rotated => "rotated"
  | Closed => "closed"
  | Stale => "stale"
  | Unreadable => "unreadable"
  | ConnectFailed => "connect-failed"
  | SubscribeRejected => "subscribe-rejected"
  | TransportError => "error"
  | Http(code) => `http-${code->Int.toString}`
  | Unsubscribed => "unsubscribed"
  }

// Connection state of a height subscription, reported by every transport.
// `Down` repeats on each failed retry while the stream stays broken, and `Live`
// fires on every (re)connect, so consumers must treat both as idempotent.
// `detail` is whatever the provider said for this one failure — an error
// message, or the frame nobody could read.
type heightSubscriptionStatus = Live | Down({reason: heightSubscriptionDownReason, detail?: string})

type t = {
  name: string,
  sourceFor: sourceFor,
  chainId: ChainId.t,
  poweredByHyperSync: bool,
  /* Frequency (in ms) used when polling for new events on this network. */
  pollingInterval: int,
  // None for a source that cannot read block hashes, which is then never
  // asked to find how deep a reorg went.
  getBlockHashes: option<array<int> => promise<outcome<BufferPage.t>>>,
  getHeight: unit => promise<outcome<int>>,
  getItems: (
    // What to fetch from its `fromBlock`. The source hands it straight to its
    // Rust client, which builds the query from it and gates every returned
    // item against the chain-wide store.
    ~request: IndexingPlan.fetchRequest,
    // Inclusive: the request's own end, or the narrower one a refused attempt
    // suggested. None asks for everything the backend has.
    ~toBlock: option<int>,
    ~retry: int,
    // Blocks at or above this one can still be reorged on the chain, so a page
    // reaching them must let reorg detection link it to the page before it:
    // its last block's header and its first block's parent hash, or every
    // block's hash. That header also gives the progress block its timestamp at
    // the head, where the block often carries no item. Each source decides how
    // to provide it. None when every block of the range is final.
    ~reorgableFrom: option<int>,
    ~knownHeight: int,
  ) => promise<outcome<itemsPage>>,
  createHeightSubscription?: (
    // The stream's staleness and reconnect timers run on the clock of the
    // manager that subscribes, not one the source was built with.
    ~clock: Clock.t,
    ~onHeight: int => unit,
    ~onStatus: heightSubscriptionStatus => unit,
  ) => unit => unit,
  // Invoked when a reorg or an internally inconsistent response means what the
  // source is holding may describe an orphaned chain — for RPC, the reads still
  // in flight, which anything asking afterwards would otherwise join. The
  // stores are rolled back separately; this is only about what the source
  // itself carries. Deliberately takes no rollback target: the deepest reorged
  // block isn't known until the depth search runs, and that search reads back
  // through this very state.
  onReorg?: unit => unit,
}
