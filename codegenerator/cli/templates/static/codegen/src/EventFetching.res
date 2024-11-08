exception QueryTimout(string)
exception EventRoutingFailed

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

type eventBatchPromise = promise<Types.eventBatchQueueItem>

//We aren't fetching transaction and field names don't line up with
//the two available fields on a log. So create this function with runtime
//exception that should be validated away in codegen
type txFieldVal
exception InvalidRpcTransactionField(string)
let getTxFieldFromEthersLog = (log: Ethers.log, txField: string, ~logger): txFieldVal =>
  switch txField {
  | "hash" => log.transactionHash->Utils.magic
  | "transactionIndex" => log.transactionIndex->Utils.magic
  | field =>
    InvalidRpcTransactionField(field)->ErrorHandling.mkLogAndRaise(
      ~logger,
      ~msg="An invalid transaction field was requested for RPC response",
    )
  }

let nonOptionalTransactionFieldNames =
  Types.Transaction.schema->Utils.Schema.getNonOptionalFieldNames

let transactionFieldsFromLog = (log, ~logger): Types.Transaction.t => {
  let dict = Js.Dict.empty()
  //Note: if we implement all transaction fields, we will need all
  //field names not just non optional ones
  nonOptionalTransactionFieldNames->Belt.Array.forEach(name => {
    dict->Js.Dict.set(name, getTxFieldFromEthersLog(log, name, ~logger))
  })
  dict->(Utils.magic: Js.Dict.t<txFieldVal> => Types.Transaction.t)
}

//Types.blockFields is a subset of  Ethers.JsonRpcProvider.block so we can safely cast
let blockFieldsFromBlock: Ethers.JsonRpcProvider.block => Types.Block.t = Utils.magic

//Note ethers log is not a superset of log since logIndex is actually "index" with an @as alias
let ethersLogToLog: Ethers.log => Types.Log.t = ({address, data, topics, logIndex}) => {
  address,
  data,
  topics,
  logIndex,
}

let convertLogs = (
  logs: array<Ethers.log>,
  ~eventRouter,
  ~blockLoader: LazyLoader.asyncMap<Ethers.JsonRpcProvider.block>,
  ~contractInterfaceManager: ContractInterfaceManager.t,
  ~chain,
  ~logger,
): array<eventBatchPromise> => {
  logger->Logging.childTrace({
    "msg": "Handling of logs",
    "numberLogs": logs->Belt.Array.length,
  })

  logs->Belt.Array.keepMap(log => {
    let topic0 = log.topics->Js.Array2.unsafe_get(0)
    switch eventRouter->EventRouter.get(
      ~tag=EventRouter.getEvmEventTag(
        ~sighash=topic0->EvmTypes.Hex.toString,
        ~topicCount=log.topics->Array.length,
      ),
      ~contractAddressMapping=contractInterfaceManager.contractAddressMapping,
      ~contractAddress=log.address,
    ) {
    | None => None //ignore events that aren't registered
    | Some(eventMod: module(Types.InternalEvent)) =>
      Some(
        blockLoader
        ->LazyLoader.get(log.blockNumber)
        ->Promise.thenResolve(block => {
          let transaction = log->transactionFieldsFromLog(~logger)
          let log = log->ethersLogToLog
          let chainId = chain->ChainMap.Chain.toChainId

          let module(Event) = eventMod

          let decodedEvent = try contractInterfaceManager->ContractInterfaceManager.parseLogViemOrThrow(
            ~log,
          ) catch {
          | exn => {
              let params = {
                "chainId": chainId,
                "blockNumber": block.number,
                "logIndex": log.logIndex,
              }
              let logger = Logging.createChildFrom(~logger, ~params)
              exn->ErrorHandling.mkLogAndRaise(
                ~msg="Failed to parse event with viem, please double check your ABI.",
                ~logger,
              )
            }
          }

          (
            {
              eventName: Event.name,
              contractName: Event.contractName,
              handlerRegister: Event.handlerRegister,
              paramsRawEventSchema: Event.paramsRawEventSchema,
              timestamp: block.timestamp,
              chain,
              blockNumber: block.number,
              logIndex: log.logIndex,
              event: {
                chainId,
                params: decodedEvent.args,
                transaction,
                block: block->blockFieldsFromBlock,
                srcAddress: log.address,
                logIndex: log.logIndex,
              },
            }: Types.eventBatchQueueItem
          )
        }),
      )
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
  ~eventRouter,
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

  logs->convertLogs(~eventRouter, ~blockLoader, ~contractInterfaceManager, ~chain, ~logger)
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
  ~eventRouter,
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
      let nextToBlock =
        Pervasives.min(upperBoundToBlock, toBlock)->Pervasives.max(fromBlockRef.contents) //Defensively ensure we never query a target block below fromBlock
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
          ~eventRouter,
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
