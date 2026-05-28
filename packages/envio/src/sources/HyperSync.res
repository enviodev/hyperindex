module Log = HyperSyncClient.EventItems.Log

type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
  rollbackGuard: option<HyperSyncClient.ResponseTypes.rollbackGuard>,
}

type logsQueryPageItem = {
  log: Log.t,
  block: HyperSyncClient.ResponseTypes.block,
  transaction: Internal.eventTransaction,
  params: Nullable.t<Internal.eventParams>,
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
      ${missingParams->Array.joinUnsafe(", ")}`
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

  // Rust's MissingFieldsError surfaces as a JS Error whose `.message` Debug
  // string starts with this marker. Detecting it here lets the source treat
  // it as ImpossibleForTheQuery, matching the pre-refactor behavior.
  let missingFieldsMarker = "MissingFields: "

  let extractMissingParams = (exn: exn): option<array<string>> => {
    let message = switch exn {
    | JsExn(jsExn) => jsExn->JsExn.message
    | _ => None
    }
    switch message {
    | Some(msg) =>
      switch msg->String.indexOf(missingFieldsMarker) {
      | -1 => None
      | start =>
        let tail = msg->String.slice(~start=start + missingFieldsMarker->String.length)
        let comma = tail->String.indexOf("\n")
        let list = comma == -1 ? tail : tail->String.slice(~start=0, ~end=comma)
        Some(list->String.split(","))
      }
    | None => None
    }
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

    let res = switch await client.getEventItems(
      ~query,
      ~nonOptionalBlockFieldNames,
      ~nonOptionalTransactionFieldNames,
    ) {
    | res => res
    | exception exn =>
      switch extractMissingParams(exn) {
      | Some(missingParams) => throw(Error(UnexpectedMissingParams({missingParams: missingParams})))
      | None => throw(exn)
      }
    }
    if res.nextBlock <= fromBlock {
      // Might happen when /height response was from another instance of HyperSync
      throw(Error(WrongInstance))
    }

    {
      items: res.items->(
        Utils.magic: array<HyperSyncClient.EventItems.item> => array<logsQueryPageItem>
      ),
      nextBlock: res.nextBlock,
      archiveHeight: res.archiveHeight->Option.getOr(0), //Archive Height is only None if height is 0
      rollbackGuard: res.rollbackGuard,
    }
  }
}

module BlockData = {
  let makeRequestBody = (~fromBlock, ~toBlock): HyperSyncClient.QueryTypes.query => {
    fromBlock,
    toBlockExclusive: toBlock + 1,
    fieldSelection: {
      block: [Number, Hash, Timestamp],
    },
    includeAllBlocks: true,
  }

  let convertResponse = (res: HyperSyncClient.queryResponse): queryResponse<
    array<ReorgDetection.blockDataWithTimestamp>,
  > => {
    res.data.blocks
    ->Array.map(block => {
      switch block {
      | {number: blockNumber, hash: blockHash, timestamp: blockTimestamp} =>
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
          ]->Array.filterMap(p => p)

        Error(
          UnexpectedMissingParams({
            queryName: "query block data HyperSync",
            missingParams,
          }),
        )
      }
    })
    ->Utils.Array.transposeResults
  }

  let rec queryBlockData = async (
    ~client: HyperSyncClient.t,
    ~fromBlock,
    ~toBlock,
    ~sourceName,
    ~chainId,
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

    Prometheus.SourceRequestCount.increment(~sourceName, ~chainId, ~method="getBlockHashes")
    let maybeSuccessfulRes = switch await client.get(~query=body) {
    | exception _ => None
    | res if res.nextBlock <= fromBlock => None
    | res => Some(res)
    }

    // If the block is not found, retry the query. This can occur since replicas of hypersync might not have caught up yet
    switch maybeSuccessfulRes {
    | None => {
        let delayMilliseconds = 100
        logger->Logging.childInfo(
          `Block #${fromBlock->Int.toString} not found in HyperSync. HyperSync has multiple instances and it's possible that they drift independently slightly from the head. Indexing should continue correctly after retrying the query in ${delayMilliseconds->Int.toString}ms.`,
        )
        await Time.resolvePromiseAfterDelay(~delayMilliseconds)
        await queryBlockData(~client, ~fromBlock, ~toBlock, ~sourceName, ~chainId, ~logger)
      }
    | Some(res) =>
      switch res->convertResponse {
      | Error(_) as err => err
      | Ok(datas) if res.nextBlock <= toBlock => {
          let restRes = await queryBlockData(
            ~client,
            ~fromBlock=res.nextBlock,
            ~toBlock,
            ~sourceName,
            ~chainId,
            ~logger,
          )
          restRes->Result.map(rest => datas->Array.concat(rest))
        }
      | Ok(_) as ok => ok
      }
    }
  }

  let queryBlockDataMulti = async (
    ~client: HyperSyncClient.t,
    ~blockNumbers,
    ~sourceName,
    ~chainId,
    ~logger,
  ) => {
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
          JsError.throwWithMessage(
            `Invalid block data request. Range of block numbers is too large. Max range is 1000. Requested range: ${fromBlock.contents->Int.toString}-${toBlock.contents->Int.toString}`,
          )
        }
        let res = await queryBlockData(
          ~fromBlock=fromBlock.contents,
          ~toBlock=toBlock.contents,
          ~client,
          ~sourceName,
          ~chainId,
          ~logger,
        )
        let filtered = res->Result.map(datas => {
          datas->Array.filter(data => set->Utils.Set.delete(data.blockNumber))
        })
        if set->Utils.Set.size > 0 {
          JsError.throwWithMessage(
            `Invalid response. Failed to get block data for block numbers: ${set
              ->Utils.Set.toArray
              ->Array.joinUnsafe(", ")}`,
          )
        }
        filtered
      }
    }
  }
}

let queryBlockData = (~client, ~blockNumber, ~sourceName, ~chainId, ~logger) =>
  BlockData.queryBlockData(
    ~client,
    ~fromBlock=blockNumber,
    ~toBlock=blockNumber,
    ~sourceName,
    ~chainId,
    ~logger,
  )->Promise.thenResolve(res => res->Result.map(res => res->Array.get(0)))
let queryBlockDataMulti = BlockData.queryBlockDataMulti
