exception QueryTimout(string)

let initialBlockInterval = 10000

// After an RPC error, how much to scale back the number of blocks requested at once
let backoffMultiplicative = 0.8

// Without RPC errors or timeouts, how much to increase the number of blocks requested by for the next batch
let accelerationAdditive = 2000

// After an error, how long to wait before retrying
let backoffMillis = 5000

let queryTimeoutMillis = 20000

// Expose key removal on JS maps, used for cache invalidation
// Unfortunately Js.Dict.unsafeDeleteKey only works with Js.Dict.t<String>
%%raw(`
function deleteKey(obj, k) {
  delete obj[k]
}
`)
@val external deleteKey: ('a, string) => unit = "deleteKey"

let convertLogs = (
  logs: array<Ethers.log>,
  ~provider,
  ~addressInterfaceMapping,
  ~fromBlockForLogging,
  ~toBlockForLogging,
  ~chainId,
) => {
  let blockRequestMapping: Js.Dict.t<
    Promise.t<Js.Nullable.t<Ethers.JsonRpcProvider.block>>,
  > = Js.Dict.empty()

  // Many times logs will be from the same block so there is no need to make multiple get block requests in that case
  let getMemoisedBlockPromise = blockNumber => {
    let blockKey = Belt.Int.toString(blockNumber)

    let blockRequestCached = blockRequestMapping->Js.Dict.get(blockKey)

    let blockRequest = switch blockRequestCached {
    | Some(req) => req
    | None =>
      let newRequest = provider->Ethers.JsonRpcProvider.getBlock(blockNumber)
      // Cache the request
      blockRequestMapping->Js.Dict.set(blockKey, newRequest)
      newRequest
    }
    blockRequest
    ->Promise.catch(err => {
      // Invalidate the cache, so that the request can be retried
      deleteKey(blockRequestMapping, blockKey)

      // Propagate failure to where we handle backoff
      Promise.reject(err)
    })
    ->Promise.then(block =>
      switch block->Js.Nullable.toOption {
      | Some(block) => Promise.resolve(block)
      | None => Promise.reject(Js.Exn.raiseError(`getBlock(${blockKey}) returned null`))
      }
    )
  }

  let task = async () => {
    Js.log2("Handling number of logs: ", logs->Array.length)

    let events =
      await logs
      ->Belt.Array.map(log => {
        let blockPromise = log.blockNumber->getMemoisedBlockPromise

        //get a specific interface type
        //interface type parses the log
        let optInterface = addressInterfaceMapping->Js.Dict.get(log.address->Obj.magic)

        switch optInterface {
        | None => None
        | Some(interface) => {
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

              Some(convertedEvent)
            | GravatarContract_NewGravatarEvent =>
              let convertedEvent =
                logDescription
                ->Converters.Gravatar.convertNewGravatarLogDescription
                ->Converters.Gravatar.convertNewGravatarLog(~log, ~blockPromise)

              Some(convertedEvent)
            | GravatarContract_UpdatedGravatarEvent =>
              let convertedEvent =
                logDescription
                ->Converters.Gravatar.convertUpdatedGravatarLogDescription
                ->Converters.Gravatar.convertUpdatedGravatarLog(~log, ~blockPromise)

              Some(convertedEvent)
            | NftFactoryContract_SimpleNftCreatedEvent =>
              let convertedEvent =
                logDescription
                ->Converters.NftFactory.convertSimpleNftCreatedLogDescription
                ->Converters.NftFactory.convertSimpleNftCreatedLog(~log, ~blockPromise)

              Some(convertedEvent)
            | SimpleNftContract_TransferEvent =>
              let convertedEvent =
                logDescription
                ->Converters.SimpleNft.convertTransferLogDescription
                ->Converters.SimpleNft.convertTransferLog(~log, ~blockPromise)

              Some(convertedEvent)
            }
          }
        }
      })
      ->Belt.Array.keepMap(opt => opt)
      ->Promise.all

    events
  }

  Time.retryOnCatchAfterDelay(
    ~retryDelayMilliseconds=backoffMillis,
    ~retryMessage=`Failed to handle event logs from block ${fromBlockForLogging->Belt.Int.toString} to block ${toBlockForLogging->Belt.Int.toString}`,
    ~task,
  )
}

