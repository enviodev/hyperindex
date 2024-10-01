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

let blockRangeFetchStatsSchema: S.t<blockRangeFetchStats> = S.object(s => {
  totalTimeElapsed: s.field("totalTimeElapsed", S.int),
  parsingTimeElapsed: ?s.field("parsingTimeElapsed", S.null(S.int)),
  pageFetchTime: ?s.field("pageFetchTime", S.null(S.int)),
  averageParseTimePerLog: ?s.field("averageParseTimePerLog", S.null(S.float)),
})

type reorgGuard = {
  lastBlockScannedData: ReorgDetection.blockData,
  firstBlockParentNumberAndHash: option<ReorgDetection.blockNumberAndHash>,
}

/**
Thes response returned from a block range fetch
*/
type blockRangeFetchResponse = {
  currentBlockHeight: int,
  reorgGuard: reorgGuard,
  parsedQueueItems: array<Types.eventBatchQueueItem>,
  fromBlockQueried: int,
  heighestQueriedBlockNumber: int,
  latestFetchedBlockTimestamp: int,
  stats: blockRangeFetchStats,
  fetchStateRegisterId: FetchState.id,
  partitionId: PartitionedFetchState.partitionIndex,
}

module type S = {
  let name: string
  let chain: ChainMap.Chain.t
  let getBlockHashes: (
    ~blockNumbers: array<int>,
    ~logger: Pino.t,
  ) => promise<result<array<ReorgDetection.blockData>, exn>>
  let waitForBlockGreaterThanCurrentHeight: (
    ~currentBlockHeight: int,
    ~logger: Pino.t,
  ) => promise<int>
  let fetchBlockRange: (
    ~query: blockRangeFetchArgs,
    ~logger: Pino.t,
    ~currentBlockHeight: int,
    ~setCurrentBlockHeight: int => unit,
  ) => promise<result<blockRangeFetchResponse, ErrorHandling.t>>
}
