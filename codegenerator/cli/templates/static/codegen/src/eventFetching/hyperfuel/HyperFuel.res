//Manage clients in cache so we don't need to reinstantiate each time
//Ideally client should be passed in as a param to the functions but
//we are still sharing the same signature with eth archive query builder

module CachedClients = {
  let cache: Js.Dict.t<HyperFuelClient.t> = Js.Dict.empty()

  let getClient = url => {
    switch cache->Js.Dict.get(url) {
    | Some(client) => client
    | None =>
      let newClient = HyperFuelClient.make({url: url})
      cache->Js.Dict.set(url, newClient)
      newClient
    }
  }
}

type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
}

type item = {
  transactionId: string,
  blockHeight: int,
  contractId: Fuel.fuelAddress,
  receipt: Fuel.Receipt.t,
  receiptType: Fuel.receiptType,
  receiptIndex: int,
  blockTimestamp: int,
  txOrigin: option<Ethers.ethAddress>,
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
type logsQueryPage = hyperSyncPage<item>

type contractReceiptQuery = {
  addresses: array<Fuel.fuelAddress>,
  logIds: array<string>,
}

type missingParams = {
  queryName: string,
  missingParams: array<string>,
}
type queryError =
  UnexpectedMissingParams(missingParams) | QueryError(HyperFuelJsonApi.Query.queryError)

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

module LogsQuery = {
  let makeRequestBody = (
    ~fromBlock,
    ~toBlockInclusive,
    ~contractsReceiptQuery: array<contractReceiptQuery>,
  ): HyperFuelClient.QueryTypes.query => {
    let receipts = contractsReceiptQuery->Js.Array2.map((
      q
    ): HyperFuelClient.QueryTypes.receiptSelection => {
      rootContractId: q.addresses,
      receiptType: [LogData],
      rb: q.logIds,
      // only transactions with status 1 (success)
      txStatus: [1],
    })
    {
      fromBlock,
      toBlockExclusive: toBlockInclusive + 1,
      receipts,
      fieldSelection: {
        receipt: [
          TxId,
          BlockHeight,
          RootContractId,
          // ContractId,
          Data,
          ReceiptIndex,
          ReceiptType,
          Ra,
          Rb,
        ],
        // block: [Id, Height, Time],
        transaction: [Id, Time],
      },
    }
  }

  let getParam = (param, name) => {
    switch param {
    | Some(v) => v
    | None =>
      raise(
        UnexpectedMissingParamsExn({
          queryName: "queryLogsPage HyperFuel",
          missingParams: [name],
        }),
      )
    }
  }

  //Note this function can throw an error
  let decodeLogQueryPageItems = (response_data: HyperFuelClient.queryResponseDataTyped): array<
    item,
  > => {
    let {receipts, transactions} = response_data

    let txBlocktimeDictionary = Js.Dict.empty()
    transactions->Belt.Array.forEach(tx => {
      Js.Dict.set(txBlocktimeDictionary, tx.id, tx.time)
    })

    receipts->Belt.Array.map(receipt => {
      let blockTimestamp =
        txBlocktimeDictionary
        ->Js.Dict.get(receipt.txId)
        ->getParam("tx associated to receipt not found")
      {
        transactionId: receipt.txId,
        blockHeight: receipt.blockHeight,
        contractId: receipt.rootContractId->getParam("receipt.rootContractId"),
        receipt: receipt->(Utils.magic: HyperFuelClient.FuelTypes.receipt => Fuel.Receipt.t),
        receiptType: receipt.receiptType,
        receiptIndex: receipt.receiptIndex,
        blockTimestamp,
        txOrigin: None,
      }
    })
  }

  let convertResponse = (res: HyperFuelClient.queryResponseTyped): queryResponse<logsQueryPage> => {
    try {
      let {nextBlock, ?archiveHeight} = res
      let page: logsQueryPage = {
        items: res.data->decodeLogQueryPageItems,
        nextBlock,
        archiveHeight: archiveHeight->Belt.Option.getWithDefault(0), // TODO: FIXME: Shouldn't have a default here
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
    ~contractsReceiptQuery,
  ): queryResponse<logsQueryPage> => {
    Logging.debug({
      "msg": "querying logs",
      "fromBlock": fromBlock,
      "toBlock": toBlock,
      "contractsReceiptQuery": contractsReceiptQuery,
    })
    let query: HyperFuelClient.QueryTypes.query = makeRequestBody(
      ~fromBlock,
      ~toBlockInclusive=toBlock,
      ~contractsReceiptQuery,
    )

    let hyperFuelClient = CachedClients.getClient(serverUrl)

    let logger = Logging.createChild(
      ~params={"type": "hypersync query", "fromBlock": fromBlock, "serverUrl": serverUrl},
    )

    let executeQuery = () => hyperFuelClient->HyperFuelClient.getSelectedData(query)

    let res = await executeQuery->Time.retryAsyncWithExponentialBackOff(~logger=Some(logger))

    res->convertResponse
  }
}

module BlockTimestampQuery = {
  let makeRequestBody = (
    ~fromBlock,
    ~toBlockInclusive,
  ): HyperFuelJsonApi.QueryTypes.postQueryBody => {
    fromBlock,
    toBlockExclusive: toBlockInclusive + 1,
    fieldSelection: {
      receipt: [Ra],
      // block: [Timestamp, Number],
    },
    // includeAllBlocks: true,
  }

  let convertResponse = (
    res: result<HyperFuelJsonApi.ResponseTypes.queryResponse, HyperFuelJsonApi.Query.queryError>,
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
              switch (block.height, block.time) {
              | (Some(blockNumber), Some(blockTimestamp)) =>
                let timestamp = blockTimestamp
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
                    block.height->Utils.optionMapNone("block.height"),
                    block.time->Utils.optionMapNone("block.time"),
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

    let res = await HyperFuelJsonApi.executeHyperSyncQuery(~postQueryBody=body, ~serverUrl)

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
      let res = await HyperFuelJsonApi.getArchiveHeight(~serverUrl)
      Logging.debug({"msg": "querying height", "response": res})
      switch res {
      | Ok({height: newHeight}) => height := newHeight
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
  let makeRequestBody = (~blockNumber): HyperFuelJsonApi.QueryTypes.postQueryBody => {
    fromBlock: blockNumber,
    toBlockExclusive: blockNumber + 1,
    fieldSelection: {
      receipt: [Ra, Rb, BlockHeight, RootContractId, Data, ReceiptType],
      // block: [Number, Hash],
      transaction: [Id, Time],
    },
    // includeAllBlocks: true,
  }

  let convertResponse = (
    res: result<HyperFuelJsonApi.ResponseTypes.queryResponse, HyperFuelJsonApi.Query.queryError>,
  ): queryResponse<array<blockNumberAndHash>> => {
    switch res {
    | Error(e) => Error(QueryError(e))
    | Ok(successRes) =>
      successRes.data
      ->Belt.Array.flatMap(item => {
        item.blocks->Belt.Option.mapWithDefault([], blocks => {
          blocks->Belt.Array.map(
            block => {
              switch (block.height, block.id) {
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
                    block.height->Utils.optionMapNone("block.height"),
                    block.id->Utils.optionMapNone("block.id"),
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

    let executeQuery = () => HyperFuelJsonApi.executeHyperSyncQuery(~postQueryBody=body, ~serverUrl)

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
