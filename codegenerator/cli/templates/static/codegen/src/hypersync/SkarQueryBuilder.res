module LogsQuery: HyperSyncTypes.LogsQuery = {
  let makeRequestBody = (
    ~fromBlock,
    ~toBlockInclusive,
    ~addresses,
    ~topics,
  ): Skar.QueryTypes.postQueryBody => {
    fromBlock,
    toBlockExclusive: toBlockInclusive + 1,
    logs: [
      {
        address: addresses,
        topics,
        fieldSelection: {
          log: [
            #address,
            #block_hash,
            #block_number,
            #data,
            #index,
            #transaction_hash,
            #transaction_index,
            #topics,
            #removed,
          ],
          block: [#timestamp],
        },
      },
    ],
  }

  let convertResponse = (
    res: result<Skar.ResponseTypes.queryResponse, QueryHelpers.queryError>,
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
              (log: Skar.ResponseTypes.logData) => {
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
    let body = makeRequestBody(~fromBlock, ~toBlockInclusive=toBlock, ~addresses, ~topics)

    let res = await Skar.executeSkarQuery(~postQueryBody=body, ~serverUrl)

    //Use ethArchive converter since the response is currently
    //Using the same layout
    res->convertResponse
  }
}

module BlockTimestampQuery: HyperSyncTypes.BlockTimestampQuery = {
  let makeRequestBody = (~fromBlock, ~toBlockInclusive): Skar.QueryTypes.postQueryBody => {
    fromBlock,
    toBlockExclusive: toBlockInclusive + 1,
    transactions: [
      {
        fieldSelection: {
          block: [#timestamp, #number],
        },
      },
    ],
  }

  let convertResponse = (
    res: result<Skar.ResponseTypes.queryResponse, QueryHelpers.queryError>,
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
    let body = makeRequestBody(~fromBlock, ~toBlockInclusive=toBlock)

    let res = await Skar.executeSkarQuery(~postQueryBody=body, ~serverUrl)

    //Use ethArchive converter since the response is currently
    //Using the same layout
    res->convertResponse
  }
}

module HeightQuery: HyperSyncTypes.HeightQuery = {
  let getHeightWithRetry = EthArchiveQueryBuilder.HeightQuery.getHeightWithRetry

  //Poll for a height greater than the given blocknumber.
  //Used for waiting until there is a new block to index
  let pollForHeightGtOrEq = EthArchiveQueryBuilder.HeightQuery.pollForHeightGtOrEq
}
