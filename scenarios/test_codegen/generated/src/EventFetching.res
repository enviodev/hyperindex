exception QueryTimout(string)

type blocksProcessed = {
  from: int,
  to: int,
}

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

let getSingleContractEventFilters = (
  ~contractAddress,
  ~chainConfig: Config.chainConfig,
  ~addressInterfaceMapping,
) => {
  let contractName = Converters.ContractNameAddressMappings.getContractNameFromAddress(
    ~chainId=chainConfig.chainId,
    ~contractAddress,
  )
  let contractConfig = switch chainConfig.contracts->Js.Array2.find(contract =>
    contract.name == contractName
  ) {
  | None => Converters.UndefinedContractName(contractName, chainConfig.chainId)->raise
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
) => {
  let eventFilters = []

  chainConfig.contracts->Belt.Array.forEach(contract => {
    Converters.ContractNameAddressMappings.getAddressesFromContractName(
      ~chainId=chainConfig.chainId,
      ~contractName=contract.name,
    )->Belt.Array.forEach(address => {
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

let makeCombinedEventFilterQuery = (~provider, ~eventFilters, ~fromBlock, ~toBlock) => {
  open Ethers.BlockTag

  let combinedFilter =
    eventFilters->Ethers.CombinedFilter.combineEventFilters(
      ~fromBlock=BlockNumber(fromBlock)->blockTagFromVariant,
      ~toBlock=BlockNumber(toBlock)->blockTagFromVariant,
    )

  let numBlocks = toBlock - fromBlock + 1

  let fromStr = Belt.Int.toString(fromBlock)
  let toStr = Belt.Int.toString(toBlock)
  let numStr = Belt.Int.toString(numBlocks)
  Js.log(`Initiating Combined Query Filter from block ${fromStr} to ${toStr} (${numStr} blocks)`)

  provider
  ->Ethers.JsonRpcProvider.getLogs(
    ~filter={combinedFilter->Ethers.CombinedFilter.combinedFilterToFilter},
  )
  ->Promise.thenResolve(res => {
    Js.log(`Successful Combined Query Filter from block ${fromStr} to ${toStr} (${numStr} blocks)`)
    res
  })
  ->Promise.catch(err => {
    Logging.info(
      `Failed Combined Query Filter from block ${fromStr} to ${toStr} (${numStr} blocks)`,
    )
    err->Promise.reject
  })
}

type eventBatchPromise = {
  blockNumber: int,
  logIndex: int,
  eventPromise: promise<Types.event>,
}

let convertLogs = (logs: array<Ethers.log>, ~blockLoader, ~addressInterfaceMapping, ~chainId) => {
  Js.log2("Handling number of logs: ", logs->Array.length)

  logs
  ->Belt.Array.map(log => {
    let blockPromise = blockLoader->LazyLoader.get(log.blockNumber)

    //get a specific interface type
    //interface type parses the log
    let optInterface = addressInterfaceMapping->Js.Dict.get(log.address->Obj.magic)

    switch optInterface {
    | None => None
    | Some(interface) =>
      Some({
        blockNumber: log.blockNumber,
        logIndex: log.logIndex,
        eventPromise: {
          let logDescription = interface->Ethers.Interface.parseLog(~log)

          switch Converters.eventStringToEvent(
            logDescription.name,
            Converters.ContractNameAddressMappings.getContractNameFromAddress(
              ~contractAddress=log.address,
              ~chainId,
            ),
          ) {
          | GravatarContract_TestEventEvent =>
            let convertedEvent =
              logDescription
              ->Converters.Gravatar.convertTestEventLogDescription
              ->Converters.Gravatar.convertTestEventLog(~log, ~blockPromise)

            convertedEvent
          | GravatarContract_NewGravatarEvent =>
            let convertedEvent =
              logDescription
              ->Converters.Gravatar.convertNewGravatarLogDescription
              ->Converters.Gravatar.convertNewGravatarLog(~log, ~blockPromise)

            convertedEvent
          | GravatarContract_UpdatedGravatarEvent =>
            let convertedEvent =
              logDescription
              ->Converters.Gravatar.convertUpdatedGravatarLogDescription
              ->Converters.Gravatar.convertUpdatedGravatarLog(~log, ~blockPromise)

            convertedEvent
          | NftFactoryContract_SimpleNftCreatedEvent =>
            let convertedEvent =
              logDescription
              ->Converters.NftFactory.convertSimpleNftCreatedLogDescription
              ->Converters.NftFactory.convertSimpleNftCreatedLog(~log, ~blockPromise)

            convertedEvent
          | SimpleNftContract_TransferEvent =>
            let convertedEvent =
              logDescription
              ->Converters.SimpleNft.convertTransferLogDescription
              ->Converters.SimpleNft.convertTransferLog(~log, ~blockPromise)

            convertedEvent
          }
        },
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
  (),
) => {
  let combinedFilterRes = await makeCombinedEventFilterQuery(
    ~provider,
    ~eventFilters,
    ~fromBlock,
    ~toBlock,
  )

  let logs = combinedFilterRes->applyConditionalFunction(minFromBlockLogIndex > 0, arrLogs => {
    arrLogs->Belt.Array.keep(log => {
      log.blockNumber > fromBlock ||
        (log.blockNumber == fromBlock && log.logIndex >= minFromBlockLogIndex)
    })
  })

  logs->convertLogs(~blockLoader, ~addressInterfaceMapping, ~chainId)
}
let getContractEventsOnFilters = async (
  ~addressInterfaceMapping,
  ~eventFilters,
  ~minFromBlockLogIndex=0,
  ~fromBlock,
  ~toBlock,
  ~maxBlockInterval,
  ~chainId,
  ~provider,
  ~blockLoader,
  (),
) => {
  let sc = Config.syncConfig

  let fromBlockRef = ref(fromBlock)
  let shouldContinueProcess = () => fromBlockRef.contents <= toBlock

  let currentBlockInterval = ref(maxBlockInterval)
  let events = ref([])
  while shouldContinueProcess() {
    Js.log("continuing to process...")
    let rec executeQuery = (~blockInterval) => {
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
      let nextToBlock = upperBoundToBlock > toBlock ? toBlock : upperBoundToBlock
      let eventsPromise =
        queryEventsWithCombinedFilter(
          ~addressInterfaceMapping,
          ~eventFilters,
          ~fromBlock=fromBlockRef.contents,
          ~toBlock=nextToBlock,
          ~minFromBlockLogIndex=fromBlockRef.contents == fromBlock ? minFromBlockLogIndex : 0,
          ~provider,
          ~blockLoader,
          ~chainId,
          (),
        )->Promise.thenResolve(events => (events, nextToBlock - fromBlockRef.contents + 1))

      [queryTimoutPromise, eventsPromise]
      ->Promise.race
      ->Promise.catch(err => {
        Js.log2(
          `Error getting events, waiting ${(sc.backoffMillis / 1000)
              ->Belt.Int.toString} seconds before retrying`,
          err,
        )

        Time.resolvePromiseAfterDelay(~delayMilliseconds=sc.backoffMillis)->Promise.then(_ => {
          let nextBlockIntervalTry =
            (blockInterval->Belt.Int.toFloat *. sc.backoffMultiplicative)->Belt.Int.fromFloat
          Js.log3("Retrying query fromBlock and toBlock:", fromBlock, nextBlockIntervalTry)
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

    Logging.info(
      `Queried processAllEventsFromBlockNumber ${(fromBlockRef.contents - 1)
          ->Belt.Int.toString} out of ${toBlock->Belt.Int.toString}`,
    )
  }
  (events.contents, {from: fromBlock, to: fromBlockRef.contents - 1})
}
