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
  fetchBlockRange: (
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~contractAddressMapping: ContractAddressingMap.mapping,
    ~currentBlockHeight: int,
    ~partitionId: string,
    ~selection: FetchState.selection,
    ~logger: Pino.t,
  ) => promise<result<blockRangeFetchResponse, ErrorHandling.t>>,
}

let fetchBlockRange = async (
  source,
  ~fromBlock,
  ~toBlock,
  ~contractAddressMapping,
  ~partitionId,
  ~currentBlockHeight,
  ~selection,
) => {
  let logger = {
    let allAddresses = contractAddressMapping->ContractAddressingMap.getAllAddresses
    let addresses =
      allAddresses->Js.Array2.slice(~start=0, ~end_=3)->Array.map(addr => addr->Address.toString)
    let restCount = allAddresses->Array.length - addresses->Array.length
    if restCount > 0 {
      addresses->Js.Array2.push(`... and ${restCount->Int.toString} more`)->ignore
    }
    Logging.createChild(
      ~params={
        "chainId": source.chain->ChainMap.Chain.toChainId,
        "logType": "Block Range Query",
        "partitionId": partitionId,
        "source": source.name,
        "fromBlock": fromBlock,
        "toBlock": toBlock,
        "addresses": addresses,
      },
    )
  }

  (
    await source.fetchBlockRange(
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
      "msg": "Fetched block range from server",
      "latestFetchedBlockNumber": response.latestFetchedBlockNumber,
      "numEvents": response.parsedQueueItems->Array.length,
      "stats": response.stats,
    })
  })
}