let makeCombinedEventFilterQuery = (~provider, ~eventFilters, ~fromBlock, ~toBlock) => {
  open Ethers.BlockTag

  let combinedFilter =
    eventFilters->Ethers.CombinedFilter.combineEventFilters(
      ~fromBlock=BlockNumber(fromBlock)->blockTagFromVariant,
      ~toBlock=BlockNumber(toBlock)->blockTagFromVariant,
    )

  Js.log3("Intiating Combined Query Filter fromBlock toBlock: ", fromBlock, toBlock)

  let task = () =>
    provider
    ->Ethers.JsonRpcProvider.getLogs(
      ~filter={combinedFilter->Ethers.CombinedFilter.combinedFilterToFilter},
    )
    ->Promise.thenResolve(res => {
      Js.log3("Successful Combined Query Filter fromBlock toBlock: ", fromBlock, toBlock)
      res
    })

  Time.retryOnCatchAfterDelay(
    ~retryDelayMilliseconds=5000,
    ~retryMessage=`Failed combined query filter from block ${fromBlock->Belt.Int.toString} to block ${toBlock->Belt.Int.toString}`,
    ~task,
  )
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
      log.blockNumber == fromBlock && log.logIndex >= minFromBlockLogIndex
    })
  })

  await logs->convertLogs(
    ~provider,
    ~addressInterfaceMapping,
    ~fromBlockForLogging=fromBlock,
    ~toBlockForLogging=toBlock,
    ~chainId,
  )
}

let queryEventsWithCombinedFilterAndProcessEventBatch = async (
  ~addressInterfaceMapping,
  ~eventFilters,
  ~fromBlock,
  ~toBlock,
  ~provider,
  ~chainId,
) => {
  let events = await queryEventsWithCombinedFilter(
    ~addressInterfaceMapping,
    ~eventFilters,
    ~fromBlock,
    ~toBlock,
    ~provider,
    ~chainId,
    (),
  )
  events->EventProcessing.processEventBatch(~chainId)
}

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

