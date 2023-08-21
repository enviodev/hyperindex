module LogsQuery = {
  let makeRequestBody = (
    ~fromBlock,
    ~toBlock,
    ~addresses,
    ~topics,
  ): EthArchive.QueryTypes.postQueryBody => {
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

  let convertResponse = (
    res: result<EthArchive.ResponseTypes.queryResponse, QueryHelpers.queryError>,
  ): HyperSyncTypes.queryResponse<HyperSyncTypes.logsQueryPage> => {
    switch res {
    | Error(e) => Error(HyperSyncTypes.QueryError(e))
    | Ok({nextBlock, archiveHeight, data}) =>
      data
      ->Belt.Array.flatMap(inner =>
        inner->Belt.Array.flatMap(item => {
          switch (item.block, item.logs) {
          | (Some(block), Some(logs)) =>
            logs->Belt.Array.map(
              (log: EthArchive.ResponseTypes.logData) => {
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

                  let pageItem: HyperSyncTypes.logsQueryPageItem = {log, blockTimestamp}
                  Ok(pageItem)

                | _ => Error(HyperSyncTypes.UnexpectedMissingParams)
                }
              },
            )
          | _ => [Error(HyperSyncTypes.UnexpectedMissingParams)]
          }
        })
      )
      ->Utils.mapArrayOfResults
      ->Belt.Result.map((items): HyperSyncTypes.logsQueryPage => {
        items,
        nextBlock,
        archiveHeight,
      })
    }
  }

  let queryLogsPage = async (
    ~serverUrl,
    ~fromBlock,
    ~toBlock,
    ~addresses: array<Ethers.ethAddress>,
    ~topics,
  ): HyperSyncTypes.queryResponse<HyperSyncTypes.logsQueryPage> => {
    let body = makeRequestBody(~fromBlock, ~toBlock, ~addresses, ~topics)

    let res = await EthArchive.executeEthArchiveQuery(~postQueryBody=body, ~serverUrl)

    res->convertResponse
  }
}

module BlockTimestampQuery = {
  let makeRequestBody = (~fromBlock, ~toBlock): EthArchive.QueryTypes.postQueryBody => {
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

  let convertResponse = (
    res: result<EthArchive.ResponseTypes.queryResponse, QueryHelpers.queryError>,
  ): HyperSyncTypes.queryResponse<HyperSyncTypes.blockTimestampPage> => {
    switch res {
    | Error(e) => Error(HyperSyncTypes.QueryError(e))
    | Ok(successRes) =>
      let {nextBlock, archiveHeight, data} = successRes

      data
      ->Belt.Array.flatMap(inner =>
        inner->Belt.Array.map(item =>
          switch item.block {
          | Some({timestamp: ?Some(blockTimestamp), number: ?Some(blockNumber)}) =>
            let timestamp = blockTimestamp->Ethers.BigInt.toInt->Belt.Option.getExn
            Ok(
              (
                {
                  timestamp,
                  blockNumber,
                }: HyperSyncTypes.blockNumberAndTimestamp
              ),
            )

          | _ => Error(HyperSyncTypes.UnexpectedMissingParams)
          }
        )
      )
      ->Utils.mapArrayOfResults
      ->Belt.Result.map((items): HyperSyncTypes.blockTimestampPage => {
        nextBlock,
        archiveHeight,
        items,
      })
    }
  }

  let queryBlockTimestampsPage = async (
    ~serverUrl,
    ~fromBlock,
    ~toBlock,
  ): HyperSyncTypes.queryResponse<HyperSyncTypes.blockTimestampPage> => {
    let body = makeRequestBody(~fromBlock, ~toBlock)

    let res = await EthArchive.executeEthArchiveQuery(~postQueryBody=body, ~serverUrl)

    res->convertResponse
  }
}

module HeightQuery: HyperSyncTypes.HeightQuery = {
  let getHeightWithRetry = async (~serverUrl, ~logger) => {
    //Amount the retry interval is multiplied between each retry
    let backOffMultiplicative = 2
    //Interval after which to retry request (multiplied by backOffMultiplicative between each retry)
    let retryIntervalMillis = ref(500)
    //height to be set in loop
    let height = ref(0)

    //Retry if the heigth is 0 (expect height to be greater)
    while height.contents <= 0 {
      let res = await EthArchive.getArchiveHeight(~serverUrl)
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

  //Poll for a height greater or equal to the given blocknumber.
  //Used for waiting until there is a new block to index
  let pollForHeightGtOrEq = async (~serverUrl, ~blockNumber, ~logger) => {
    let pollHeight = ref(await getHeightWithRetry(~serverUrl, ~logger))
    let pollIntervalMillis = 100

    while pollHeight.contents <= blockNumber {
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=pollIntervalMillis)
      pollHeight := (await getHeightWithRetry(~serverUrl, ~logger))
    }

    pollHeight.contents
  }
}
