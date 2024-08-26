open Belt
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

type block = {
  hash: string,
  timestamp: int,
  blockNumber: int,
}

type item = {
  transactionId: string,
  contractId: Fuel.fuelAddress,
  receipt: Fuel.Receipt.t,
  receiptType: Fuel.receiptType,
  receiptIndex: int,
  block: block,
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
type queryError = UnexpectedMissingParams(missingParams) | QueryError(exn)

exception UnexpectedMissingParamsExn(missingParams)

let queryErrorToMsq = (e: queryError): string => {
  switch e {
  | UnexpectedMissingParams({queryName, missingParams}) =>
    `${queryName} query failed due to unexpected missing params on response:
      ${missingParams->Js.Array2.joinWith(", ")}`
  | QueryError(exn) =>
    exn
    ->Js.Exn.asJsExn
    ->Option.flatMap(exn => exn->Js.Exn.message)
    ->Option.getWithDefault("No message on exception")
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
        block: [Id, Height, Time],
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
    let {receipts, blocks} = response_data

    let blocksDict = Js.Dict.empty()
    blocks
    ->(Utils.magic: option<'a> => 'a)
    ->Belt.Array.forEach(block => {
      blocksDict->Js.Dict.set(block.height->(Utils.magic: int => string), block)
    })

    receipts->Belt.Array.map(receipt => {
      let block =
        blocksDict
        ->Js.Dict.get(receipt.blockHeight->(Utils.magic: int => string))
        ->getParam("Failed to find block associated to receipt")
      {
        transactionId: receipt.txId,
        block: {
          blockNumber: block.height,
          hash: block.id,
          timestamp: block.time,
        },
        contractId: receipt.rootContractId->getParam("receipt.rootContractId"),
        receipt: receipt->(Utils.magic: HyperFuelClient.FuelTypes.receipt => Fuel.Receipt.t),
        receiptType: receipt.receiptType,
        receiptIndex: receipt.receiptIndex,
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

    try {
      let res = await executeQuery->Time.retryAsyncWithExponentialBackOff(~logger=Some(logger))
      res->convertResponse
    } catch {
    | exn => Error(QueryError(exn))
    }
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

  let convertResponse = (res: HyperFuelJsonApi.ResponseTypes.queryResponse): queryResponse<
    blockTimestampPage,
  > => {
    let {nextBlock, archiveHeight, data} = res

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
                  block.height->Utils.Option.mapNone("block.height"),
                  block.time->Utils.Option.mapNone("block.time"),
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
    ->Utils.Array.transposeResults
    ->Belt.Result.map((items): blockTimestampPage => {
      nextBlock,
      archiveHeight,
      items,
    })
  }

  let queryBlockTimestampsPage = async (~serverUrl, ~fromBlock, ~toBlock): queryResponse<
    blockTimestampPage,
  > => {
    let body = makeRequestBody(~fromBlock, ~toBlockInclusive=toBlock)

    try {
      let res = await HyperFuelJsonApi.executeHyperSyncQuery->Rest.fetch(serverUrl, body)
      res->convertResponse
    } catch {
    | exn => Error(QueryError(exn))
    }
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
      try {
        height := await HyperSyncJsonApi.getArchiveHeight->Rest.fetch(serverUrl, ())
      } catch {
      | e => {
          logger->Logging.childWarn({
            "message": `Failed to get height from endpoint. Retrying in ${retryIntervalMillis.contents->Int.toString}ms...`,
            "error": e,
          })
          await Time.resolvePromiseAfterDelay(~delayMilliseconds=retryIntervalMillis.contents)
          retryIntervalMillis := retryIntervalMillis.contents * backOffMultiplicative
        }
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

  let convertResponse = (res: HyperFuelJsonApi.ResponseTypes.queryResponse): queryResponse<
    array<blockNumberAndHash>,
  > => {
    res.data
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
                  block.height->Utils.Option.mapNone("block.height"),
                  block.id->Utils.Option.mapNone("block.id"),
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
    ->Utils.Array.transposeResults
  }

  let queryBlockHash = async (~serverUrl, ~blockNumber): queryResponse<
    array<blockNumberAndHash>,
  > => {
    let body = makeRequestBody(~blockNumber)

    let logger = Logging.createChild(
      ~params={"type": "hypersync get blockhash query", "blockNumber": blockNumber},
    )

    try {
      let res = await Time.retryAsyncWithExponentialBackOff(
        () => HyperFuelJsonApi.executeHyperSyncQuery->Rest.fetch(serverUrl, body),
        ~logger=Some(logger),
      )
      res->convertResponse
    } catch {
    | exn => Error(QueryError(exn))
    }
  }

  let queryBlockHashes = async (~serverUrl, ~blockNumbers) => {
    let res =
      await blockNumbers
      ->Belt.Array.map(blockNumber => queryBlockHash(~blockNumber, ~serverUrl))
      ->Promise.all
    res
    ->Utils.Array.transposeResults
    ->Belt.Result.map(blockHashesNested => blockHashesNested->Belt.Array.concatMany)
  }
}

let queryLogsPage = LogsQuery.queryLogsPage
let queryBlockTimestampsPage = BlockTimestampQuery.queryBlockTimestampsPage
let getHeightWithRetry = HeightQuery.getHeightWithRetry
let pollForHeightGtOrEq = HeightQuery.pollForHeightGtOrEq
let queryBlockHashes = BlockHashes.queryBlockHashes
