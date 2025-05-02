/**
A set of stats for logging about the block range fetch
*/
type blockRangeFetchStats = {
  @as("total time elapsed (ms)") totalTimeElapsed: int,
  @as("parsing time (ms)") parsingTimeElapsed?: int,
  @as("page fetch time (ms)") pageFetchTime?: int,
}

/**
Thes response returned from a block range fetch
*/
type blockRangeFetchResponse = {
  currentBlockHeight: int,
  reorgGuard: ReorgDetection.reorgGuard,
  parsedQueueItems: array<Internal.eventItem>,
  fromBlockQueried: int,
  latestFetchedBlockNumber: int,
  latestFetchedBlockTimestamp: int,
  stats: blockRangeFetchStats,
}

type getItemsRetry =
  | WithSuggestedToBlock({toBlock: int})
  | WithBackoff({message: string, backoffMillis: int})

type getItemsError =
  | UnsupportedSelection({message: string})
  | FailedGettingFieldSelection({exn: exn, blockNumber: int, logIndex: int, message: string})
  | FailedParsingItems({exn: exn, blockNumber: int, logIndex: int, message: string})
  | FailedGettingItems({exn: exn, attemptedToBlock: int, retry: getItemsRetry})

exception GetItemsError(getItemsError)

type sourceFor = Sync | Fallback
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
    ~indexingContracts: dict<FetchState.indexingContract>,
    ~currentBlockHeight: int,
    ~partitionId: string,
    ~selection: FetchState.selection,
    ~retry: int,
    ~logger: Pino.t,
  ) => promise<blockRangeFetchResponse>,
}
