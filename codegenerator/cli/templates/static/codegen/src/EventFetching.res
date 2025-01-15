exception QueryTimout(string)
exception EventRoutingFailed

let getKnownBlock = (provider, blockNumber) =>
  provider
  ->Ethers.JsonRpcProvider.getBlock(blockNumber)
  ->Promise.then(blockNullable =>
    switch blockNullable->Js.Nullable.toOption {
    | Some(block) => Promise.resolve(block)
    | None =>
      Promise.reject(
        Js.Exn.raiseError(`RPC returned null for blockNumber ${blockNumber->Belt.Int.toString}`),
      )
    }
  )

let rec getKnownBlockWithBackoff = async (~provider, ~blockNumber, ~backoffMsOnFailure) =>
  switch await getKnownBlock(provider, blockNumber) {
  | exception err =>
    Logging.warn({
      "err": err,
      "msg": `Issue while running fetching batch of events from the RPC. Will wait ${backoffMsOnFailure->Belt.Int.toString}ms and try again.`,
      "type": "EXPONENTIAL_BACKOFF",
    })
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=backoffMsOnFailure)
    await getKnownBlockWithBackoff(
      ~provider,
      ~blockNumber,
      ~backoffMsOnFailure=backoffMsOnFailure * 2,
    )
  | result => result
  }

type eventBatchQuery = {
  logs: array<Ethers.log>,
  latestFetchedBlock: Ethers.JsonRpcProvider.block,
  nextSuggestedBlockInterval: int,
}

let getNextPage = (
  ~fromBlock,
  ~toBlock,
  ~addresses,
  ~topics,
  ~loadBlock,
  ~suggestedBlockInterval,
  ~syncConfig as sc: Config.syncConfig,
  ~provider,
  ~logger,
): promise<eventBatchQuery> => {
  let rec executeQuery = (~suggestedBlockInterval): promise<eventBatchQuery> => {
    //If the query hangs for longer than this, reject this promise to reduce the block interval
    let queryTimoutPromise =
      Time.resolvePromiseAfterDelay(~delayMilliseconds=sc.queryTimeoutMillis)->Promise.then(() =>
        Promise.reject(
          QueryTimout(
            `Query took longer than ${Belt.Int.toString(sc.queryTimeoutMillis / 1000)} seconds`,
          ),
        )
      )

    let suggestedToBlock = fromBlock + suggestedBlockInterval - 1
    let queryToBlock = Pervasives.min(suggestedToBlock, toBlock)->Pervasives.max(fromBlock) //Defensively ensure we never query a target block below fromBlock
    let latestFetchedBlockPromise = loadBlock(queryToBlock)
    let logsPromise =
      provider
      ->Ethers.JsonRpcProvider.getLogs(
        ~filter={
          address: ?addresses,
          topics,
          fromBlock,
          toBlock: queryToBlock,
        }->Ethers.CombinedFilter.toFilter,
      )
      ->Promise.then(async logs => {
        let executedBlockInterval = queryToBlock - fromBlock + 1
        // Increase the suggested block interval only when it was actually applied
        // and we didn't query to a hard toBlock
        let nextSuggestedBlockInterval = if executedBlockInterval >= suggestedBlockInterval {
          // Increase batch size going forward, but do not increase past a configured maximum
          // See: https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease
          Pervasives.min(executedBlockInterval + sc.accelerationAdditive, sc.intervalCeiling)
        } else {
          suggestedBlockInterval
        }
        {
          logs,
          nextSuggestedBlockInterval,
          latestFetchedBlock: await latestFetchedBlockPromise,
        }
      })

    [queryTimoutPromise, logsPromise]
    ->Promise.race
    ->Promise.catch(err => {
      // Might fail with message "query exceeds max results 20000, retry with the range 6000438-6000934"
      // Ideally to handle it and respect

      logger->Logging.childWarn({
        "msg": "Error getting events. Will retry after backoff time",
        "backOffMilliseconds": sc.backoffMillis,
        "suggestedBlockInterval": suggestedBlockInterval,
        "err": err,
      })

      Time.resolvePromiseAfterDelay(~delayMilliseconds=sc.backoffMillis)->Promise.then(_ => {
        let nextBlockIntervalTry =
          (suggestedBlockInterval->Belt.Int.toFloat *. sc.backoffMultiplicative)->Belt.Int.fromFloat
        logger->Logging.childTrace({
          "msg": "Retrying query with a smaller block interval",
          "fromBlock": fromBlock,
          "toBlock": fromBlock + nextBlockIntervalTry - 1,
        })
        executeQuery(~suggestedBlockInterval={nextBlockIntervalTry})
      })
    })
  }

  executeQuery(~suggestedBlockInterval)
}
