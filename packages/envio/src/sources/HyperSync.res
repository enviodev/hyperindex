let reraisIfRateLimited = exn =>
  switch exn->JsExn.anyToExnInternal {
  | JsExn(e) =>
    switch e->JsExn.message {
    | Some(msg) if msg->String.startsWith("RATE_LIMITED:") =>
      let resetMs =
        msg
        ->String.slice(~start=13, ~end=msg->String.length)
        ->Int.fromString
        ->Option.getOr(1000)
      throw(Source.RateLimited({resetMs: resetMs}))
    | _ => ()
    }
  | _ => ()
  }

type logsQueryPage = {
  items: array<HyperSyncClient.EventItems.item>,
  // Block headers referenced by `items`, deduplicated by block number.
  blocks: array<HyperSyncClient.EventItems.blockHeader>,
  nextBlock: int,
  archiveHeight: int,
  rollbackGuard: option<HyperSyncClient.ResponseTypes.rollbackGuard>,
  // Page store owning this page's raw transactions.
  transactionStore: TransactionStore.t,
  // Page store owning this page's raw blocks.
  blockStore: BlockStore.t,
}

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
    ~maxNumLogs,
  ): HyperSyncClient.QueryTypes.query => {
    fromBlock,
    toBlockExclusive: ?switch toBlockInclusive {
    | Some(toBlockInclusive) => Some(toBlockInclusive + 1)
    | None => None
    },
    logs: addressesWithTopics,
    fieldSelection,
    maxNumLogs,
  }

  // Rust encodes structured failures as a JSON payload in the napi error's
  // message: `{"kind":"MissingFields","fields":["block.timestamp", ...]}`.
  // JSON.parse + shape check is the recovery protocol — no string-grepping
  // on anyhow's Debug format.
  let extractMissingParams = (exn: exn): option<array<string>> => {
    let message = switch exn {
    | JsExn(jsExn) => jsExn->JsExn.message
    | _ => None
    }
    switch message {
    | None => None
    | Some(msg) =>
      switch msg->JSON.parseOrThrow->JSON.Decode.object {
      | exception _ => None
      | None => None
      | Some(obj) =>
        switch (obj->Dict.get("kind"), obj->Dict.get("fields")) {
        | (Some(String("MissingFields")), Some(Array(fields))) =>
          Some(fields->Array.filterMap(JSON.Decode.string))
        | _ => None
        }
      }
    }
  }

  let query = async (
    ~client: HyperSyncClient.t,
    ~fromBlock,
    ~toBlock,
    ~logSelections: array<LogSelection.t>,
    ~fieldSelection,
    ~maxNumLogs,
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
      ~maxNumLogs,
    )

    let (res, transactionStore, blockStore) = switch await client.getEventItems(~query) {
    | res => res
    | exception exn =>
      reraisIfRateLimited(exn)
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
      items: res.items,
      blocks: res.blocks,
      nextBlock: res.nextBlock,
      archiveHeight: res.archiveHeight->Option.getOr(0), //Archive Height is only None if height is 0
      rollbackGuard: res.rollbackGuard,
      transactionStore,
      blockStore,
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
    | exception exn =>
      reraisIfRateLimited(exn)
      None
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
