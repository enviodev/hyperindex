// TODO: add back warnings when ready!
type chainId = int
exception UndefinedChainConfig(chainId)

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

  let getLatestFetchedBlockTimestamp: t => int

  let addDynamicContractAndFetchMissingEvents: (
    t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock: int,
    ~fromLogIndex: int,
    ~logger: Pino.t,
  ) => promise<array<EventFetching.eventBatchQueueItem>>
}

module SkarWorker: ChainWorker = {
  type t = {
    mutable latestFetchedBlockNumber: promise<int>, // promise allows locking of this field while a batch has been fetched but still being added
    mutable latestFetchedBlockTimestamp: int,
    mutable hasNewDynamicContractRegistrations: promise<bool>, //promise allows us to use this field as a lock
    newRangeQueriedCallBacks: SDSL.Queue.t<unit => unit>,
    contractAddressMapping: ContractAddressingMap.mapping,
    chainConfig: Config.chainConfig,
    serverUrl: string,
  }

  let make = (chainConfig: Config.chainConfig): t => {
    let contractAddressMapping = ContractAddressingMap.make()
    let logger = Logging.createChild(
      ~params={
        "chainId": chainConfig.chainId,
        "workerType": "skar",
        "loggerFor": "Used only in logging regestration of static contract addresses",
      },
    )
    //Add all contracts and addresses from config
    //Dynamic contracts are checked in DB on start
    contractAddressMapping->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)

