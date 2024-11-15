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
  id: string,
  time: int,
  height: int,
}

type item = {
  transactionId: string,
  contractId: Address.t,
  receipt: Fuel.Receipt.t,
  receiptIndex: int,
  block: block,
}

type blockNumberAndHash = {
  blockNumber: int,
  hash: string,
}

type logsQueryPage = hyperSyncPage<item>

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
    ->Option.flatMap(exn => exn->Js.Exn.message)
    ->Option.getWithDefault("No message on exception")
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
    ~recieptsSelection,
  ): HyperFuelClient.QueryTypes.query => {
    {
      fromBlock,
      toBlockExclusive: toBlockInclusive + 1,
      receipts: recieptsSelection,
      fieldSelection: {
        receipt: [
          TxId,
          BlockHeight,
          RootContractId,
          Data,
          ReceiptIndex,
          ReceiptType,
          Rb,
          // TODO: Include them only when there's a mint/burn/transferOut receipt selection
          SubId,
          Val,
          Amount,
          ToAddress,
          AssetId,
          To
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
    ->Array.forEach(block => {
      blocksDict->Js.Dict.set(block.height->(Utils.magic: int => string), block)
    })

    let items = []

    receipts->Array.forEach(receipt => {
      switch receipt.rootContractId {
      | None => ()
      | Some(contractId) => {
          let block =
            blocksDict
            ->Utils.Dict.dangerouslyGetNonOption(receipt.blockHeight->(Utils.magic: int => string))
            ->getParam("Failed to find block associated to receipt")
          items
          ->Array.push({
            transactionId: receipt.txId,
            block: {
              height: block.height,
              id: block.id,
              time: block.time,
            },
            contractId,
            receipt: receipt->(Utils.magic: HyperFuelClient.FuelTypes.receipt => Fuel.Receipt.t),
            receiptIndex: receipt.receiptIndex,
          })
          ->ignore
        }
      }
    })
    items
  }

  let convertResponse = (res: HyperFuelClient.queryResponseTyped): queryResponse<logsQueryPage> => {
    try {
      let {nextBlock, ?archiveHeight} = res
      let page: logsQueryPage = {
        items: res.data->decodeLogQueryPageItems,
        nextBlock,
        archiveHeight: archiveHeight->Option.getWithDefault(0), // TODO: FIXME: Shouldn't have a default here
      }

      Ok(page)
    } catch {
    | UnexpectedMissingParamsExn(err) => Error(UnexpectedMissingParams(err))
    }
  }

  let queryLogsPage = async (~serverUrl, ~fromBlock, ~toBlock, ~recieptsSelection): queryResponse<
    logsQueryPage,
  > => {
    let query: HyperFuelClient.QueryTypes.query = makeRequestBody(
      ~fromBlock,
      ~toBlockInclusive=toBlock,
      ~recieptsSelection,
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
      // FIXME: Theoretically it should work without the outputs filter, but it doesn't for some reason
      outputs: [%raw(`{}`)],
      // FIXME: Had to add inputs {} as well, since it failed on block 1211599 during wildcard Call indexing
      inputs: [%raw(`{}`)],
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

    //Retry if the height is 0 (expect height to be greater)
    while height.contents <= 0 {
      let res = await HyperFuelJsonApi.getArchiveHeight(~serverUrl)
      switch res {
      | Ok({height: newHeight}) => height := newHeight
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

let queryLogsPage = LogsQuery.queryLogsPage
let queryBlockData = BlockData.queryBlockData
let getHeightWithRetry = HeightQuery.getHeightWithRetry
let pollForHeightGtOrEq = HeightQuery.pollForHeightGtOrEq
