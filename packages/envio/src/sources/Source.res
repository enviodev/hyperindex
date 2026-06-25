/**
A set of stats for logging about the block range fetch
*/
type blockRangeFetchStats = {
  @as("total time elapsed (s)") totalTimeElapsed: float,
  @as("parsing time (s)") parsingTimeElapsed?: float,
  @as("page fetch time (s)") pageFetchTime?: float,
}

/**
Thes response returned from a block range fetch
*/
type blockRangeFetchResponse = {
  knownHeight: int,
  // Best-effort (blockNumber, blockHash) pairs observed while fetching this range.
  // Used by reorg detection; gaps are OK, no extra requests are made to fill them.
  // Duplicates with the same block number are allowed — registerReorgGuard treats
  // a within-array hash mismatch on the same block number as a reorg.
  blockHashes: array<ReorgDetection.blockData>,
  parsedQueueItems: array<Internal.item>,
  fromBlockQueried: int,
  latestFetchedBlockNumber: int,
  latestFetchedBlockTimestamp: int,
  stats: blockRangeFetchStats,
}

type getItemsRetry =
  | WithSuggestedToBlock({toBlock: int})
  | WithBackoff({message: string, backoffMillis: int})
  | ImpossibleForTheQuery({message: string})

exception RateLimited({resetMs: int})

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
  getBlockHashes: (
    ~blockNumbers: array<int>,
    ~logger: Pino.t,
  ) => promise<result<array<ReorgDetection.blockDataWithTimestamp>, exn>>,
  getHeightOrThrow: unit => promise<int>,
  getItemsOrThrow: (
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~addressesByContractName: dict<array<Address.t>>,
    ~contractNameByAddress: dict<string>,
    ~knownHeight: int,
    ~partitionId: string,
    ~selection: FetchState.selection,
    ~retry: int,
    ~logger: Pino.t,
  ) => promise<blockRangeFetchResponse>,
  createHeightSubscription?: (~onHeight: int => unit) => unit => unit,
  // Invoked by SourceManager once a rollback target is known so the source can
  // drop any state that may now point at an orphaned chain (e.g. RPC block cache).
  onReorg?: (~rollbackTargetBlock: int) => unit,
}