    {
      latestFetchedBlockNumber: Promise.resolve(0),
      latestFetchedBlockTimestamp: 0,
      hasNewDynamicContractRegistrations: Promise.resolve(false),
      newRangeQueriedCallBacks: SDSL.Queue.make(),
      contractAddressMapping,
      chainConfig,
      serverUrl: SkarQueryBuilder.skarEndpoint,
    }
  }

  let startFetchingEvents = async (
    self: t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => {
    logger->Logging.childTrace("Starting event fetching on Skar worker")

    let {chainConfig, contractAddressMapping} = self
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

    let initialHeightRes = await Skar.getArchiveHeight(~serverUrl=self.serverUrl)
    let initialHeightUnsafe = initialHeightRes->Belt.Result.getExn

    let currentHeight = ref(initialHeightUnsafe)
    let fromBlock = ref(startBlock)

    let checkReadyToContinue = async () => {
      if fromBlock.contents > currentHeight.contents {
        //If the block we want to query from is greater than the current height,
        //poll for until the archive height is greater than the from block and set
        //current height to the new height
        currentHeight :=
          (
            await SkarQueryBuilder.HeightQuery.pollForHeightGtOrEq(
              ~blockNumber=fromBlock.contents,
              ~logger,
            )
          )
      }
    }

    while true {
      //Check to see there is a new batch to query
      await checkReadyToContinue()

      //Instantiate each time to add new registered contract addresses
      let contractInterfaceManager = ContractInterfaceManager.make(
        ~chainConfig,
        ~contractAddressMapping,
      )

      let {addresses, topics} =
        contractInterfaceManager->ContractInterfaceManager.getAllTopicsAndAddresses

      //Just the topics of the event signature and no topics related
      //to indexed parameters
      let topLevelTopics = [topics]

      let startFetchingBatchTimeRef = Hrtime.makeTimer()

      //fetch batch
      let page = await SkarQueryBuilder.LogsQuery.queryLogsPage(
        ~fromBlock=fromBlock.contents,
        ~toBlock=currentHeight.contents,
        ~addresses,
        ~topics=topLevelTopics,
      )

      let elapsedTimeFetchingPage =
        startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

      logger->Logging.childTrace({
        "message": "Retrieved event page from server",
        "fromBlock": fromBlock.contents,
        "toBlock": page.nextBlock - 1,
        "number of logs": page.items->Array.length,
      })

      //Start query for heighest block queried to get latest timestamp
      let heighestBlockQueried = page.archiveHeight - 1
      let heighestBlockQueriedPagePromise = SkarQueryBuilder.BlockTimestampQuery.queryBlockTimestampsPage(
        ~fromBlock=heighestBlockQueried,
        ~toBlock=heighestBlockQueried,
      )

      if await self.hasNewDynamicContractRegistrations {
        //If there are new dynamic contract registrations
        //discard this batch and redo the query with new address
        self.hasNewDynamicContractRegistrations = Promise.resolve(false)

        logger->Logging.childTrace({
          "message": "Dropping invalid batch due to new dynamic contract registration",
          "page fetch time elapsed (ms)": elapsedTimeFetchingPage,
        })
      } else {
        //Lock the latest fetched blockNumber until it gets
        //set with the timestamp later.
        //Lock is to prevent race condition when looking up from dynamic contract registration
        let {
          pendingPromise: latestBlockNumbersPromise,
          resolve: latestBlockNumbersResolve,
        } = Utils.createPromiseWithHandles()
        self.latestFetchedBlockNumber = latestBlockNumbersPromise

        let parsingTimeRef = Hrtime.makeTimer()
        //Parse page items into queue items
        let parsedQueueItems = page.items->Belt.Array.map(item => {
          let parsedUnsafe =
            Converters.parseEvent(
              ~log=item.log,
              ~blockTimestamp=item.blockTimestamp,
              ~contractInterfaceManager,
            )->Belt.Result.getExn

          let queueItem: EventFetching.eventBatchQueueItem = {
            timestamp: item.blockTimestamp,
            chainId: chainConfig.chainId,
            blockNumber: item.log.blockNumber,
            logIndex: item.log.logIndex,
            event: parsedUnsafe,
          }
          queueItem
        })

        let parsingTimeElapsed =
          parsingTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

        let queuePushingTimeRef = Hrtime.makeTimer()

        //Loop through items, add them to the queue
        for i in 0 to parsedQueueItems->Array.length - 1 {
          let queueItem = parsedQueueItems[i]

          //Add item to the queue
          await fetchedEventQueue->ChainEventQueue.awaitQueueSpaceAndPushItem(queueItem)

          //Loop through any callbacks on the queue waiting for confirmation of a new
          //range queried and run callbacks needs to happen after each item is added
          //else this we could be blocked from adding items to the queue and from popping
          //items off without running callbacks
          self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())
        }

        let queuePushingTimeElapsed =
          queuePushingTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

        //set latestFetchedBlockNumber and latestFetchedBlockTimestamp
        let heighestBlockQueriedPage = await heighestBlockQueriedPagePromise

        //Used in failure case of query
        let fallbackUpdateLatestFetchedValuesToLastInBatch = () => {
          let lastItemInBatch = page.items->Belt.Array.get(page.items->Array.length)
          lastItemInBatch
          ->Belt.Option.map(item => {
            //Set the latest fetched timestamp to the last item in the batch timestamp
            //Note this could be lower than the block we were querying until
            //But its only used in query failure and it will still help unblock chain manager queues
            self.latestFetchedBlockTimestamp = item.blockTimestamp
          })
          ->ignore

          //We know the latest fetched block number since it will be the one before nextBlock
          self.latestFetchedBlockNumber = latestBlockNumbersResolve(page.nextBlock - 1)
        }

        switch heighestBlockQueriedPage {
        | Ok(page) =>
          //Expected only 1 item but just taking last in case things change and we return
          //a range
          let lastBlockInRangeQueried = page.items->Belt.Array.get(page.items->Array.length)

          switch lastBlockInRangeQueried {
          | Some(block) =>
            //Set the latest fetched data to the queried block
            self.latestFetchedBlockTimestamp = block.timestamp
            self.latestFetchedBlockNumber = latestBlockNumbersResolve(block.blockNumber)
          | None => fallbackUpdateLatestFetchedValuesToLastInBatch()
          }
        | Error(err) => fallbackUpdateLatestFetchedValuesToLastInBatch()
        }
        //Loop through any callbacks on the queue waiting for confirmation of a new
        //range queried and run callbacks since there will be an updated timestamp even
        //If there ar no items in the page
        self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())

        //set height and next from block
        currentHeight := page.archiveHeight
        fromBlock := page.nextBlock

        let totalTimeElapsed =
          startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

        logger->Logging.childTrace({
          "message": "Finished page range",
          "fromBlock": fromBlock.contents,
          "toBlock": await self.latestFetchedBlockNumber,
          "total time elapsed (ms)": totalTimeElapsed,
          "page fetch time (ms)": elapsedTimeFetchingPage,
          "parsing time (ms)": parsingTimeElapsed,
          "average parse time per log (ms)": parsingTimeElapsed->Belt.Int.toFloat /.
            parsedQueueItems->Array.length->Belt.Int.toFloat,
          "push to queue time (ms)": queuePushingTimeElapsed,
        })
      }
    }
  }

  let addNewRangeQueriedCallback = (self: t): promise<unit> => {
    self.newRangeQueriedCallBacks->ChainEventQueue.insertCallbackAwaitPromise
  }

  let getLatestFetchedBlockTimestamp = (self: t) => self.latestFetchedBlockTimestamp

  let addDynamicContractAndFetchMissingEvents = async (
    self: t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock,
    ~fromLogIndex,
    ~logger,
  ): array<EventFetching.eventBatchQueueItem> => {
    let {pendingPromise, resolve} = Utils.createPromiseWithHandles()

    //Perform registering and updatiing "hasNewDynamicContractRegistrations" inside a lock
    //To avoid race condition where fetcher sees that there are new contracts to register but
    //they are still busy being registered (this would cause an improper batch query with missing
    //addresses from the fetcher) or that the "hasNewDynamicContractRegistrations" state has not been
    //set to true yet but there are infact new registrations and a batch could be processed when it should
    //be discarded
    self.hasNewDynamicContractRegistrations = pendingPromise

    dynamicContracts->Belt.Array.forEach(({contractAddress, contractType, chainId}) => {
      self.contractAddressMapping->ContractAddressingMap.addAddress(
        ~address=contractAddress,
        ~name=contractType,
      )
    })

    self.hasNewDynamicContractRegistrations = resolve(true)

    let contractInterfaceManager =
      dynamicContracts
      ->Belt.Array.map(({contractAddress, contractType, chainId}) => {
        let chainConfig = switch Config.config->Js.Dict.get(chainId->Belt.Int.toString) {
        | None =>
          let exn = UndefinedChainConfig(chainId)
          logger->Logging.childErrorWithExn(exn, "Could not find chain config for given ChainId")
          exn->raise
        | Some(c) => c
        }

        let singleContractInterfaceManager = ContractInterfaceManager.makeFromSingleContract(
          ~contractAddress,
          ~contractName=contractType,
          ~chainConfig,
        )

        singleContractInterfaceManager
      })
      ->ContractInterfaceManager.combineInterfaceManagers

    //to be populated in queries
    let queueItems: array<EventFetching.eventBatchQueueItem> = []

    let fromBlockRef = ref(fromBlock)
    let toBlock = await self.latestFetchedBlockNumber

    logger->Logging.childTrace({
      "message": "Registering dynamic contracts",
      "contracts": dynamicContracts,
      "fromBlock": fromBlock,
      "fromLogIndex": fromLogIndex,
      "toBlock": toBlock,
    })

    while fromBlockRef.contents < toBlock {
      let {addresses, topics} =
        contractInterfaceManager->ContractInterfaceManager.getAllTopicsAndAddresses

      //Just the topics of the event signature and no topics related
      //to indexed parameters
      let topLevelTopics = [topics]

      //fetch batch
      let page = await SkarQueryBuilder.LogsQuery.queryLogsPage(
        ~fromBlock=fromBlockRef.contents,
        ~toBlock,
        ~addresses,
        ~topics=topLevelTopics,
      )

      page.items->Belt.Array.forEach(item => {
        //Logs in the same block as the log that called for dynamic contract registration
        //should not be included if they occurred before the contract registering log
        let logIsNotBeforeContractRegisteringLog = !(
          item.log.blockNumber == fromBlock && item.log.logIndex <= fromLogIndex
        )

        if logIsNotBeforeContractRegisteringLog {
          let parsedUnsafe =
            Converters.parseEvent(
              ~log=item.log,
              ~blockTimestamp=item.blockTimestamp,
              ~contractInterfaceManager,
            )->Belt.Result.getExn

          let queueItem: EventFetching.eventBatchQueueItem = {
            timestamp: item.blockTimestamp,
            chainId: self.chainConfig.chainId,
            blockNumber: item.log.blockNumber,
            logIndex: item.log.logIndex,
            event: parsedUnsafe,
          }

          queueItems->Js.Array2.push(queueItem)->ignore
        }
      })

      fromBlockRef := page.nextBlock
    }

    queueItems
  }
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
    let logger = Logging.createChild(
      ~params={
        "chainId": chainConfig.chainId,
        "workerType": "rpc",
        "loggerFor": "Used only in logging regestration of static contract addresses",
      },
    )

    //Add all contracts and addresses from config
    //Dynamic contracts are checked in DB on start
    contractAddressMapping->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)

    let blockLoader = LazyLoader.make(
      ~loaderFn=blockNumber =>
        EventFetching.getUnwrappedBlockWithBackoff(
          ~provider=chainConfig.provider,
          ~backoffMsOnFailure=1000,
          ~blockNumber,
        ),
      ~metadata={
        asyncTaskName: "blockLoader: fetching block timestamp - `getBlock` rpc call",
        caller: "RPC ChainWorker",
        suggestedFix: "This likely means the RPC url you are using is not respending correctly. Please try another RPC endipoint.",
      },
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
      let contractInterfaceManager = ContractInterfaceManager.make(
        ~contractAddressMapping,
        ~chainConfig,
      )

      let {
        eventBatchPromises,
        finalExecutedBlockInterval,
      } = await EventFetching.getContractEventsOnFilters(
        ~contractInterfaceManager,
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

        //Loop through any callbacks on the queue waiting for confirmation of a new
        //range queried and run callbacks needs to happen after each item is added
        //else this we could be blocked from adding items to the queue and from popping
        //items off without running callbacks
        self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())
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

    let contractInterfaceManager =
      dynamicContracts
      ->Belt.Array.map(({contractAddress, contractType, chainId}) => {
        let chainConfig = switch Config.config->Js.Dict.get(chainId->Belt.Int.toString) {
        | None =>
          let exn = UndefinedChainConfig(chainId)
          logger->Logging.childErrorWithExn(exn, "Could not find chain config for given ChainId")
          exn->raise
        | Some(c) => c
        }

        let singleContractInterfaceManager = ContractInterfaceManager.makeFromSingleContract(
          ~contractAddress,
          ~contractName=contractType,
          ~chainConfig,
        )

        singleContractInterfaceManager
      })
      ->ContractInterfaceManager.combineInterfaceManagers

    let {eventBatchPromises} = await EventFetching.getContractEventsOnFilters(
      ~contractInterfaceManager,
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

  let getLatestFetchedBlockTimestamp = (self: t): int => self.latestFetchedBlockTimestamp
}

type workerTypeSelected = RpcSelected | SkarSelected
type chainWorker = Rpc(RpcWorker.t) | Skar(SkarWorker.t)

module PolyMorphicChainWorkerFunctions = {
  /* Why use thes polymorphic functions rather than calling function directly on
  the chainworker?

  We could just call the function on the worker when matching on the chainWorker type.
  ie. ... | Rpc(worker) => worker->RpcWorker.startFetchingEvents() ...

  Instead we have these polymorphic functions that take a tuple with worker with it's module type,
  and calls the chain worker function.

  The only real benefit is that it forces us to use functions on the ChainWorker module signature.
  Which will hopefully keep this somewhat modular. 

  The chainworkerModTuple type enforces that the worker type and module conform to the chainworker 
  signature. And the polymorphic functions only call functions on that signature.

  chainWorker variants can be converted to this type, and used with the polymorphic functions.

  It's not the prettiest interface, and if readability is ever chosen over this enforced module signature
  pattern then these polymorphic functions can be removed and the functions can be accessed/called directly
  on the underlying worker module.
 */

  type chainWorkerModTuple<'workerType> = (
    'workerType,
    module(ChainWorker with type t = 'workerType),
  )

  let startFetchingEvents = (
    type workerType,
    chainWorkerModTuple: chainWorkerModTuple<workerType>,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => {
    let (worker, workerMod) = chainWorkerModTuple
    let module(ChainWorker) = workerMod
    worker->ChainWorker.startFetchingEvents(~logger, ~fetchedEventQueue)
  }

  let addNewRangeQueriedCallback = (
    type workerType,
    chainWorkerModTuple: chainWorkerModTuple<workerType>,
  ) => {
    let (worker, workerMod) = chainWorkerModTuple
    let module(M) = workerMod
    worker->M.addNewRangeQueriedCallback
  }

  let getLatestFetchedBlockTimestamp = (
    type workerType,
    chainWorkerModTuple: chainWorkerModTuple<workerType>,
  ) => {
    let (worker, workerMod) = chainWorkerModTuple
    let module(M) = workerMod
    worker->M.getLatestFetchedBlockTimestamp
  }

  let addDynamicContractAndFetchMissingEvents = (
    type workerType,
    chainWorkerModTuple: chainWorkerModTuple<workerType>,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock,
    ~fromLogIndex,
    ~logger,
  ): promise<array<EventFetching.eventBatchQueueItem>> => {
    let (worker, workerMod) = chainWorkerModTuple
    let module(M) = workerMod
    //Note: Only defining f so my syntax highlighting doesn't break -> Jono
    let f = worker->M.addDynamicContractAndFetchMissingEvents
    f(~dynamicContracts, ~fromBlock, ~fromLogIndex, ~logger)
  }

  type chainWorkerMod =
    | RpcWorkerMod(chainWorkerModTuple<RpcWorker.t>)
    | SkarWorkerMod(chainWorkerModTuple<SkarWorker.t>)

  let chainWorkerToChainMod = (worker: chainWorker) => {
    switch worker {
    | Rpc(w) => RpcWorkerMod((w, module(RpcWorker)))
    | Skar(w) => SkarWorkerMod((w, module(SkarWorker)))
    }
  }
}

let startFetchingEvents = (worker: chainWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  open PolyMorphicChainWorkerFunctions
  switch worker->chainWorkerToChainMod {
  | RpcWorkerMod(w) => w->startFetchingEvents
  | SkarWorkerMod(w) => w->startFetchingEvents
  }
}

let addNewRangeQueriedCallback = (worker: chainWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  open PolyMorphicChainWorkerFunctions
  switch worker->chainWorkerToChainMod {
  | RpcWorkerMod(w) => w->addNewRangeQueriedCallback
  | SkarWorkerMod(w) => w->addNewRangeQueriedCallback
  }
}

let getLatestFetchedBlockTimestamp = (worker: chainWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  open PolyMorphicChainWorkerFunctions
  switch worker->chainWorkerToChainMod {
  | RpcWorkerMod(w) => w->getLatestFetchedBlockTimestamp
  | SkarWorkerMod(w) => w->getLatestFetchedBlockTimestamp
  }
}

let addDynamicContractAndFetchMissingEvents = (worker: chainWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  open PolyMorphicChainWorkerFunctions
  switch worker->chainWorkerToChainMod {
  | RpcWorkerMod(w) => w->addDynamicContractAndFetchMissingEvents
  | SkarWorkerMod(w) => w->addDynamicContractAndFetchMissingEvents
  }
}

let make = (selectedWorker: workerTypeSelected, ~chainConfig) => {
  switch selectedWorker {
  | RpcSelected => Rpc(RpcWorker.make(chainConfig))
  | SkarSelected => Skar(SkarWorker.make(chainConfig))
  }
}
