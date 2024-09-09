open Belt

//Manage clients in cache so we don't need to reinstantiate each time
//Ideally client should be passed in as a param to the functions but
//we are still sharing the same signature with eth archive query builder

module CachedClients = {
  let cache: Js.Dict.t<HyperFuelClient.t> = Js.Dict.empty()

  let getClient = url => {
    switch cache->Utils.Dict.dangerouslyGetNonOption(url) {
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
  contractId: Address.t,
  receipt: Fuel.Receipt.t,
  receiptType: Fuel.receiptType,
  receiptIndex: int,
  block: block,
  txOrigin: option<Address.t>,
}

type blockNumberAndHash = {
  blockNumber: int,
  hash: string,
}

type logsQueryPage = hyperSyncPage<item>

type contractReceiptQuery = {
  addresses: array<Address.t>,
  rb: array<bigint>,
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
      rb: q.rb,
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
        ->Utils.Dict.dangerouslyGetNonOption(receipt.blockHeight->(Utils.magic: int => string))
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

module BlockData = {
  let convertResponse = (res: HyperFuelClient.queryResponseTyped): option<
    ReorgDetection.blockData,
  > => {
    res.data.blocks->Option.flatMap(blocks => {
      blocks
      ->Array.get(0)
      ->Option.map(block => {
        switch block {
        | {height: blockNumber, time: timestamp, id: blockHash} =>
          (
            {
              blockTimestamp: timestamp,
              blockNumber,
              blockHash,
            }: ReorgDetection.blockData
          )
        }
      })
    })
  }

  let rec queryBlockData = async (~serverUrl, ~blockNumber, ~logger): option<
    ReorgDetection.blockData,
  > => {
    let query: HyperFuelClient.QueryTypes.query = {
      fromBlock: blockNumber,
      toBlockExclusive: blockNumber + 1,
      // TODO: Theoretically it should work without the outputs filter, but it doesn't for some reason
      outputs: [%raw(`{}`)],
      fieldSelection: {
        block: [Height, Id, Time],
      },
      includeAllBlocks: true,
    }

    let hyperFuelClient = CachedClients.getClient(serverUrl)

    let logger = Logging.createChildFrom(
      ~logger,
      ~params={"logType": "hypersync get blockhash query", "blockNumber": blockNumber},
    )

    let executeQuery = () => hyperFuelClient->HyperFuelClient.getSelectedData(query)

    let res = await executeQuery->Time.retryAsyncWithExponentialBackOff(~logger=Some(logger))

    // If the block is not found, retry the query. This can occur since replicas of hypersync might not hack caught up yet
    if res.nextBlock <= blockNumber {
      let logger = Logging.createChild(~params={"url": serverUrl})
      logger->Logging.childWarn(
        `Block #${blockNumber->Int.toString} not found in hypersync. HyperSync runs multiple instances of hypersync and it is possible that they drift independently slightly from the head. Retrying query in 100ms.`,
      )
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=100)
      await queryBlockData(~serverUrl, ~blockNumber, ~logger)
    } else {
      res->convertResponse
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
    ->Utils.Array.transposeResults
    ->Belt.Result.map(blockHashesNested => blockHashesNested->Belt.Array.concatMany)
  }
}

let queryLogsPage = LogsQuery.queryLogsPage
let queryBlockData = BlockData.queryBlockData
let getHeightWithRetry = HeightQuery.getHeightWithRetry
let pollForHeightGtOrEq = HeightQuery.pollForHeightGtOrEq
let queryBlockHashes = BlockHashes.queryBlockHashes
