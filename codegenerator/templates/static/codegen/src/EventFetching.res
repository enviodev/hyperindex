
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

let getSingleContractEventFilters = (
  ~contractAddress,
  ~chainConfig: Config.chainConfig,
  ~addressInterfaceMapping,
  ~contractAddressMapping,
  ~logger,
) => {
  let contractName =
    contractAddressMapping->ContractAddressingMap.getContractNameFromAddress(
      ~contractAddress,
      ~logger,
    )

  let contractConfig = switch chainConfig.contracts->Js.Array2.find(contract =>
    contract.name == contractName
  ) {
  | None => ContractAddressingMap.UndefinedContractName(contractName, chainConfig.chainId)->raise
  | Some(contractConfig) => contractConfig
  }

  let contractEthers = Ethers.Contract.make(
    ~address=contractAddress,
    ~abi=contractConfig.abi,
    ~provider=chainConfig.provider,
  )

  addressInterfaceMapping->Js.Dict.set(
    contractAddress->Ethers.ethAddressToString,
    contractEthers->Ethers.Contract.getInterface,
  )

  contractConfig.events->Belt.Array.map(eventName => {
    contractEthers->Ethers.Contract.getEventFilter(~eventName=Types.eventNameToString(eventName))
  })
}

let getAllEventFilters = (
  ~addressInterfaceMapping,
  ~chainConfig: Config.chainConfig,
  ~provider,
  ~contractAddressMapping: ContractAddressingMap.mapping,
) => {
  let eventFilters = []

  chainConfig.contracts->Belt.Array.forEach(contract => {
    contractAddressMapping
    ->ContractAddressingMap.getAddressesFromContractName(~contractName=contract.name)
    ->Belt.Array.forEach(address => {
      let contractEthers = Ethers.Contract.make(~address, ~abi=contract.abi, ~provider)
      addressInterfaceMapping->Js.Dict.set(
        address->Ethers.ethAddressToString,
        contractEthers->Ethers.Contract.getInterface,
      )

      contract.events->Belt.Array.forEach(
        eventName => {
          let eventFilter =
            contractEthers->Ethers.Contract.getEventFilter(
              ~eventName=Types.eventNameToString(eventName),
            )
          let _ = eventFilters->Js.Array2.push(eventFilter)
        },
      )
    })
  })
  eventFilters
}

let makeCombinedEventFilterQuery = (
  ~provider,
  ~eventFilters,
  ~fromBlock,
  ~toBlock,
  ~logger: Pino.t,
) => {
  open Ethers.BlockTag

  let combinedFilter =
    eventFilters->Ethers.CombinedFilter.combineEventFilters(
      ~fromBlock=BlockNumber(fromBlock)->blockTagFromVariant,
      ~toBlock=BlockNumber(toBlock)->blockTagFromVariant,
    )

  let numBlocks = toBlock - fromBlock + 1

  logger->Logging.childTrace({
    "msg": "Initiating Combined Query Filter",
    "from": fromBlock,
    "to": toBlock,
    "numBlocks": numBlocks,
  })

  provider
  ->Ethers.JsonRpcProvider.getLogs(
    ~filter={combinedFilter->Ethers.CombinedFilter.combinedFilterToFilter},
  )
  ->Promise.thenResolve(res => {
    logger->Logging.childTrace({
      "msg": "Successful Combined Query Filter",
      "from": fromBlock,
      "to": toBlock,
      "numBlocks": numBlocks,
    })
    res
  })
  ->Promise.catch(err => {
    logger->Logging.childWarn({
      "msg": "Failed Combined Query Filter from block",
      "from": fromBlock,
      "to": toBlock,
      "numBlocks": numBlocks,
    })
    err->Promise.reject
  })
}

type eventBatchPromise = {
  timestampPromise: promise<int>,
  chainId: int,
  blockNumber: int,
  logIndex: int,
  eventPromise: promise<Types.event>,
}

type eventBatchQueueItem = {
  timestamp: int,
  chainId: int,
  blockNumber: int,
  logIndex: int,
  event: Types.event,
}

let convertLogs = (
  logs: array<Ethers.log>,
  ~blockLoader: LazyLoader.asyncMap<Ethers.JsonRpcProvider.block>,
  ~contractAddressMapping: ContractAddressingMap.mapping,
  ~addressInterfaceMapping,
  ~chainId,
  ~logger,
): array<eventBatchPromise> => {
  logger->Logging.childTrace({
    "msg": "Handling of logs",
    "numberLogs": logs->Belt.Array.length,
  })

  logs
  ->Belt.Array.map(log => {
    let blockPromise = blockLoader->LazyLoader.get(log.blockNumber)
    let timestampPromise = blockPromise->Promise.thenResolve(block => block.timestamp)

    //get a specific interface type
    //interface type parses the log
    let optInterface = addressInterfaceMapping->Js.Dict.get(log.address->Obj.magic)

    switch optInterface {
    | None => None
    | Some(interface) =>
      Some({
        timestampPromise,
        chainId,
        blockNumber: log.blockNumber,
        logIndex: log.logIndex,
        eventPromise: timestampPromise->Promise.thenResolve(blockTimestamp => {
          Converters.parseEvent(~log, ~blockTimestamp, ~interface, ~contractAddressMapping, ~logger)
        }),
      })
    }
  })
  ->Belt.Array.keepMap(opt => opt)
}

let applyConditionalFunction = (value: 'a, condition: bool, callback: 'a => 'b) => {
  condition ? callback(value) : value
}

let queryEventsWithCombinedFilter = async (
  ~addressInterfaceMapping,
  ~eventFilters,
  ~fromBlock,
  ~toBlock,
  ~minFromBlockLogIndex=0,
  ~blockLoader,
  ~provider,
  ~chainId,
  ~contractAddressMapping,
  ~logger: Pino.t,
  (),
): array<eventBatchPromise> => {
  let combinedFilterRes = await makeCombinedEventFilterQuery(
    ~provider,
    ~eventFilters,
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

  logs->convertLogs(
    ~blockLoader,
    ~addressInterfaceMapping,
    ~contractAddressMapping,
    ~chainId,
    ~logger,
  )
}

type eventBatchQuery = {
  eventBatchPromises: array<eventBatchPromise>,
  finalExecutedBlockInterval: int,
}

let getContractEventsOnFilters = async (
  ~eventFilters,
  ~addressInterfaceMapping,
  ~contractAddressMapping,
  ~fromBlock,
  ~toBlock,
  ~initialBlockInterval,
  ~minFromBlockLogIndex=0,
  ~chainConfig: Config.chainConfig,
  ~blockLoader,
  ~logger,
  (),
): eventBatchQuery => {
  let sc = chainConfig.syncConfig

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
          ~contractAddressMapping,
          ~addressInterfaceMapping,
          ~eventFilters,
          ~fromBlock=fromBlockRef.contents,
          ~toBlock=nextToBlock,
          ~minFromBlockLogIndex=fromBlockRef.contents == fromBlock ? minFromBlockLogIndex : 0,
          ~provider=chainConfig.provider,
          ~blockLoader,
          ~chainId=chainConfig.chainId,
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
