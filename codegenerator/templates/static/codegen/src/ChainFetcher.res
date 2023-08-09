
type eventType = EventFetching.eventBatchQueueItem
type t = {
  mutable currentlyFetchingToBlock: int,
  mutable currentBlockInterval: int,
  mutable latestFetchedBlockTimestamp: int,
  newRangeQueriedCallBacks: SDSL.Queue.t<unit => unit>,
  contractAddressMapping: ContractAddressingMap.mapping,
  logger: Pino.t,
  blockLoader: LazyLoader.asyncMap<Ethers.JsonRpcProvider.block>,
  fetchedEventQueue: ChainEventQueue.t,
  chainConfig: Config.chainConfig,
}

//CONSTRUCTION
let make = (~chainConfig: Config.chainConfig, ~maxQueueSize): t => {
  let contractAddressMapping = ContractAddressingMap.make()
  let logger = Logging.createChild(~params={"chainId": chainConfig.chainId})

  //Add all contracts and addresses from config
  //Dynamic contracts are checked in DB on start
  contractAddressMapping->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)

  let blockLoader = LazyLoader.make(
    ~loaderFn=EventFetching.getUnwrappedBlock(chainConfig.provider),
    (),
  )

  {
    currentlyFetchingToBlock: 0,
    currentBlockInterval: chainConfig.syncConfig.initialBlockInterval,
    latestFetchedBlockTimestamp: 0,
    newRangeQueriedCallBacks: SDSL.Queue.make(),
    contractAddressMapping,
    fetchedEventQueue: ChainEventQueue.make(~maxQueueSize),
    logger,
    blockLoader,
    chainConfig,
  }
}

//Public methods
let startFetchingEvents = async (self: t) => {
  let {chainConfig, logger, contractAddressMapping, blockLoader, fetchedEventQueue} = self
  let latestProcessedBlock = await DbFunctions.RawEvents.getLatestProcessedBlockNumber(
    ~chainId=chainConfig.chainId,
  )

  let startBlock =
    latestProcessedBlock->Belt.Option.mapWithDefault(chainConfig.startBlock, latestProcessedBlock =>
      latestProcessedBlock + 1
    )

  logger->Logging.childTrace({
    "msg": "Starting fetching events for chain.",
    "startBlock": startBlock,
    "latestProcessedBlock": latestProcessedBlock,
  })

  //Add all dynamic contracts from DB
  let dynamicContracts =
    await DbFunctions.sql->DbFunctions.DynamicContractRegistry.readDynamicContractsOnChainIdAtOrBeforeBlock(
      ~chainId=chainConfig.chainId,
      ~startBlock,
    )

  dynamicContracts->Belt.Array.forEach(({contractType, contractAddress}) =>
    contractAddressMapping->ContractAddressingMap.addAddress(
      ~name=contractType,
      ~address=contractAddress,
    )
  )

  let sc = chainConfig.syncConfig
  let addressInterfaceMapping: Js.Dict.t<Ethers.Interface.t> = Js.Dict.empty()
  let provider = chainConfig.provider

  let fromBlockRef = ref(startBlock)

  let getCurrentBlockFromRPC = () =>
    provider
    ->Ethers.JsonRpcProvider.getBlockNumber
    ->Promise.catch(_err => {
      logger->Logging.childWarn("Error getting current block number")
      0->Promise.resolve
    })
  let currentBlock: ref<int> = ref(await getCurrentBlockFromRPC())

  let isNewBlocksToFetch = () => fromBlockRef.contents <= currentBlock.contents

  let rec checkShouldContinue = async () => {
    //If there are no new blocks to fetch, poll the provider for
    //a new block until it arrives
    if !isNewBlocksToFetch() {
      let newBlock = await provider->EventUtils.waitForNextBlock
      currentBlock := newBlock

      await checkShouldContinue()
    }
  }

  while true {
    await checkShouldContinue()
    let blockInterval = self.currentBlockInterval
    let targetBlock = Pervasives.min(
      currentBlock.contents,
      fromBlockRef.contents + blockInterval - 1,
    )

    self.currentlyFetchingToBlock = targetBlock

    let toBlockTimestampPromise =
      blockLoader
      ->LazyLoader.get(self.currentlyFetchingToBlock)
      ->Promise.thenResolve(block => block.timestamp)

    //Needs to be run on every loop in case of new registrations
    let eventFilters = EventFetching.getAllEventFilters(
      ~addressInterfaceMapping,
      ~chainConfig,
      ~provider,
      ~contractAddressMapping,
    )

    let {
      eventBatchPromises,
      finalExecutedBlockInterval,
    } = await EventFetching.getContractEventsOnFilters(
      ~eventFilters,
      ~addressInterfaceMapping,
      ~contractAddressMapping,
      ~fromBlock=fromBlockRef.contents,
      ~toBlock=targetBlock,
      ~initialBlockInterval=blockInterval,
      ~minFromBlockLogIndex=0,
      ~chainConfig,
      ~blockLoader,
      ~logger,
      (),
    )

    for i in 0 to eventBatchPromises->Belt.Array.length - 1 {
      let {timestampPromise, chainId, blockNumber, logIndex, eventPromise} = eventBatchPromises[i]

      let queueItem: EventFetching.eventBatchQueueItem = {
        timestamp: await timestampPromise,
        chainId,
        blockNumber,
        logIndex,
        event: await eventPromise,
      }

      await fetchedEventQueue->ChainEventQueue.awaitQueueSpaceAndPushItem(queueItem)
    }

    fromBlockRef := targetBlock + 1

    // Increase batch size going forward, but do not increase past a configured maximum
    // See: https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease
    self.currentBlockInterval = Pervasives.min(
      finalExecutedBlockInterval + sc.accelerationAdditive,
      sc.intervalCeiling,
    )

    //Set the latest fetched blocktimestamp in state
    self.latestFetchedBlockTimestamp = await toBlockTimestampPromise

    //Loop through any callbacks on the queue waiting for confirmation of a new
    //range queried and run callbacks
    self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())

    // Only fetch the current block if it could affect the length of our next batch
    let nextIntervalEnd = fromBlockRef.contents + self.currentBlockInterval - 1
    if currentBlock.contents <= nextIntervalEnd {
      logger->Logging.childInfo(
        `We will finish processing known blocks in the next block. Checking for a newer block than ${currentBlock.contents->Belt.Int.toString}`,
      )
      currentBlock := (await getCurrentBlockFromRPC())
      logger->Logging.childInfo(
        `getCurrentBlockFromRPC() => ${currentBlock.contents->Belt.Int.toString}`,
      )
    }
  }
}

