module LogsQuery: HyperSyncTypes.LogsQuery = {
  type addressWithTopics = {
    address: Ethers.ethAddress,
    topics: array<array<Ethers.EventFilter.topic>>,
  }
  let makeRequestBody = (
    ~fromBlock,
    ~toBlockInclusive,
    ~addressesWithTopics: array<addressWithTopics>,
  ): Skar.QueryTypes.postQueryBody => {
    fromBlock,
    toBlockExclusive: toBlockInclusive + 1,
    logs: addressesWithTopics->Belt.Array.map(({address, topics}): Skar.QueryTypes.logParams => {
      {
        address: [address],
        topics,
      }
    }),
    fieldSelection: {
      log: [
        Address,
        BlockHash,
        BlockNumber,
        Data,
        LogIndex,
        TransactionHash,
        TransactionIndex,
        Topic0,
        Topic1,
        Topic2,
        Topic3,
        Removed,
      ],
      block: [Number, Timestamp],
    },
  }

  let convertResponse = (
    res: result<Skar.ResponseTypes.queryResponse, QueryHelpers.queryError>,
  ): HyperSyncTypes.queryResponse<HyperSyncTypes.logsQueryPage> => {
    switch res {
    | Error(e) => Error(HyperSyncTypes.QueryError(e))
    | Ok({nextBlock, archiveHeight, data}) =>
      data
      ->Belt.Array.flatMap(item => {
        switch (item.blocks, item.logs) {
        | (Some(blocks), Some(logs)) =>
          let blockTimestampsMap =
            blocks
            ->Belt.Array.keepMap(block => {
              switch (block.number, block.timestamp) {
              | (Some(number), Some(timestamp)) => Some((number->Belt.Int.toString, timestamp))
              | _ => None
              }
            })
            ->Js.Dict.fromArray

          logs->Belt.Array.map((log: Skar.ResponseTypes.logData) => {
            let blockTimestampOpt =
              log.blockNumber->Belt.Option.flatMap(
                number => blockTimestampsMap->Js.Dict.get(number->Belt.Int.toString),
              )

            switch (
              blockTimestampOpt,
              log.address,
              log.blockHash,
              log.blockNumber,
              log.data,
              log.index,
              log.transactionHash,
              log.transactionIndex,
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
                Some(removed),
              ) =>
              let topics =
                [log.topic0, log.topic1, log.topic2, log.topic3]->Belt.Array.keepMap(item => item)

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

            | _ =>
              let missingParams =
                [
                  blockTimestampOpt->Belt.Option.map(_ => "log.timestamp"),
                  log.address->Belt.Option.map(_ => "log.address"),
                  log.blockHash->Belt.Option.map(_ => "log.blockHash-"),
                  log.blockNumber->Belt.Option.map(_ => "log.blockNumber"),
                  log.data->Belt.Option.map(_ => "log.data"),
                  log.index->Belt.Option.map(_ => "log.index"),
                  log.transactionHash->Belt.Option.map(_ => "log.transactionHash"),
                  log.transactionIndex->Belt.Option.map(_ => "log.transactionIndex"),
                  log.removed->Belt.Option.map(_ => "log.removed"),
                ]->Belt.Array.keepMap(v => v)
              Error(
                HyperSyncTypes.UnexpectedMissingParams({
                  queryName: "queryLogsPage Skar",
                  missingParams,
                }),
              )
            }
          })
        | _ =>
          let missingParams =
            [
              item.blocks->Belt.Option.map(_ => "blocks"),
              item.logs->Belt.Option.map(_ => "logs"),
            ]->Belt.Array.keepMap(v => v)

          [
            Error(
              HyperSyncTypes.UnexpectedMissingParams({
                queryName: "queryLogsPage Skar",
                missingParams,
              }),
            ),
          ]
        }
      })
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
    //TODO: This needs to be modified so that only related topics to addresses get passed in
    let addressesWithTopics = addresses->Belt.Array.flatMap(address => {
      [{address, topics}]
      // let address = address->Ethers.ethAddressToStringLower->Obj.magic
      // topics->Belt.Array.flatMap(topicsInner =>
      //   topicsInner->Belt.Array.map(topic => {address, topics: []})
      // )
    })
    let body = makeRequestBody(~fromBlock, ~toBlockInclusive=toBlock, ~addressesWithTopics)

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
    transactions: [{}],
    fieldSelection: {
      block: [Timestamp, Number],
    },
  }

  let convertResponse = (
    res: result<Skar.ResponseTypes.queryResponse, QueryHelpers.queryError>,
  ): HyperSyncTypes.queryResponse<HyperSyncTypes.blockTimestampPage> => {
    switch res {
    | Error(e) => Error(HyperSyncTypes.QueryError(e))
    | Ok(successRes) =>
      let {nextBlock, archiveHeight, data} = successRes

      data
      ->Belt.Array.flatMap(item => {
        item.blocks->Belt.Option.mapWithDefault([], blocks => {
          blocks->Belt.Array.map(
            block => {
              switch (block.number, block.timestamp) {
              | (Some(blockNumber), Some(blockTimestamp)) =>
                let timestamp = blockTimestamp->Ethers.BigInt.toInt->Belt.Option.getExn
                Ok(
                  (
                    {
                      timestamp,
                      blockNumber,
                    }: HyperSyncTypes.blockNumberAndTimestamp
                  ),
                )
              | _ =>
                let missingParams =
                  [
                    block.number->Belt.Option.map(_ => "block.number"),
                    block.timestamp->Belt.Option.map(_ => "block.timestamp"),
                  ]->Belt.Array.keepMap(p => p)

                Error(
                  HyperSyncTypes.UnexpectedMissingParams({
                    queryName: "queryBlockTimestampsPage Skar",
                    missingParams,
                  }),
                )
              }
            },
          )
        })
      })
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
