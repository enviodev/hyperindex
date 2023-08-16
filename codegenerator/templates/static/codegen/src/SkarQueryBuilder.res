%%private(let envSafe = EnvSafe.make())

let subsquidEthArchiveServerUrl = "https://eth.archive.subsquid.io"
let skarEndpoint = EnvUtils.getStringEnvVar(
  ~envSafe,
  ~fallback=subsquidEthArchiveServerUrl,
  "SKAR_ENDPOINT",
)

type skarPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
}

module LogsQuery = {
  let makeRequestBody = (
    ~fromBlock,
    ~toBlock,
    ~addresses,
    ~topics,
  ): Skar.SkarQuery.postQueryBody => {
    fromBlock,
    toBlock,
    logs: [
      {
        address: addresses,
        topics,
        fieldSelection: {
          log: {
            address: true,
            blockHash: true,
            blockNumber: true,
            data: true,
            index: true,
            transactionHash: true,
            transactionIndex: true,
            topics: true,
            removed: true,
          },
          block: {
            timestamp: true,
          },
        },
      },
    ],
  }

  type skarLogsQueryPageItem = {
    log: Ethers.log,
    blockTimestamp: int,
  }

  type skarLogsQueryPage = skarPage<skarLogsQueryPageItem>

  exception UnexpectedMissingParams

  let queryLogsPage = async (
    ~fromBlock,
    ~toBlock,
    ~addresses: array<Ethers.ethAddress>,
    ~topics,
  ): skarLogsQueryPage => {
    let body = makeRequestBody(~fromBlock, ~toBlock, ~addresses, ~topics)

    let res = await Skar.executeSkarQuery(~postQueryBody=body, ~serverUrl=skarEndpoint)

    let unsafeRes = res->Belt.Result.getExn
    let {nextBlock, archiveHeight} = unsafeRes

    let items = unsafeRes.data->Belt.Array.flatMap(inner =>
      inner->Belt.Array.flatMap(item => {
        let (block, logs) = switch (item.block, item.logs) {
        | (Some(block), Some(logs)) => (block, logs)
        | _ => raise(UnexpectedMissingParams)
        }
        let eventLogs = logs->Belt.Array.map(
          (log: Skar.SkarResponse.logData): skarLogsQueryPageItem => {
            switch (
              block.timestamp,
              log.address,
              log.blockHash,
              log.blockNumber,
              log.data,
              log.index,
              log.transactionHash,
              log.transactionIndex,
              log.topics,
              log.removed,
            ) {
            | (
                Some(timestamp),
                Some(address),
                Some(blockHash),
                Some(blockNumber),
                Some(data),
                Some(index),
                Some(transactionHash),
                Some(transactionIndex),
                Some(topics),
                Some(removed),
              ) =>
              let log: Ethers.log = {
                data,
                blockNumber,
                blockHash,
                address: Ethers.getAddressFromStringUnsafe(address),
                transactionHash,
                transactionIndex,
                logIndex: index,
                topics,
                removed,
              }

              let blockTimestamp =
                timestamp->Ethers.BigInt.toString->Belt.Int.fromString->Belt.Option.getExn

              let pageItem: skarLogsQueryPageItem = {log, blockTimestamp}
              pageItem

            | _ => UnexpectedMissingParams->raise
            }
          },
        )
        eventLogs
      })
    )

    {
      items,
      nextBlock,
      archiveHeight,
    }
  }
}

module BlockTimestampQuery = {
  type blockNumberAndTimestamp = {
    timestamp: int,
    blockNumber: int,
  }

  type blockTimestampPage = skarPage<blockNumberAndTimestamp>
  let makeRequestBody = (~fromBlock, ~toBlock): Skar.SkarQuery.postQueryBody => {
    fromBlock,
    toBlock,
    transactions: [
      {
        fieldSelection: {
          block: {
            timestamp: true,
            number: true,
          },
        },
      },
    ],
  }

  let queryBlockTimestampsPage = async (~fromBlock, ~toBlock): Belt.Result.t<
    blockTimestampPage,
    _,
  > => {
    let body = makeRequestBody(~fromBlock, ~toBlock)

    let res = await Skar.executeSkarQuery(~postQueryBody=body, ~serverUrl=skarEndpoint)

    switch res {
    | Error(e) => Error(e)
    | Ok(successRes) =>
      let {nextBlock, archiveHeight, data} = successRes

      let items =
        data
        ->Belt.Array.flatMap(inner =>
          inner->Belt.Array.map(item =>
            item.block->Belt.Option.flatMap(
              (block): option<blockNumberAndTimestamp> =>
                switch (block.timestamp, block.number) {
                | (Some(timestamp), Some(blockNumber)) =>
                  timestamp
                  ->Ethers.BigInt.toInt
                  ->Belt.Option.map(timestamp => {timestamp, blockNumber})
                | _ => None
                },
            )
          )
        )
        ->Belt.Array.keepMap(item => item)

      Ok({
        nextBlock,
        archiveHeight,
        items,
      })
    }
  }
}

module HeightQuery = {
  let getHeightWithRetry = async (~logger) => {
    //Amount the retry interval is multiplied between each retry
    let backOffMultiplicative = 2
    //Interval after which to retry request (multiplied by backOffMultiplicative between each retry)
    let retryIntervalMillis = ref(500)
    //height to be set in loop
    let height = ref(0)

    //Retry if the heigth is 0 (expect height to be greater)
    while height.contents <= 0 {
      let res = await Skar.getArchiveHeight(~serverUrl=skarEndpoint)
      switch res {
      | Ok(h) => height := h
      | Error(e) =>
        logger->Logging.childWarn({
          "message": `Failed to get height from endpoint. Retrying in ${retryIntervalMillis.contents->Belt.Int.toString}ms...`,
          "error": e,
        })
        await Time.resolvePromiseAfterDelay(~delayMilliseconds=retryIntervalMillis.contents)
        retryIntervalMillis := retryIntervalMillis.contents * backOffMultiplicative
      }
    }

    height.contents
  }

  //Poll for a height greater than the given blocknumber.
  //Used for waiting until there is a new block to index
  let pollForHeightGreaterThan = async (~blockNumber, ~logger) => {
    let pollHeight = ref(await getHeightWithRetry(~logger))
    let pollIntervalMillis = 100

    while pollHeight.contents <= blockNumber {
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=pollIntervalMillis)
      pollHeight := (await getHeightWithRetry(~logger))
    }

    pollHeight.contents
  }
}
