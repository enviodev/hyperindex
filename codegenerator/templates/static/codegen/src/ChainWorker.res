
// TODO: add back warnings when ready!

@@warning("-27")
module type ChainWorker = {
  type t

  let make: Config.chainConfig => t

  let startFetchingEvents: (
    t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => promise<unit>

  let addNewRangeQueriedCallback: t => promise<unit>

  let getCurrentlyFetchingToBlock: t => int
  let getLatestFetchedBlockTimestamp: t => int

  let addDynamicContractAndFetchMissingEvents: (
    t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock: int,
    ~fromLogIndex: int,
    ~logger: Pino.t,
  ) => promise<array<EventFetching.eventBatchQueueItem>>
}

let startFethcingEventsOnWorker = (
  type workerType,
  (worker: workerType, workerMod: module(ChainWorker with type t = workerType)),
  ~logger: Pino.t,
  ~fetchedEventQueue: ChainEventQueue.t,
) => {
  let module(ChainWorker) = workerMod
  worker->ChainWorker.startFetchingEvents(~logger, ~fetchedEventQueue)
}

let addNewRangeQueriedCallback = (
  type workerType,
  (worker: workerType, workerMod: module(ChainWorker with type t = workerType)),
) => {
  let module(M) = workerMod
  worker->M.addNewRangeQueriedCallback
}

let getLatestFetchedBlockTimestamp = (
  type workerType,
  (worker: workerType, workerMod: module(ChainWorker with type t = workerType)),
) => {
  let module(M) = workerMod
  worker->M.getLatestFetchedBlockTimestamp
}

let getCurrentlyFetchingToBlock = (
  type workerType,
  (worker: workerType, workerMod: module(ChainWorker with type t = workerType)),
) => {
  let module(M) = workerMod
  worker->M.getCurrentlyFetchingToBlock
}

let addDynamicContractAndFetchMissingEvents = (
  type workerType,
  (worker: workerType, workerMod: module(ChainWorker with type t = workerType)),
  ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ~fromBlock,
  ~fromLogIndex,
  ~logger,
): promise<array<EventFetching.eventBatchQueueItem>> => {
  let module(M) = workerMod
  //Note: Only defining f so my syntax highlighting doesn't break -> Jono
  let f = worker->M.addDynamicContractAndFetchMissingEvents
  f(~dynamicContracts, ~fromBlock, ~fromLogIndex, ~logger)
}

module SkarWorker: ChainWorker = {
  type t = string

  let make = chainConfig => {
    Js.log(chainConfig)
    "I am the config"
  }

  let startFetchingEvents = async (
    self: t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => {
    Js.log("I am running the skar worker")
    ()
  }

  let addNewRangeQueriedCallback = (self: t) => Promise.resolve()
  let getCurrentlyFetchingToBlock = (self: t) => 1
  let getLatestFetchedBlockTimestamp = (self: t) => 1

  let addDynamicContractAndFetchMissingEvents = async (
    self: t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock,
    ~fromLogIndex,
    ~logger,
  ): array<EventFetching.eventBatchQueueItem> => {[]}
}

module RawEventsWorker: ChainWorker = {
  type t = int

  let make = chainConfig => {
    Js.log(chainConfig)
    987654321
  }

  let startFetchingEvents = async (
    self: t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => {
    Js.log("I am running the raw worker")
    ()
  }

  let addNewRangeQueriedCallback = (self: t) => Promise.resolve()
  let getCurrentlyFetchingToBlock = (self: t) => 1
  let getLatestFetchedBlockTimestamp = (self: t) => 1

  let addDynamicContractAndFetchMissingEvents = async (
    self: t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock,
    ~fromLogIndex,
    ~logger,
  ): array<EventFetching.eventBatchQueueItem> => {[]}
}

module RpcWorker: ChainWorker = {
  type t = {
    mutable currentBlockInterval: int,
    mutable currentlyFetchingToBlock: int,
    mutable latestFetchedBlockTimestamp: int,
    newRangeQueriedCallBacks: SDSL.Queue.t<unit => unit>,
    contractAddressMapping: ContractAddressingMap.mapping,
    blockLoader: LazyLoader.asyncMap<Ethers.JsonRpcProvider.block>,
    chainConfig: Config.chainConfig,
  }

  let make = (chainConfig: Config.chainConfig): t => {
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
      blockLoader,
      chainConfig,
    }
  }

  //Public methods
  let startFetchingEvents = async (
    self: t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => {
    let {chainConfig, contractAddressMapping, blockLoader} = self
    let latestProcessedBlock = await DbFunctions.RawEvents.getLatestProcessedBlockNumber(
      ~chainId=chainConfig.chainId,
    )

    let startBlock =
      latestProcessedBlock->Belt.Option.mapWithDefault(
        chainConfig.startBlock,
        latestProcessedBlock => latestProcessedBlock + 1,
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

    //Registers the new contract
    //fetches all the unfetched events
  }

  let addDynamicContractAndFetchMissingEvents = async (
    self: t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock,
    ~fromLogIndex,
    ~logger,
  ): array<EventFetching.eventBatchQueueItem> => {
    let {
      chainConfig,
      contractAddressMapping,
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
  let addNewRangeQueriedCallback = (self: t): promise<unit> => {
    self.newRangeQueriedCallBacks->ChainEventQueue.insertCallbackAwaitPromise
  }

  let getCurrentlyFetchingToBlock = (self: t): int => self.currentlyFetchingToBlock
  let getLatestFetchedBlockTimestamp = (self: t): int => self.latestFetchedBlockTimestamp
}
