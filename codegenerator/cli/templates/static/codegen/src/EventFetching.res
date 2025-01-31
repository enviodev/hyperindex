open Belt

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

let getSuggestedBlockIntervalFromExn = {
  let suggestedRangeRegExp = %re(`/retry with the range (\d+)-(\d+)/`)

  let blockRangeLimitRegExp = %re(`/limited to a (\d+) blocks range/`)

  exn =>
    switch exn {
    | Js.Exn.Error(error) =>
      try {
        // Didn't use parse here since it didn't work
        // because the error is some sort of weird Ethers object
        let message: string = (error->Obj.magic)["error"]["message"]
        message->S.assertOrThrow(S.string)
        switch suggestedRangeRegExp->Js.Re.exec_(message) {
        | Some(execResult) =>
          switch execResult->Js.Re.captures {
          | [_, Js.Nullable.Value(fromBlock), Js.Nullable.Value(toBlock)] =>
            switch (fromBlock->Int.fromString, toBlock->Int.fromString) {
            | (Some(fromBlock), Some(toBlock)) if toBlock >= fromBlock =>
              Some(toBlock - fromBlock + 1)
            | _ => None
            }
          | _ => None
          }
        | None =>
          switch blockRangeLimitRegExp->Js.Re.exec_(message) {
          | Some(execResult) =>
            switch execResult->Js.Re.captures {
            | [_, Js.Nullable.Value(blockRangeLimit)] =>
              switch blockRangeLimit->Int.fromString {
              | Some(blockRangeLimit) if blockRangeLimit > 0 => Some(blockRangeLimit)
              | _ => None
              }
            | _ => None
            }
          | None => None
          }
        }
      } catch {
      | _ => None
      }
    | _ => None
    }
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
      switch getSuggestedBlockIntervalFromExn(err) {
      | Some(nextBlockIntervalTry) => {
          logger->Logging.childTrace({
            "msg": "Failed getting events for the block interval. Retrying with the block interval suggested by the RPC provider.",
            "fromBlock": fromBlock,
            "toBlock": fromBlock + nextBlockIntervalTry - 1,
            "prevBlockInterval": suggestedBlockInterval,
          })
          executeQuery(~suggestedBlockInterval=nextBlockIntervalTry)
        }
      | None => {
          logger->Logging.childWarn({
            "msg": "Failed getting events for the block interval. Will retry after backoff time",
            "backOffMilliseconds": sc.backoffMillis,
            "prevBlockInterval": suggestedBlockInterval,
            "err": err,
          })

          Time.resolvePromiseAfterDelay(~delayMilliseconds=sc.backoffMillis)->Promise.then(_ => {
            let nextBlockIntervalTry =
              (suggestedBlockInterval->Belt.Int.toFloat *. sc.backoffMultiplicative)
                ->Belt.Int.fromFloat
            logger->Logging.childTrace({
              "msg": "Retrying query with a smaller block interval",
              "fromBlock": fromBlock,
              "toBlock": fromBlock + nextBlockIntervalTry - 1,
            })
            executeQuery(~suggestedBlockInterval={nextBlockIntervalTry})
          })
        }
      }
    })
  }

  executeQuery(~suggestedBlockInterval)
}