//Pops the front item on the fetchedEventQueue and awaits an item if there is none
let popAndAwaitQueueItem = async (self: t): eventType => {
  await self.fetchedEventQueue->ChainEventQueue.popSingleAndAwaitItem
}

//Pops the front item on the fetchedEventQueue
let popQueueItem = (self: t): option<eventType> => {
  self.fetchedEventQueue->ChainEventQueue.popSingle
}

//Registers the new contract
//fetches all the unfetched events
let addDynamicContractAndFetchMissingEvents = async (
  self: t,
  ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ~fromBlock,
  ~fromLogIndex,
): array<EventFetching.eventBatchQueueItem> => {
  let {
    chainConfig,
    contractAddressMapping,
    logger,
    currentBlockInterval,
    blockLoader,
    currentlyFetchingToBlock,
  } = self

  let addressInterfaceMapping = Js.Dict.empty()
  //execute query from block to currently currentlyFetchingToBlock
  //return values

  let eventFilters = dynamicContracts->Belt.Array.flatMap(dynamicContract => {
    let {contractAddress, contractType} = dynamicContract

    //For each contract register the address
    contractAddressMapping->ContractAddressingMap.addAddress(
      ~name=contractType,
      ~address=contractAddress,
    )

    //Return a filter for the address with the given topics
    EventFetching.getSingleContractEventFilters(
      ~contractAddress,
      ~addressInterfaceMapping,
      ~chainConfig,
      ~contractAddressMapping,
      ~logger,
    )
  })

  let {eventBatchPromises} = await EventFetching.getContractEventsOnFilters(
    ~eventFilters,
    ~addressInterfaceMapping,
    ~contractAddressMapping,
    ~fromBlock,
    ~toBlock=currentlyFetchingToBlock, //Fetch up till the block that the worker has not included this address
    ~initialBlockInterval=currentBlockInterval,
    ~minFromBlockLogIndex=fromLogIndex,
    ~chainConfig,
    ~blockLoader,
    ~logger,
    (),
  )
  await eventBatchPromises
  ->Belt.Array.map(async ({
    timestampPromise,
    chainId,
    blockNumber,
    logIndex,
    eventPromise,
  }): EventFetching.eventBatchQueueItem => {
    timestamp: await timestampPromise,
    chainId,
    blockNumber,
    logIndex,
    event: await eventPromise,
  })
  ->Promise.all
}

type latestFetchedBlockTimestamp = int
type eventQueuePeek =
  NoItem(latestFetchedBlockTimestamp, Types.chainId) | Item(EventFetching.eventBatchQueueItem)

let peekFrontItemOfQueue = (self: t): eventQueuePeek => {
  let optFront = self.fetchedEventQueue->ChainEventQueue.peekFront

  switch optFront {
  | None => NoItem(self.latestFetchedBlockTimestamp, self.chainConfig.chainId)
  | Some(item) => Item(item)
  }
}

let addNewRangeQueriedCallback = (self: t) => {
  self.newRangeQueriedCallBacks->ChainEventQueue.insertCallbackAwaitPromise
}