type blocksProcessed = {
  from: int,
  to: int,
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
  (),
) => {
  let fromBlockRef = ref(fromBlock)
  let shouldContinueProcess = () => fromBlockRef.contents < toBlock

  let currentBlockInterval = ref(maxBlockInterval)
  let events = ref([])
  while shouldContinueProcess() {
    let rec executeQuery = (~blockInterval) => {
      //If the query hangs for longer than this, reject this promise to reduce the block interval
      let queryTimoutPromise =
        Time.resolvePromiseAfterDelay(~delayMilliseconds=queryTimeoutMillis)->Promise.then(() =>
          Promise.reject(
            QueryTimout(
              `Query took longer than ${Belt.Int.toString(queryTimeoutMillis / 1000)} seconds`,
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
          ~minFromBlockLogIndex,
          ~provider,
          ~chainId,
          (),
        )->Promise.thenResolve(events => (events, blockInterval))

      [queryTimoutPromise, eventsPromise]
      ->Promise.race
      ->Promise.catch(err => {
        Js.log2(
          `Error getting events, waiting ${(backoffMillis / 1000)
              ->Belt.Int.toString} seconds before retrying`,
          err,
        )

        Time.resolvePromiseAfterDelay(~delayMilliseconds=backoffMillis)->Promise.then(_ => {
          let nextBlockIntervalTry =
            (blockInterval->Belt.Int.toFloat *. backoffMultiplicative)->Belt.Int.fromFloat
          Js.log3("Retrying query fromBlock and toBlock:", fromBlock, nextBlockIntervalTry)
          executeQuery(~blockInterval={nextBlockIntervalTry})
        })
      })
    }

    let (intervalEvents, executedBlockInterval) = await executeQuery(
      ~blockInterval=currentBlockInterval.contents,
    )
    events := events.contents->Belt.Array.concat(intervalEvents)
    // Increase batch size going forward, https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease
    currentBlockInterval := executedBlockInterval + accelerationAdditive
    fromBlockRef := fromBlockRef.contents + executedBlockInterval

    let boundedBlocksQueried = fromBlockRef.contents > toBlock ? toBlock : fromBlockRef.contents

    Logging.info(
      `Queried processAllEventsFromBlockNumber ${boundedBlocksQueried->Belt.Int.toString} out of ${toBlock->Belt.Int.toString}`,
    )
  }
  (events.contents, {from: fromBlock, to: fromBlockRef.contents})
}
let processAllEventsFromBlockNumber = async (
  ~fromBlock: int,
  ~blockInterval as maxBlockInterval,
  ~chainConfig: Config.chainConfig,
  ~provider,
) => {
  let addressInterfaceMapping: Js.Dict.t<Ethers.Interface.t> = Js.Dict.empty()

  let eventFilters = getAllEventFilters(~addressInterfaceMapping, ~chainConfig, ~provider)

  let fromBlockRef = ref(fromBlock)

  let getCurrentBlockFromRPC = () =>
    provider
    ->Ethers.JsonRpcProvider.getBlockNumber
    ->Promise.catch(_err => {
      Logging.warn("Error getting current block number")
      0->Promise.resolve
    })
  let currentBlock: ref<int> = ref(await getCurrentBlockFromRPC())

  //we retrieve the latest processed block from the db and add 1
  //if only one block has occurred since that processed block we ensure that the new block
  //is handled with the below condition
  let shouldContinueProcess = () => fromBlockRef.contents <= currentBlock.contents

  while shouldContinueProcess() {
    let (events, blocksProcessed) = await getContractEventsOnFilters(
      ~addressInterfaceMapping,
      ~eventFilters,
      ~minFromBlockLogIndex=0,
      ~fromBlock=fromBlockRef.contents,
      ~toBlock=currentBlock.contents,
      ~maxBlockInterval,
      ~chainId=chainConfig.chainId,
      ~provider,
      (),
    )

    //process the batch of events
    //NOTE: we can use this to track batch processing time
    await events->EventProcessing.processEventBatch(~chainId=chainConfig.chainId)

    fromBlockRef := blocksProcessed.to
    currentBlock := (await getCurrentBlockFromRPC())
  }
}

let processAllEvents = async (chainConfig: Config.chainConfig) => {
  let latestProcessedBlock = await DbFunctions.RawEvents.getLatestProcessedBlockNumber(
    ~chainId=chainConfig.chainId,
  )

  let startBlock =
    latestProcessedBlock->Belt.Option.mapWithDefault(
      chainConfig.startBlock,
      latestProcessedBlock => {latestProcessedBlock + 1},
    )

  //Add all contracts and addresses from config
  Converters.ContractNameAddressMappings.registerStaticAddresses(~chainConfig)

  //Add all dynamic contracts from DB
  let dynamicContracts =
    await DbFunctions.sql->DbFunctions.DynamicContractRegistry.readDynamicContractsOnChainIdAtOrBeforeBlock(
      ~chainId=chainConfig.chainId,
      ~startBlock,
    )

  dynamicContracts->Belt.Array.forEach(({contractType, contractAddress}) =>
    Converters.ContractNameAddressMappings.addContractAddress(
      ~chainId=chainConfig.chainId,
      ~contractName=contractType,
      ~contractAddress,
    )
  )

  await processAllEventsFromBlockNumber(
    ~fromBlock=startBlock,
    ~chainConfig,
    ~blockInterval=initialBlockInterval,
    ~provider=chainConfig.provider,
  )
}

let startSyncingAllEvents = () => {
  Config.config
  ->Js.Dict.values
  ->Belt.Array.map(chainConfig => {
    chainConfig->processAllEvents
  })
  ->Promise.all
  ->Promise.thenResolve(_ => ())
}
