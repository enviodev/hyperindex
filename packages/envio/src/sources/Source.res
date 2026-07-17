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
type requestStat = {method: string, seconds: float}

// Native clients wrap a failure of a multi-request operation in a structured
// payload, so the source can still return timings when SourceManager retries
// it. `cause` carries the inner message as a plain error, ready for logging.
type nativeRequestFailure = {
  cause: exn,
  message: option<string>,
  requestStats: array<requestStat>,
}

let unpackNativeRequestFailure = (exn: exn): nativeRequestFailure => {
  let originalMessage = switch exn->JsExn.anyToExnInternal {
  | JsExn(jsExn) => jsExn->JsExn.message
  | _ => None
  }
  let decoded = switch originalMessage {
  | Some(message) =>
    switch message->JSON.parseOrThrow->JSON.Decode.object {
    | exception _ => None
    | Some(obj) =>
      switch (obj->Dict.get("kind"), obj->Dict.get("message")) {
      | (Some(String("RequestFailed")), Some(String(message))) => {
          let requestStats = switch obj->Dict.get("requestStats") {
          | Some(Array(stats)) =>
            stats->Array.filterMap(stat =>
              switch stat->JSON.Decode.object {
              | Some(obj) =>
                switch (obj->Dict.get("method"), obj->Dict.get("seconds")) {
                | (Some(String(method)), Some(Number(seconds))) => Some({method, seconds})
                | _ => None
                }
              | None => None
              }
            )
          | _ => []
          }
          Some((message, requestStats))
        }
      | _ => None
      }
    | None => None
    }
  | None => None
  }
  switch decoded {
  | Some((message, requestStats)) => {
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
  latestFetchedBlockTimestamp: int,
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

type getItemsRetry =
  | WithSuggestedToBlock({toBlock: int})
  | WithBackoff({message: string, backoffMillis: int})
  | ImpossibleForTheQuery({message: string})

type rateLimited = {resetMs: int}
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
  chain: ChainMap.Chain.t,
  poweredByHyperSync: bool,
  /* Frequency (in ms) used when polling for new events on this network. */
  pollingInterval: int,
  getBlockHashes: (~blockNumbers: array<int>, ~logger: Pino.t) => promise<getBlockHashesResponse>,
  getHeightOrThrow: unit => promise<getHeightResponse>,
  getItemsOrThrow: (
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~addressesByContractName: dict<array<Address.t>>,
    ~contractNameByAddress: dict<string>,
    ~knownHeight: int,
    ~partitionId: string,
    ~selection: FetchState.selection,
    // Soft cap on the number of primary items (logs/instructions/receipts) the
    // source should ask its backend for, from the query's own estResponseSize.
    // A HyperSync-backed source enforces it server-side, so a wrong estimate
    // truncates the response instead of overshooting the shared buffer. Sources
    // without an equivalent lever (RPC, Fuel, Simulate) ignore it.
    ~itemsTarget: int,
    ~retry: int,
    ~logger: Pino.t,
  ) => promise<blockRangeFetchResponse>,
  createHeightSubscription?: (~onHeight: int => unit) => unit => unit,
  // Invoked when a reorg or internally inconsistent response means local state
  // may point at an orphaned chain (e.g. the RPC block cache). For an
  // inconsistent response the target is the block before the retried range.
  onReorg?: (~rollbackTargetBlock: int) => unit,
  // Present only on the simulate source: the items a test fed in. The chain
  // tracks which of these never reach a handler so the run can report dead
  // simulate inputs on completion.
  simulateItems?: array<Internal.item>,
}
