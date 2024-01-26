exception QueryTimout(string)

let getUnwrappedBlock = (provider, blockNumber) =>
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

let rec getUnwrappedBlockWithBackoff = async (~provider, ~blockNumber, ~backoffMsOnFailure) =>
  switch await getUnwrappedBlock(provider, blockNumber) {
  | exception err =>
    Logging.warn({
      "err": err,
      "msg": `Issue while running fetching batch of events from the RPC. Will wait ${backoffMsOnFailure->Belt.Int.toString}ms and try again.`,
      "type": "EXPONENTIAL_BACKOFF",
    })
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=backoffMsOnFailure)
    await getUnwrappedBlockWithBackoff(
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

type eventBatchPromise = {
  timestampPromise: promise<int>,
  chain: ChainMap.Chain.t,
  blockNumber: int,
  logIndex: int,
  eventPromise: promise<Types.event>,
}

exception RpcEventParsing(Converters.parseEventError)

let convertLogs = (
  logs: array<Ethers.log>,
  ~blockLoader: LazyLoader.asyncMap<Ethers.JsonRpcProvider.block>,
  ~contractInterfaceManager: ContractInterfaceManager.t,
  ~chain,
  ~logger,
): array<eventBatchPromise> => {
  logger->Logging.childTrace({
    "msg": "Handling of logs",
    "numberLogs": logs->Belt.Array.length,
  })

  logs->Belt.Array.map(log => {
    let blockPromise = blockLoader->LazyLoader.get(log.blockNumber)
    let timestampPromise = blockPromise->Promise.thenResolve(block => block.timestamp)

    {
      timestampPromise,
      chain,
      blockNumber: log.blockNumber,
      logIndex: log.logIndex,
      eventPromise: timestampPromise->Promise.thenResolve(blockTimestamp => {
        let parsed = Converters.parseEvent(
          ~log,
          ~blockTimestamp,
          ~contractInterfaceManager,
          ~chainId=chain->ChainMap.Chain.toChainId,
        )
        switch parsed {
        | Error(e) =>
          let ex = RpcEventParsing(e)
          logger->Logging.childErrorWithExn(ex, "Failed to parse event from RPC. Double c")
          ex->raise
        | Ok(val) => val
        }
      }),
    }
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
  ~blockLoader,
  ~provider,
  ~chain,
  ~logger: Pino.t,
  (),
): array<eventBatchPromise> => {
  let combinedFilterRes = await makeCombinedEventFilterQuery(
    ~provider,
    ~contractInterfaceManager,
    ~fromBlock,
    ~toBlock,
    ~logger,
  )

  let logs = combinedFilterRes->applyConditionalFunction(minFromBlockLogIndex > 0, arrLogs => {
    arrLogs->Belt.Array.keep(log => {
      log.blockNumber > fromBlock ||
        (log.blockNumber == fromBlock && log.logIndex >= minFromBlockLogIndex)
    })
  })

  logs->convertLogs(~blockLoader, ~contractInterfaceManager, ~chain, ~logger)
}

type eventBatchQuery = {
  eventBatchPromises: array<eventBatchPromise>,
  finalExecutedBlockInterval: int,
}

let getContractEventsOnFilters = async (
  ~contractInterfaceManager,
  ~fromBlock,
  ~toBlock,
  ~initialBlockInterval,
  ~minFromBlockLogIndex=0,
  ~chain,
  ~rpcConfig: Config.rpcConfig,
  ~blockLoader,
  ~logger,
  (),
): eventBatchQuery => {
  let sc = rpcConfig.syncConfig

  let fromBlockRef = ref(fromBlock)
  let shouldContinueProcess = () => fromBlockRef.contents <= toBlock

  let currentBlockInterval = ref(initialBlockInterval)
  let events = ref([])
  while shouldContinueProcess() {
    logger->Logging.childTrace("continuing to process...")
    let rec executeQuery = (~blockInterval): promise<(array<eventBatchPromise>, int)> => {
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
      let nextToBlock = Pervasives.min(upperBoundToBlock, toBlock)
      let eventsPromise =
        queryEventsWithCombinedFilter(
          ~contractInterfaceManager,
          ~fromBlock=fromBlockRef.contents,
          ~toBlock=nextToBlock,
          ~minFromBlockLogIndex=fromBlockRef.contents == fromBlock ? minFromBlockLogIndex : 0,
          ~provider=rpcConfig.provider,
          ~blockLoader,
          ~chain,
          ~logger,
          (),
        )->Promise.thenResolve(events => (events, nextToBlock - fromBlockRef.contents + 1))

      [queryTimoutPromise, eventsPromise]
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

    let (intervalEvents, executedBlockInterval) = await executeQuery(
      ~blockInterval=currentBlockInterval.contents,
    )
    events := events.contents->Belt.Array.concat(intervalEvents)

    // Increase batch size going forward, but do not increase past a configured maximum
    // See: https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease
    currentBlockInterval :=
      Pervasives.min(executedBlockInterval + sc.accelerationAdditive, sc.intervalCeiling)

    fromBlockRef := fromBlockRef.contents + executedBlockInterval
    logger->Logging.childTrace({
      "msg": "Queried processAllEventsFromBlockNumber ",
      "lastBlockProcessed": fromBlockRef.contents - 1,
      "toBlock": toBlock,
      "numEvents": intervalEvents->Array.length,
    })
  }

  {
    eventBatchPromises: events.contents,
    finalExecutedBlockInterval: currentBlockInterval.contents,
  }
}
