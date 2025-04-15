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
type queryError = UnexpectedMissingParams(missingParams)

let queryErrorToMsq = (e: queryError): string => {
  switch e {
  | UnexpectedMissingParams({queryName, missingParams}) =>
    `${queryName} query failed due to unexpected missing params on response:
      ${missingParams->Js.Array2.joinWith(", ")}`
  }
}

type queryResponse<'a> = result<'a, queryError>

module GetLogs = {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  let makeRequestBody = (
    ~fromBlock,
    ~toBlockInclusive,
    ~recieptsSelection,
  ): HyperFuelClient.QueryTypes.query => {
    {
      fromBlock,
      toBlockExclusive: ?switch toBlockInclusive {
      | Some(toBlockInclusive) => Some(toBlockInclusive + 1)
      | None => None
      },
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
          To,
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
        Error(
          UnexpectedMissingParams({
            missingParams: [name],
          }),
        ),
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

  let convertResponse = (res: HyperFuelClient.queryResponseTyped): logsQueryPage => {
    let {nextBlock, ?archiveHeight} = res
    let page: logsQueryPage = {
      items: res.data->decodeLogQueryPageItems,
      nextBlock,
      archiveHeight: archiveHeight->Option.getWithDefault(0), // TODO: FIXME: Shouldn't have a default here
    }
    page
  }

  let query = async (~serverUrl, ~fromBlock, ~toBlock, ~recieptsSelection): logsQueryPage => {
    let query: HyperFuelClient.QueryTypes.query = makeRequestBody(
      ~fromBlock,
      ~toBlockInclusive=toBlock,
      ~recieptsSelection,
    )

    let hyperFuelClient = CachedClients.getClient(serverUrl)

    let res = await hyperFuelClient->HyperFuelClient.getSelectedData(query)
    if res.nextBlock <= fromBlock {
      // Might happen when /height response was from another instance of HyperSync
      raise(Error(WrongInstance))
    }
    res->convertResponse
  }
}

module BlockData = {
  let convertResponse = (res: HyperFuelClient.queryResponseTyped): option<
    ReorgDetection.blockDataWithTimestamp,
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
            }: ReorgDetection.blockDataWithTimestamp
          )
        }
      })
    })
  }

  let rec queryBlockData = async (~serverUrl, ~blockNumber, ~logger): option<
    ReorgDetection.blockDataWithTimestamp,
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

    let res = await executeQuery->Time.retryAsyncWithExponentialBackOff(~logger)

    // If the block is not found, retry the query. This can occur since replicas of hypersync might not hack caught up yet
    if res.nextBlock <= blockNumber {
      let logger = Logging.createChild(~params={"url": serverUrl})
      let delayMilliseconds = 100
      logger->Logging.childInfo(
        `Block #${blockNumber->Int.toString} not found in HyperFuel. HyperFuel has multiple instances and it's possible that they drift independently slightly from the head. Indexing should continue correctly after retrying the query in ${delayMilliseconds->Int.toString}ms.`,
      )
      await Time.resolvePromiseAfterDelay(~delayMilliseconds)
      await queryBlockData(~serverUrl, ~blockNumber, ~logger)
    } else {
      res->convertResponse
    }
  }
}

let queryBlockData = BlockData.queryBlockData

let heightRoute = Rest.route(() => {
  path: "/height",
  method: Get,
  input: _ => (),
  responses: [s => s.field("height", S.int)],
})
