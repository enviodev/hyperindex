open Belt

module Log = {
  type t = {
    address: Address.t,
    data: string,
    topics: array<EvmTypes.Hex.t>,
    logIndex: int,
  }

  let fieldNames = ["address", "data", "topics", "logIndex"]
}

type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
  rollbackGuard: option<HyperSyncClient.ResponseTypes.rollbackGuard>,
  events: array<HyperSyncClient.ResponseTypes.event>,
}

type logsQueryPageItem = {
  log: Log.t,
  block: Internal.eventBlock,
  transaction: Internal.eventTransaction,
}

type logsQueryPage = hyperSyncPage<logsQueryPageItem>

type missingParams = {
  queryName: string,
  missingParams: array<string>,
}
type queryError = UnexpectedMissingParams(missingParams)

exception HyperSyncQueryError(queryError)

let queryErrorToExn = queryError => {
  HyperSyncQueryError(queryError)
}

let queryErrorToMsq = (e: queryError): string => {
  switch e {
  | UnexpectedMissingParams({queryName, missingParams}) =>
    `${queryName} query failed due to unexpected missing params on response:
      ${missingParams->Js.Array2.joinWith(", ")}`
  }
}

type queryResponse<'a> = result<'a, queryError>
let mapExn = (queryResponse: queryResponse<'a>) =>
  switch queryResponse {
  | Ok(v) => Ok(v)
  | Error(err) => err->queryErrorToExn->Error
  }

module GetLogs = {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  let makeRequestBody = (
    ~fromBlock,
    ~toBlockInclusive,
    ~addressesWithTopics,
    ~fieldSelection,
  ): HyperSyncClient.QueryTypes.query => {
    fromBlock,
    toBlockExclusive: ?switch toBlockInclusive {
    | Some(toBlockInclusive) => Some(toBlockInclusive + 1)
    | None => None
    },
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
    missingParams->addMissingParams(Log.fieldNames, event.log, ~prefix="log")
    missingParams->addMissingParams(nonOptionalBlockFieldNames, event.block, ~prefix="block")
    missingParams->addMissingParams(
      nonOptionalTransactionFieldNames,
      event.transaction,
      ~prefix="transaction",
    )
    if missingParams->Array.length > 0 {
      raise(Error(UnexpectedMissingParams({missingParams: missingParams})))
    }

    //Topics can be nullable and still need to be filtered
    let logUnsanitized: Log.t = event.log->Utils.magic
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
  ): logsQueryPage => {
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
    page
  }

  let query = async (
    ~client: HyperSyncClient.t,
    ~fromBlock,
    ~toBlock,
    ~logSelections: array<LogSelection.t>,
    ~fieldSelection,
    ~nonOptionalBlockFieldNames,
    ~nonOptionalTransactionFieldNames,
  ): logsQueryPage => {
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

    let res = await client.getEvents(~query)
    if res.nextBlock <= fromBlock {
      // Might happen when /height response was from another instance of HyperSync
      raise(Error(WrongInstance))
    }

    res->convertResponse(~nonOptionalBlockFieldNames, ~nonOptionalTransactionFieldNames)
  }
}

module BlockData = {
  let makeRequestBody = (~fromBlock, ~toBlock): HyperSyncJsonApi.QueryTypes.postQueryBody => {
    fromBlock,
    toBlockExclusive: toBlock + 1,
    fieldSelection: {
      block: [Number, Hash, Timestamp],
    },
    includeAllBlocks: true,
  }

  let convertResponse = (res: HyperSyncJsonApi.ResponseTypes.queryResponse): queryResponse<
    array<ReorgDetection.blockDataWithTimestamp>,
  > => {
    res.data
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
                  }: ReorgDetection.blockDataWithTimestamp
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

  let rec queryBlockData = async (
    ~serverUrl,
    ~apiToken,
    ~fromBlock,
    ~toBlock,
    ~logger,
  ): queryResponse<array<ReorgDetection.blockDataWithTimestamp>> => {
    let body = makeRequestBody(~fromBlock, ~toBlock)

    let logger = Logging.createChildFrom(
      ~logger,
      ~params={
        "logType": "HyperSync get block hash query",
        "fromBlock": fromBlock,
        "toBlock": toBlock,
      },
    )

    let maybeSuccessfulRes = switch await Time.retryAsyncWithExponentialBackOff(() =>
      HyperSyncJsonApi.queryRoute->Rest.fetch(
        {
          "query": body,
          "token": apiToken,
        },
        ~client=Rest.client(serverUrl),
      )
    , ~logger) {
    | exception _ => None
    | res if res.nextBlock <= fromBlock => None
    | res => Some(res)
    }

    // If the block is not found, retry the query. This can occur since replicas of hypersync might not hack caught up yet
    switch maybeSuccessfulRes {
    | None => {
        let logger = Logging.createChild(~params={"url": serverUrl})
        let delayMilliseconds = 100
        logger->Logging.childInfo(
          `Block #${fromBlock->Int.toString} not found in HyperSync. HyperSync has multiple instances and it's possible that they drift independently slightly from the head. Indexing should continue correctly after retrying the query in ${delayMilliseconds->Int.toString}ms.`,
        )
        await Time.resolvePromiseAfterDelay(~delayMilliseconds)
        await queryBlockData(~serverUrl, ~apiToken, ~fromBlock, ~toBlock, ~logger)
      }
    | Some(res) =>
      switch res->convertResponse {
      | Error(_) as err => err
      | Ok(datas) if res.nextBlock <= toBlock => {
          let restRes = await queryBlockData(
            ~serverUrl,
            ~apiToken,
            ~fromBlock=res.nextBlock,
            ~toBlock,
            ~logger,
          )
          restRes->Result.map(rest => datas->Array.concat(rest))
        }
      | Ok(_) as ok => ok
      }
    }
  }

  let queryBlockDataMulti = async (~serverUrl, ~apiToken, ~blockNumbers, ~logger) => {
    switch blockNumbers->Array.get(0) {
    | None => Ok([])
    | Some(firstBlock) => {
        let fromBlock = ref(firstBlock)
        let toBlock = ref(firstBlock)
        let set = Utils.Set.make()
        for idx in 0 to blockNumbers->Array.length - 1 {
          let blockNumber = blockNumbers->Array.getUnsafe(idx)
          if blockNumber < fromBlock.contents {
            fromBlock := blockNumber
          }
          if blockNumber > toBlock.contents {
            toBlock := blockNumber
          }
          set->Utils.Set.add(blockNumber)->ignore
        }
        if toBlock.contents - fromBlock.contents > 1000 {
          Js.Exn.raiseError(
            `Invalid block data request. Range of block numbers is too large. Max range is 1000. Requested range: ${fromBlock.contents->Int.toString}-${toBlock.contents->Int.toString}`,
          )
        }
        let res = await queryBlockData(
          ~fromBlock=fromBlock.contents,
          ~toBlock=toBlock.contents,
          ~serverUrl,
          ~apiToken,
          ~logger,
        )
        let filtered = res->Result.map(datas => {
          datas->Array.keep(data => set->Utils.Set.delete(data.blockNumber))
        })
        if set->Utils.Set.size > 0 {
          Js.Exn.raiseError(
            `Invalid response. Failed to get block data for block numbers: ${set
              ->Utils.Set.toArray
              ->Js.Array2.joinWith(", ")}`,
          )
        }
        filtered
      }
    }
  }
}

let queryBlockData = (~serverUrl, ~apiToken, ~blockNumber, ~logger) =>
  BlockData.queryBlockData(
    ~serverUrl,
    ~apiToken,
    ~fromBlock=blockNumber,
    ~toBlock=blockNumber,
    ~logger,
  )->Promise.thenResolve(res => res->Result.map(res => res->Array.get(0)))
let queryBlockDataMulti = BlockData.queryBlockDataMulti
