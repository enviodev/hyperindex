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
}

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
  parsedQueueItems: array<Internal.eventItem>,
  fromBlockQueried: int,
  latestFetchedBlockNumber: int,
  latestFetchedBlockTimestamp: int,
  stats: blockRangeFetchStats,
  fetchStateRegisterId: FetchState.id,
  partitionId: PartitionedFetchState.partitionId,
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
    ~isPreRegisteringDynamicContracts: bool,
  ) => promise<result<blockRangeFetchResponse, ErrorHandling.t>>
}

let waitForNewBlock = (
  chainWorker,
  ~currentBlockHeight,
  ~logger,
) => {
  let module(ChainWorker: S) = chainWorker
  let logger = Logging.createChildFrom(
    ~logger,
    ~params={
      "logType": "Poll for block greater than current height",
      "currentBlockHeight": currentBlockHeight,
    },
  )
  logger->Logging.childTrace("Waiting for new blocks")
  ChainWorker.waitForBlockGreaterThanCurrentHeight(
    ~currentBlockHeight,
    ~logger,
  )
}
