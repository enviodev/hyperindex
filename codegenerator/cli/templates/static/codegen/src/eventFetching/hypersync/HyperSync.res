type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
}

type logsQueryPageItem = {
  log: Ethers.log,
  blockTimestamp: int,
}

type blockNumberAndTimestamp = {
  timestamp: int,
  blockNumber: int,
}

type blockNumberAndHash = {
  blockNumber: int,
  hash: string,
}

type blockTimestampPage = hyperSyncPage<blockNumberAndTimestamp>
type logsQueryPage = hyperSyncPage<logsQueryPageItem>

type missingParams = {
  queryName: string,
  missingParams: array<string>,
}
type queryError = UnexpectedMissingParams(missingParams) | QueryError(QueryHelpers.queryError)

exception UnexpectedMissingParamsExn(missingParams)

let queryErrorToMsq = (e: queryError): string => {
  let getMsgFromExn = (exn: exn) =>
    exn
    ->Js.Exn.asJsExn
    ->Belt.Option.flatMap(exn => exn->Js.Exn.message)
    ->Belt.Option.getWithDefault("No message on exception")
  switch e {
  | UnexpectedMissingParams({queryName, missingParams}) =>
    `${queryName} query failed due to unexpected missing params on response:
      ${missingParams->Js.Array2.joinWith(", ")}`
  | QueryError(e) =>
    switch e {
    | Deserialize(e) =>
      `Failed to deserialize response: ${e.message}
        JSON data:
          ${e.value->Js.Json.stringify}`
    | FailedToFetch(e) =>
      let msg = e->getMsgFromExn

      `Failed during fetch query: ${msg}`
    | FailedToParseJson(e) =>
      let msg = e->getMsgFromExn
      `Failed during parse of json: ${msg}`
    | Other(e) =>
      let msg = e->getMsgFromExn
      `Failed for unknown reason during query: ${msg}`
    }
  }
}

type queryResponse<'a> = result<'a, queryError>

//Manage clients in cache so we don't need to reinstantiate each time
//Ideally client should be passed in as a param to the functions but
//we are still sharing the same signature with eth archive query builder
module CachedClients = {
  let cache: Js.Dict.t<HyperSyncClient.t> = Js.Dict.empty()

  let getClient = url => {
    switch cache->Js.Dict.get(url) {
    | Some(client) => client
    | None =>
      let newClient = HyperSyncClient.make({url: url})

      cache->Js.Dict.set(url, newClient)

      newClient
    }
  }
}

module LogsQuery = {
  let makeRequestBody = (
    ~fromBlock,
    ~toBlockInclusive,
    ~addressesWithTopics: ContractInterfaceManager.contractAdressesAndTopics,
  ): HyperSyncJsonApi.QueryTypes.postQueryBody => {
    fromBlock,
    toBlockExclusive: toBlockInclusive + 1,
    logs: addressesWithTopics,
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

  //Note this function can throw an error
  let checkFields = (event: HyperSyncClient.ResponseTypes.event): logsQueryPageItem => {
    let log = event.log

    let blockTimestamp = event.block->Belt.Option.flatMap(b => b.timestamp)

    switch (
      blockTimestamp,
      log.address,
      log.blockHash,
      log.blockNumber,
      log.data,
      log.index,
      log.transactionHash,
      log.transactionIndex,
      log.removed,
      log.topics,
    ) {
    | (
        Some(blockTimestamp),
        Some(address),
        Some(blockHash),
        Some(blockNumber),
        Some(data),
        Some(index),
        Some(transactionHash),
        Some(transactionIndex),
        Some(removed),
        Some(topics),
      ) =>
      let topics = topics->Belt.Array.keepMap(Js.Nullable.toOption)

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

      let pageItem: logsQueryPageItem = {log, blockTimestamp}
      pageItem
    | _ =>
      let missingParams =
        [
          blockTimestamp->Utils.optionMapNone("log.timestamp"),
          log.address->Utils.optionMapNone("log.address"),
          log.blockHash->Utils.optionMapNone("log.blockHash-"),
          log.blockNumber->Utils.optionMapNone("log.blockNumber"),
          log.data->Utils.optionMapNone("log.data"),
          log.index->Utils.optionMapNone("log.index"),
          log.transactionHash->Utils.optionMapNone("log.transactionHash"),
          log.transactionIndex->Utils.optionMapNone("log.transactionIndex"),
          log.removed->Utils.optionMapNone("log.removed"),
        ]->Belt.Array.keepMap(v => v)

      UnexpectedMissingParamsExn({
        queryName: "queryLogsPage HyperSync",
        missingParams,
      })->raise
    }
  }

  let convertResponse = (res: HyperSyncClient.ResponseTypes.response): queryResponse<
    logsQueryPage,
  > => {
    try {
      let {nextBlock, archiveHeight} = res
      let items = res.events->Belt.Array.map(event => event->checkFields)
      let page: logsQueryPage = {
        items,
        nextBlock,
        archiveHeight,
      }

      Ok(page)
    } catch {
    | UnexpectedMissingParamsExn(err) => Error(UnexpectedMissingParams(err))
    }
  }

  let queryLogsPage = async (
    ~serverUrl,
    ~fromBlock,
    ~toBlock,
    ~contractAddressesAndtopics: ContractInterfaceManager.contractAdressesAndTopics,
  ): queryResponse<logsQueryPage> => {
    //TODO: This needs to be modified so that only related topics to addresses get passed in
    let body = makeRequestBody(
      ~fromBlock,
      ~toBlockInclusive=toBlock,
      ~addressesWithTopics=contractAddressesAndtopics,
    )

    let hyperSyncClient = CachedClients.getClient(serverUrl)

    let logger = Logging.createChild(
      ~params={"type": "hypersync query", "fromBlock": fromBlock, "serverUrl": serverUrl},
    )

    let executeQuery = () => hyperSyncClient->HyperSyncClient.sendReq(body)

    let res = await executeQuery->Time.retryAsyncWithExponentialBackOff(~logger=Some(logger))

    res->convertResponse
  }
}

module BlockTimestampQuery = {
  let makeRequestBody = (
    ~fromBlock,
    ~toBlockInclusive,
  ): HyperSyncJsonApi.QueryTypes.postQueryBody => {
    fromBlock,
    toBlockExclusive: toBlockInclusive + 1,
    fieldSelection: {
      block: [Timestamp, Number],
    },
    includeAllBlocks: true,
  }

