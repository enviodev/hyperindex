open Belt
type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
  rollbackGuard: option<HyperSyncClient.ResponseTypes.rollbackGuard>,
  events: array<HyperSyncClient.ResponseTypes.event>,
}

type logsQueryPageItem = {
  log: Types.Log.t,
  block: Types.Block.t,
  transaction: Types.Transaction.t,
}

type logsQueryPage = hyperSyncPage<logsQueryPageItem>

type missingParams = {
  queryName: string,
  missingParams: array<string>,
}
type queryError = UnexpectedMissingParams(missingParams) | QueryError(QueryHelpers.queryError)

exception HyperSyncQueryError(queryError)

let queryErrorToExn = queryError => {
  HyperSyncQueryError(queryError)
}

exception UnexpectedMissingParamsExn(missingParams)

let queryErrorToMsq = (e: queryError): string => {
  let getMsgFromExn = (exn: exn) =>
    exn
    ->Js.Exn.asJsExn
    ->Option.flatMap(exn => exn->Js.Exn.message)
    ->Option.getWithDefault("No message on exception")
  switch e {
  | UnexpectedMissingParams({queryName, missingParams}) =>
    `${queryName} query failed due to unexpected missing params on response:
      ${missingParams->Js.Array2.joinWith(", ")}`
  | QueryError(e) =>
    switch e {
    | Deserialize(data, e) =>
      `Failed to deserialize response at ${e.path->S.Path.toString}: ${e->S.Error.reason}
  JSON data:
    ${data->Js.Json.stringify}`
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
let mapExn = (queryResponse: queryResponse<'a>) =>
  switch queryResponse {
  | Ok(v) => Ok(v)
  | Error(err) => err->queryErrorToExn->Error
  }

let getExn = (queryResponse: queryResponse<'a>) =>
  switch queryResponse {
  | Ok(v) => v
  | Error(err) => err->queryErrorToExn->raise
  }

//Manage clients in cache so we don't need to reinstantiate each time
//Ideally client should be passed in as a param to the functions but
//we are still sharing the same signature with eth archive query builder
module CachedClients = {
  let cache: dict<HyperSyncClient.t> = Js.Dict.empty()

  let getClient = url => {
    switch cache->Utils.Dict.dangerouslyGetNonOption(url) {
    | Some(client) => client
    | None =>
      let newClient = HyperSyncClient.make(~url)

      cache->Js.Dict.set(url, newClient)

      newClient
    }
  }
}

module LogsQuery = {
  let makeRequestBody = (
    ~fromBlock,
    ~toBlockInclusive,
    ~addressesWithTopics,
    ~fieldSelection,
  ): HyperSyncClient.QueryTypes.query => {
    fromBlock,
    toBlockExclusive: toBlockInclusive + 1,
    logs: addressesWithTopics,
    fieldSelection,
  }

  let addMissingParams = (acc, fieldNames, returnedObj, ~prefix) => {
    fieldNames->Array.forEach(fieldName => {
      switch returnedObj
      ->(Utils.magic: 'a => Js.Dict.t<unknown>)
      ->Utils.Dict.dangerouslyGetNonOption(fieldName) {
      | Some(_) => ()
      | None => acc->Array.push(prefix ++ "." ++ fieldName)->ignore
      }
    })
  }

  //Note this function can throw an error
  let convertEvent = (
    event: HyperSyncClient.ResponseTypes.event,
    ~nonOptionalBlockFieldNames,
    ~nonOptionalTransactionFieldNames,
  ): logsQueryPageItem => {
    let missingParams = []
    missingParams->addMissingParams(Types.Log.fieldNames, event.log, ~prefix="log")
    missingParams->addMissingParams(nonOptionalBlockFieldNames, event.block, ~prefix="block")
    missingParams->addMissingParams(
      nonOptionalTransactionFieldNames,
      event.transaction,
      ~prefix="transaction",
    )
    if missingParams->Array.length > 0 {
      UnexpectedMissingParamsExn({
        queryName: "queryLogsPage HyperSync",
        missingParams,
      })->raise
    }

    //Topics can be nullable and still need to be filtered
    //Address is not yet checksummed (TODO this should be done in the client)
    let logUnsanitized: Types.Log.t = event.log->Utils.magic
    let topics = event.log.topics->Option.getUnsafe->Array.keepMap(Js.Nullable.toOption)
    let address = event.log.address->Option.getUnsafe
    let log = {
      ...logUnsanitized,
      topics,
      address,
    }

    {
      log,
      block: event.block->Utils.magic,
      transaction: event.transaction->Utils.magic,
    }
  }

  let convertResponse = (
    res: HyperSyncClient.ResponseTypes.eventResponse,
    ~nonOptionalBlockFieldNames,
    ~nonOptionalTransactionFieldNames,
  ): queryResponse<logsQueryPage> => {
    try {
      let {nextBlock, archiveHeight, rollbackGuard} = res
      let items =
        res.data->Array.map(item =>
          item->convertEvent(~nonOptionalBlockFieldNames, ~nonOptionalTransactionFieldNames)
        )
      let page: logsQueryPage = {
        items,
        nextBlock,
        archiveHeight: archiveHeight->Option.getWithDefault(0), //Archive Height is only None if height is 0
        events: res.data,
        rollbackGuard,
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
    ~logSelections: array<LogSelection.t>,
    ~fieldSelection,
    ~nonOptionalBlockFieldNames,
    ~nonOptionalTransactionFieldNames,
  ): queryResponse<logsQueryPage> => {
    let addressesWithTopics = logSelections->Array.flatMap(({addresses, topicSelections}) =>
      topicSelections->Array.map(({topic0, topic1, topic2, topic3}) => {
        let topics = HyperSyncClient.QueryTypes.makeTopicSelection(
          ~topic0,
          ~topic1,
          ~topic2,
          ~topic3,
        )
        HyperSyncClient.QueryTypes.makeLogSelection(~address=addresses, ~topics)
      })
    )

    let query = makeRequestBody(
      ~fromBlock,
      ~toBlockInclusive=toBlock,
      ~addressesWithTopics,
      ~fieldSelection,
    )

    let hyperSyncClient = CachedClients.getClient(serverUrl)

    let logger = Logging.createChild(
      ~params={"type": "hypersync query", "fromBlock": fromBlock, "serverUrl": serverUrl},
    )

    let executeQuery = () => hyperSyncClient.getEvents(~query)

    let res = await executeQuery->Time.retryAsyncWithExponentialBackOff(~logger=Some(logger))

    res->convertResponse(~nonOptionalBlockFieldNames, ~nonOptionalTransactionFieldNames)
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

    //Retry if the height is 0 (expect height to be greater)
    while height.contents <= 0 {
      let res = await HyperSyncJsonApi.getArchiveHeight(~serverUrl)
      switch res {
      | Ok(h) => height := h
      | Error(e) =>
        logger->Logging.childWarn({
          "message": `Failed to get height from endpoint. Retrying in ${retryIntervalMillis.contents->Int.toString}ms...`,
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

module BlockData = {
  let makeRequestBody = (~blockNumber): HyperSyncJsonApi.QueryTypes.postQueryBody => {
    fromBlock: blockNumber,
    toBlockExclusive: blockNumber + 1,
    fieldSelection: {
      block: [Number, Hash, Timestamp],
    },
    includeAllBlocks: true,
  }

  let convertResponse = (
    res: result<HyperSyncJsonApi.ResponseTypes.queryResponse, QueryHelpers.queryError>,
  ): queryResponse<array<ReorgDetection.blockData>> => {
    switch res {
    | Error(e) => Error(QueryError(e))
    | Ok(successRes) =>
      successRes.data
      ->Array.flatMap(item => {
        item.blocks->Option.mapWithDefault([], blocks => {
          blocks->Array.map(
            block => {
              switch block {
              | {number: blockNumber, timestamp, hash: blockHash} =>
                let blockTimestamp = timestamp->BigInt.toInt->Option.getExn
                Ok(
                  (
                    {
                      blockTimestamp,
                      blockNumber,
                      blockHash,
                    }: ReorgDetection.blockData
                  ),
                )
              | _ =>
                let missingParams =
                  [
                    block.number->Utils.Option.mapNone("block.number"),
                    block.timestamp->Utils.Option.mapNone("block.timestamp"),
                    block.hash->Utils.Option.mapNone("block.hash"),
                  ]->Array.keepMap(p => p)

                Error(
                  UnexpectedMissingParams({
                    queryName: "query block data HyperSync",
                    missingParams,
                  }),
                )
              }
            },
          )
        })
      })
      ->Utils.Array.transposeResults
    }
  }

  let rec queryBlockData = async (~serverUrl, ~blockNumber, ~logger): queryResponse<
    option<ReorgDetection.blockData>,
  > => {
    let body = makeRequestBody(~blockNumber)

    let executeQuery = () => HyperSyncJsonApi.executeHyperSyncQuery(~postQueryBody=body, ~serverUrl)

    let logger = Logging.createChildFrom(
      ~logger,
      ~params={"logType": "hypersync get blockhash query", "blockNumber": blockNumber},
    )

    let res = await executeQuery->Time.retryAsyncWithExponentialBackOff(~logger=Some(logger))

    // If the block is not found, retry the query. This can occur since replicas of hypersync might not hack caught up yet
    if res->Result.mapWithDefault(0, res => res.nextBlock) <= blockNumber {
      let logger = Logging.createChild(~params={"url": serverUrl})
      logger->Logging.childWarn(
        `Block #${blockNumber->Int.toString} not found in hypersync. HyperSync runs multiple instances of hypersync and it is possible that they drift independently slightly from the head. Retrying query in 100ms.`,
      )
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=100)
      await queryBlockData(~serverUrl, ~blockNumber, ~logger)
    } else {
      res->convertResponse->Result.map(res => res->Array.get(0))
    }
  }

  let queryBlockDataMulti = async (~serverUrl, ~blockNumbers, ~logger) => {
    let res =
      await blockNumbers
      ->Array.map(blockNumber => queryBlockData(~blockNumber, ~serverUrl, ~logger))
      ->Promise.all
    res
    ->Utils.Array.transposeResults
    ->Result.map(Array.keepMap(_, v => v))
  }
}

let queryLogsPage = LogsQuery.queryLogsPage
let getHeightWithRetry = HeightQuery.getHeightWithRetry
let pollForHeightGtOrEq = HeightQuery.pollForHeightGtOrEq
let queryBlockData = BlockData.queryBlockData
let queryBlockDataMulti = BlockData.queryBlockDataMulti
