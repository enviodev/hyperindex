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
    ->Belt.Option.flatMap(exn => exn->Js.Exn.message)
    ->Belt.Option.getWithDefault("No message on exception")
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
    ~addressesWithTopics: ContractInterfaceManager.contractAddressesAndTopics,
  ): HyperSyncClient.QueryTypes.postQueryBody => {
    fromBlock,
    toBlockExclusive: toBlockInclusive + 1,
    logs: addressesWithTopics,
    fieldSelection: {
      log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
      block: Types.Block.querySelection,
      transaction: Types.Transaction.querySelection,
    },
  }

  let getMissingFields = (fieldNames, returnedObj, ~prefix) => {
    fieldNames->Belt.Array.keepMap(fieldName => {
      returnedObj
      ->(Utils.magic: 'a => Js.Dict.t<unknown>)
      ->Js.Dict.get(fieldName)
      ->Utils.optionMapNone(prefix ++ "." ++ fieldName)
    })
  }

  //Note this function can throw an error
  let convertEvent = (event: HyperSyncClient.ResponseTypes.event): logsQueryPageItem => {
    let missingParams =
      [
        getMissingFields(Types.Log.fieldNames, event.log, ~prefix="log"),
        getMissingFields(Types.Block.fieldNames, event.block, ~prefix="block"),
        getMissingFields(Types.Transaction.fieldNames, event.transaction, ~prefix="transaction"),
      ]->Belt.Array.concatMany

    if missingParams->Belt.Array.length > 0 {
      UnexpectedMissingParamsExn({
        queryName: "queryLogsPage HyperSync",
        missingParams,
      })->raise
    }

    //Topics can be nullable and still need to be filtered
    //Address is not yet checksummed (TODO this should be done in the client)
    let logUnsanitized: Types.Log.t = event.log->Utils.magic
    let topics = event.log.topics->Belt.Option.getUnsafe->Belt.Array.keepMap(Js.Nullable.toOption)
    let address = event.log.address->Belt.Option.getUnsafe->Viem.getAddressUnsafe
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

  let convertResponse = (res: HyperSyncClient.ResponseTypes.response): queryResponse<
    logsQueryPage,
  > => {
    try {
      let {nextBlock, archiveHeight, rollbackGuard} = res
      let items = res.events->Belt.Array.map(event => event->convertEvent)
      let page: logsQueryPage = {
        items,
        nextBlock,
        archiveHeight: archiveHeight->Belt.Option.getWithDefault(0), //Archive Height is only None if height is 0
        events: res.events,
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
    ~contractAddressesAndtopics: ContractInterfaceManager.contractAddressesAndTopics,
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

    let executeQuery = () => hyperSyncClient->HyperSyncClient.sendEventsReq(body)

    let res = await executeQuery->Time.retryAsyncWithExponentialBackOff(~logger=Some(logger))

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
      ->Belt.Array.flatMap(item => {
        item.blocks->Belt.Option.mapWithDefault([], blocks => {
          blocks->Belt.Array.map(
            block => {
              switch block {
              | {number: blockNumber, timestamp, hash: blockHash} =>
                let blockTimestamp = timestamp->BigInt.toInt->Belt.Option.getExn
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
                    block.number->Utils.optionMapNone("block.number"),
                    block.timestamp->Utils.optionMapNone("block.timestamp"),
                    block.hash->Utils.optionMapNone("block.hash"),
                  ]->Belt.Array.keepMap(p => p)

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
      ->Utils.mapArrayOfResults
    }
  }

  let rec queryBlockData = async (~serverUrl, ~blockNumber): queryResponse<
    option<ReorgDetection.blockData>,
  > => {
    let body = makeRequestBody(~blockNumber)

    let executeQuery = () => HyperSyncJsonApi.executeHyperSyncQuery(~postQueryBody=body, ~serverUrl)

    let logger = Logging.createChild(
      ~params={"type": "hypersync get blockhash query", "blockNumber": blockNumber},
    )

    let res = await executeQuery->Time.retryAsyncWithExponentialBackOff(~logger=Some(logger))

    // If the block is not found, retry the query. This can occur since replicas of hypersync might not hack caught up yet
    if res->Belt.Result.mapWithDefault(0, res => res.nextBlock) <= blockNumber {
      logger->Logging.childWarn(
        `Block #${blockNumber->Belt.Int.toString} not found in hypersync. Retrying query in 100ms.`,
      )
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=100)
      await queryBlockData(~serverUrl, ~blockNumber)
    } else {
      res->convertResponse->Belt.Result.map(res => res->Belt.Array.get(0))
    }
  }

  let queryBlockDataMulti = async (~serverUrl, ~blockNumbers) => {
    let res =
      await blockNumbers
      ->Belt.Array.map(blockNumber => queryBlockData(~blockNumber, ~serverUrl))
      ->Promise.all
    res
    ->Utils.mapArrayOfResults
    ->Belt.Result.map(Belt.Array.keepMap(_, v => v))
  }
}

let queryLogsPage = LogsQuery.queryLogsPage
let getHeightWithRetry = HeightQuery.getHeightWithRetry
let pollForHeightGtOrEq = HeightQuery.pollForHeightGtOrEq
let queryBlockData = BlockData.queryBlockData
let queryBlockDataMulti = BlockData.queryBlockDataMulti
