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

let getHeightWithRetry = async (~source, ~logger) => {
  //Amount the retry interval is multiplied between each retry
  let backOffMultiplicative = 2
  //Interval after which to retry request (multiplied by backOffMultiplicative between each retry)
  let retryIntervalMillis = ref(500)
  //height to be set in loop
  let height = ref(0)

  //Retry if the height is 0 (expect height to be greater)
  while height.contents <= 0 {
    switch await source.getHeightOrThrow() {
    | newHeight => height := newHeight
    | exception exn =>
      logger->Logging.childWarn({
        "msg": `Failed to get height from endpoint. Retrying in ${retryIntervalMillis.contents->Int.toString}ms...`,
        "error": exn->ErrorHandling.prettifyExn,
      })
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=retryIntervalMillis.contents)
      retryIntervalMillis := retryIntervalMillis.contents * backOffMultiplicative
    }
  }

  height.contents
}

//Poll for a height greater or equal to the given blocknumber.
//Used for waiting until there is a new block to index
let waitForNewBlock = async (~source, ~currentBlockHeight) => {
  let logger = Logging.createChild(
    ~params={
      "chainId": source.chain->ChainMap.Chain.toChainId,
      "logType": "Poll for block greater than current height",
      "currentBlockHeight": currentBlockHeight,
    },
  )
  logger->Logging.childTrace("Waiting for new blocks")

  let pollHeight = ref(await getHeightWithRetry(~source, ~logger))

  while pollHeight.contents <= currentBlockHeight {
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=source.pollingInterval)
    pollHeight := (await getHeightWithRetry(~source, ~logger))
  }

  pollHeight.contents
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
