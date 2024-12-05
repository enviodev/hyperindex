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

let makeCombinedEventFilterQuery = (
  ~provider,
  ~contractInterfaceManager: ContractInterfaceManager.t,
  ~fromBlock,
  ~toBlock,
  ~logger: Pino.t,
) => {
  let combinedFilter =
    contractInterfaceManager->ContractInterfaceManager.getCombinedEthersFilter(~fromBlock, ~toBlock)

  let numBlocks = toBlock - fromBlock + 1

  let loggerWithContext = Logging.createChildFrom(
    ~logger,
    ~params={
      "fromBlock": fromBlock,
      "toBlock": toBlock,
      "numBlocks": numBlocks,
    },
  )

  loggerWithContext->Logging.childTrace("Initiating Combined Query Filter")

  provider
  ->Ethers.JsonRpcProvider.getLogs(
    ~filter={combinedFilter->Ethers.CombinedFilter.combinedFilterToFilter},
  )
  ->Promise.thenResolve(res => {
    loggerWithContext->Logging.childTrace({
      "Successful Combined Query Filter"
    })
    res
  })
  ->Promise.catch(err => {
    loggerWithContext->Logging.childWarn("Failed Combined Query Filter from block")
    err->Promise.reject
  })
}

let applyConditionalFunction = (value: 'a, condition: bool, callback: 'a => 'b) => {
  condition ? callback(value) : value
}

let queryEventsWithCombinedFilter = async (
  ~contractInterfaceManager,
  ~fromBlock,
  ~toBlock,
  ~minFromBlockLogIndex=0,
  ~provider,
  ~logger: Pino.t,
): array<Ethers.log> => {
  let combinedFilterRes = await makeCombinedEventFilterQuery(
    ~provider,
    ~contractInterfaceManager,
    ~fromBlock,
    ~toBlock,
    ~logger,
  )

  combinedFilterRes->applyConditionalFunction(minFromBlockLogIndex > 0, arrLogs => {
    arrLogs->Belt.Array.keep(log => {
      log.blockNumber > fromBlock ||
        (log.blockNumber == fromBlock && log.logIndex >= minFromBlockLogIndex)
    })
  })
}

type eventBatchQuery = {
  logs: array<Ethers.log>,
  finalExecutedBlockInterval: int,
}

let getNextPage = async (
  ~contractInterfaceManager,
  ~fromBlock,
  ~toBlock,
  ~initialBlockInterval,
  ~minFromBlockLogIndex=0,
  ~syncConfig as sc: Config.syncConfig,
  ~provider,
  ~logger,
): eventBatchQuery => {
  let fromBlockRef = ref(fromBlock)
  let shouldContinueProcess = () => fromBlockRef.contents <= toBlock

  let currentBlockInterval = ref(initialBlockInterval)
  let logs = ref([])
  while shouldContinueProcess() {
    let rec executeQuery = (~blockInterval): promise<(array<Ethers.log>, int)> => {
      //If the query hangs for longer than this, reject this promise to reduce the block interval
      let queryTimoutPromise =
        Time.resolvePromiseAfterDelay(~delayMilliseconds=sc.queryTimeoutMillis)->Promise.then(() =>
          Promise.reject(
            QueryTimout(
              `Query took longer than ${Belt.Int.toString(sc.queryTimeoutMillis / 1000)} seconds`,
            ),
          )
        )

      let upperBoundToBlock = fromBlockRef.contents + blockInterval - 1
      let nextToBlock =
        Pervasives.min(upperBoundToBlock, toBlock)->Pervasives.max(fromBlockRef.contents) //Defensively ensure we never query a target block below fromBlock
      let logsPromise =
        queryEventsWithCombinedFilter(
          ~contractInterfaceManager,
          ~fromBlock=fromBlockRef.contents,
          ~toBlock=nextToBlock,
          ~minFromBlockLogIndex=fromBlockRef.contents == fromBlock ? minFromBlockLogIndex : 0,
          ~provider,
          ~logger,
        )->Promise.thenResolve(logs => (logs, nextToBlock - fromBlockRef.contents + 1))

      [queryTimoutPromise, logsPromise]
      ->Promise.race
      ->Promise.catch(err => {
        logger->Logging.childWarn({
          "msg": "Error getting events, will retry after backoff time",
          "backOffMilliseconds": sc.backoffMillis,
          "err": err,
        })

        Time.resolvePromiseAfterDelay(~delayMilliseconds=sc.backoffMillis)->Promise.then(_ => {
          let nextBlockIntervalTry =
            (blockInterval->Belt.Int.toFloat *. sc.backoffMultiplicative)->Belt.Int.fromFloat
          logger->Logging.childTrace({
            "msg": "Retrying query fromBlock and toBlock",
            "fromBlock": fromBlock,
            "toBlock": nextBlockIntervalTry,
          })

          executeQuery(~blockInterval={nextBlockIntervalTry})
        })
      })
    }

    let (intervalLogs, executedBlockInterval) = await executeQuery(
      ~blockInterval=currentBlockInterval.contents,
    )
    logs := logs.contents->Belt.Array.concat(intervalLogs)

    // Increase batch size going forward, but do not increase past a configured maximum
    // See: https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease
    currentBlockInterval :=
      Pervasives.min(executedBlockInterval + sc.accelerationAdditive, sc.intervalCeiling)

    fromBlockRef := fromBlockRef.contents + executedBlockInterval
    logger->Logging.childTrace({
      "msg": "Finished executing query",
      "lastBlockProcessed": fromBlockRef.contents - 1,
      "toBlock": toBlock,
      "numEvents": intervalLogs->Array.length,
    })
  }

  {
    logs: logs.contents,
    finalExecutedBlockInterval: currentBlockInterval.contents,
  }
}
