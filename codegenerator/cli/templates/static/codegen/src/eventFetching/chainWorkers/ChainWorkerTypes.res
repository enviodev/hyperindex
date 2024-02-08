type chainId = int
exception UndefinedChainConfig(chainId)
exception IncorrectSyncSource(Config.syncSource)

/**
The args required for calling block range fetch
*/
type blockRangeFetchArgs = FetchState.nextQuery

/**
A set of stats for logging about the block range fetch
*/
type blockRangeFetchStats = {
  @as("total time elapsed (ms)") totalTimeElapsed: int,
  @as("parsing time (ms)") parsingTimeElapsed?: int,
  @as("page fetch time (ms)") pageFetchTime?: int,
  @as("average parse time per log (ms)") averageParseTimePerLog?: float,
}

type reorgGuard = {
  lastBlockScannedData: ReorgDetection.lastBlockScannedData,
  parentHash: option<string>,
}

/**
Thes response returned from a block range fetch
*/
type blockRangeFetchResponse<'a, 'b> = {
  currentBlockHeight: int,
  reorgGuard: reorgGuard,
  parsedQueueItems: array<Types.eventBatchQueueItem>,
  fromBlockQueried: int,
  heighestQueriedBlockNumber: int,
  latestFetchedBlockTimestamp: int,
  stats: blockRangeFetchStats,
  fetchStateRegisterId: FetchState.id,
  worker: Config.source<'a, 'b>,
}