  let convertResponse = (
    res: result<HyperSyncJsonApi.ResponseTypes.queryResponse, QueryHelpers.queryError>,
  ): queryResponse<blockTimestampPage> => {
    switch res {
    | Error(e) => Error(QueryError(e))
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
                    }: blockNumberAndTimestamp
                  ),
                )
              | _ =>
                let missingParams =
                  [
                    block.number->Utils.optionMapNone("block.number"),
                    block.timestamp->Utils.optionMapNone("block.timestamp"),
                  ]->Belt.Array.keepMap(p => p)

                Error(
                  UnexpectedMissingParams({
                    queryName: "queryBlockTimestampsPage HyperSync",
                    missingParams,
                  }),
                )
              }
            },
          )
        })
      })
      ->Utils.mapArrayOfResults
      ->Belt.Result.map((items): blockTimestampPage => {
        nextBlock,
        archiveHeight,
        items,
      })
    }
  }

  let queryBlockTimestampsPage = async (~serverUrl, ~fromBlock, ~toBlock): queryResponse<
    blockTimestampPage,
  > => {
    let body = makeRequestBody(~fromBlock, ~toBlockInclusive=toBlock)

    let res = await HyperSyncJsonApi.executeHyperSyncQuery(~postQueryBody=body, ~serverUrl)

    res->convertResponse
  }
}

module HeightQuery = {
  let getHeightWithRetry = async (~serverUrl, ~logger) => {
    //Amount the retry interval is multiplied between each retry
    let backOffMultiplicative = 2
    //Interval after which to retry request (multiplied by backOffMultiplicative between each retry)
    let retryIntervalMillis = ref(500)
    //height to be set in loop
    let height = ref(0)

    //Retry if the heigth is 0 (expect height to be greater)
    while height.contents <= 0 {
      let res = await HyperSyncJsonApi.getArchiveHeight(~serverUrl)
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

module BlockHashes = {
  let makeRequestBody = (~blockNumber): HyperSyncJsonApi.QueryTypes.postQueryBody => {
    fromBlock: blockNumber,
    toBlockExclusive: blockNumber + 1,
    fieldSelection: {
      block: [Number, Hash],
    },
    includeAllBlocks: true,
  }

  let convertResponse = (
    res: result<HyperSyncJsonApi.ResponseTypes.queryResponse, QueryHelpers.queryError>,
  ): queryResponse<array<blockNumberAndHash>> => {
    switch res {
    | Error(e) => Error(QueryError(e))
    | Ok(successRes) =>
      successRes.data
      ->Belt.Array.flatMap(item => {
        item.blocks->Belt.Option.mapWithDefault([], blocks => {
          blocks->Belt.Array.map(
            block => {
              switch (block.number, block.hash) {
              | (Some(blockNumber), Some(hash)) =>
                Ok(
                  (
                    {
                      blockNumber,
                      hash,
                    }: blockNumberAndHash
                  ),
                )
              | _ =>
                let missingParams =
                  [
                    block.number->Utils.optionMapNone("block.number"),
                    block.hash->Utils.optionMapNone("block.hash"),
                  ]->Belt.Array.keepMap(p => p)

                Error(
                  UnexpectedMissingParams({
                    queryName: "query block hash HyperSync",
                    missingParams,
                  }),
                )
              }
            },
          )
        })
      })
      ->Utils.mapArrayOfResults
    }
  }

  let queryBlockHash = async (~serverUrl, ~blockNumber): queryResponse<
    array<blockNumberAndHash>,
  > => {
    let body = makeRequestBody(~blockNumber)

    let executeQuery = () => HyperSyncJsonApi.executeHyperSyncQuery(~postQueryBody=body, ~serverUrl)

    let logger = Logging.createChild(
      ~params={"type": "hypersync get blockhash query", "blockNumber": blockNumber},
    )

    let res = await executeQuery->Time.retryAsyncWithExponentialBackOff(~logger=Some(logger))

    res->convertResponse
  }

  let queryBlockHashes = async (~serverUrl, ~blockNumbers) => {
    let res =
      await blockNumbers
      ->Belt.Array.map(blockNumber => queryBlockHash(~blockNumber, ~serverUrl))
      ->Promise.all
    res
    ->Utils.mapArrayOfResults
    ->Belt.Result.map(blockHashesNested => blockHashesNested->Belt.Array.concatMany)
  }
}

let queryLogsPage = LogsQuery.queryLogsPage
let queryBlockTimestampsPage = BlockTimestampQuery.queryBlockTimestampsPage
let getHeightWithRetry = HeightQuery.getHeightWithRetry
let pollForHeightGtOrEq = HeightQuery.pollForHeightGtOrEq
let queryBlockHashes = BlockHashes.queryBlockHashes
