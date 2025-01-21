open Belt

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
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~contractAddressMapping: ContractAddressingMap.mapping,
    ~currentBlockHeight: int,
    ~partitionId: string,
    ~selection: FetchState.selection,
    ~logger: Pino.t,
  ) => promise<result<blockRangeFetchResponse, ErrorHandling.t>>
}

let waitForNewBlock = (source, ~currentBlockHeight, ~logger) => {
  let module(Source: S) = source
  let logger = Logging.createChildFrom(
    ~logger,
    ~params={
      "logType": "Poll for block greater than current height",
      "currentBlockHeight": currentBlockHeight,
    },
  )
  logger->Logging.childTrace("Waiting for new blocks")
  Source.waitForBlockGreaterThanCurrentHeight(~currentBlockHeight, ~logger)
}

let fetchBlockRange = async (
  source,
  ~fromBlock,
  ~toBlock,
  ~contractAddressMapping,
  ~partitionId,
  ~chain,
  ~currentBlockHeight,
  ~selection,
  ~logger,
) => {
  let module(Source: S) = source
  let logger = {
    let allAddresses = contractAddressMapping->ContractAddressingMap.getAllAddresses
    let addresses =
      allAddresses->Js.Array2.slice(~start=0, ~end_=3)->Array.map(addr => addr->Address.toString)
    let restCount = allAddresses->Array.length - addresses->Array.length
    if restCount > 0 {
      addresses->Js.Array2.push(`... and ${restCount->Int.toString} more`)->ignore
    }
    Logging.createChildFrom(
      ~logger,
      ~params={
        "chainId": chain->ChainMap.Chain.toChainId,
        "logType": "Block Range Query",
        "partitionId": partitionId,
        "workerType": Source.name,
        "fromBlock": fromBlock,
        "toBlock": toBlock,
        "addresses": addresses,
      },
    )
  }
  (
    await Source.fetchBlockRange(
      ~fromBlock,
      ~toBlock,
      ~contractAddressMapping,
      ~partitionId,
      ~logger,
      ~selection,
      ~currentBlockHeight,
    )
  )->Utils.Result.forEach(response => {
    logger->Logging.childTrace({
      "message": "Fetched block range from server",
      "latestFetchedBlockNumber": response.latestFetchedBlockNumber,
      "numEvents": response.parsedQueueItems->Array.length,
      "stats": response.stats,
    })
  })
}
