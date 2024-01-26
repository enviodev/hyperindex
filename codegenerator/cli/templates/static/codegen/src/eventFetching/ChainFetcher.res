type t = {
  logger: Pino.t,
  fetchedEventQueue: ChainEventQueue.t,
  chainConfig: Config.chainConfig,
  chainWorker: ref<ChainWorker.chainWorker>,
  mutable lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.t,
}

//CONSTRUCTION
let make = (
  ~chainConfig: Config.chainConfig,
  ~lastBlockScannedHashes,
  ~maxQueueSize,
  ~shouldSyncFromRawEvents: bool,
): t => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chain})

  //Dangerous! Ref is not defined yet but will be defined in the next step
  let chainWorkerRef = ref(None->Obj.magic)

  let chainConfigWorkerNoCallback = {
    let noneCallback = None
    switch chainConfig.syncSource {
    | Rpc(_) => ChainWorker.RpcSelectedWithCallback(noneCallback)
    | HyperSync(_) => ChainWorker.HyperSyncSelectedWithCallback(noneCallback)
    }
  }
  let fetchedEventQueue = ChainEventQueue.make(~maxQueueSize)

  //TODO: Purge resync code or reimplement
  let chainWorkerWithCallback = chainConfigWorkerNoCallback
  let _ = shouldSyncFromRawEvents
  // if shouldSyncFromRawEvents {
  //   let finishedSyncCallback = async (worker: RawEventsWorker.t) => {
  //     await worker->RawEventsWorker.stopFetchingEvents
  //     logger->Logging.childInfo("Finished reprocessed cached events, starting fetcher")
  //     let contractAddressMapping = worker.contractAddressMapping
  //
  //     let latestFetchedEventId = await worker.latestFetchedEventId
  //     let {blockNumber} = latestFetchedEventId->EventUtils.unpackEventIndex
  //     let startBlock = blockNumber + 1
  //     chainWorkerRef :=
  //       chainConfigWorkerNoCallback->ChainWorker.make(~chainConfig, ~contractAddressMapping)
  //
  //     chainWorkerRef.contents
  //     ->ChainWorker.startWorker(~startBlock, ~fetchedEventQueue, ~logger, ~checkHasReorgOccurred)
  //     ->ignore
  //   }
  //
  //   ChainWorker.RawEventsSelectedWithCallback(Some(finishedSyncCallback))
  // } else {
  //   chainConfigWorkerNoCallback
  // }

  chainWorkerRef := chainWorkerWithCallback->ChainWorker.make(~chainConfig)

  {
    fetchedEventQueue,
    logger,
    chainConfig,
    chainWorker: chainWorkerRef,
    lastBlockScannedHashes,
  }
}

//Public methods
let startFetchingEvents = async (self: t, ~checkHasReorgOccurred) => {
  switch self.chainWorker.contents->ChainWorker.startFetchingEvents(
    ~logger=self.logger,
    ~fetchedEventQueue=self.fetchedEventQueue,
    ~checkHasReorgOccurred=self->checkHasReorgOccurred,
  ) {
  | exception err =>
    self.logger->Logging.childError({
      "err": err,
      "msg": `error while running chainWorker on chain ${self.chainConfig.chain->ChainMap.Chain.toString}`,
    })
    Error(err)
  | _ => Ok()
  }
}

/**
Pops the front item on the fetchedEventQueue and awaits an item if there is none
*/
let popAndAwaitQueueItem = async (self: t): Types.eventBatchQueueItem => {
  await self.fetchedEventQueue->ChainEventQueue.popSingleAndAwaitItem
}

/**
Pops the front item on the fetchedEventQueue
*/
let popQueueItem = (self: t): option<Types.eventBatchQueueItem> => {
  self.fetchedEventQueue->ChainEventQueue.popSingle
}

/**
Registers the new contract
fetches all the unfetched events
*/
let addDynamicContractAndFetchMissingEvents = (
  self: t,
  ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ~fromBlock,
  ~fromLogIndex,
): promise<array<Types.eventBatchQueueItem>> => {
  self.chainWorker.contents->ChainWorker.addDynamicContractAndFetchMissingEvents(
    ~dynamicContracts,
    ~fromBlock,
    ~fromLogIndex,
    ~logger=self.logger,
  )
}

type latestFetchedBlockTimestamp = int
type eventQueuePeek =
  NoItem(latestFetchedBlockTimestamp, ChainMap.Chain.t) | Item(Types.eventBatchQueueItem)

let peekFrontItemOfQueue = (self: t): eventQueuePeek => {
  let optFront = self.fetchedEventQueue->ChainEventQueue.peekFront

  switch optFront {
  | None =>
    let latestFetchedBlockTimestamp =
      self.chainWorker.contents->ChainWorker.getLatestFetchedBlockTimestamp
    NoItem(latestFetchedBlockTimestamp, self.chainConfig.chain)
  | Some(item) => Item(item)
  }
}

let addNewRangeQueriedCallback = (self: t) => {
  ChainWorker.addNewRangeQueriedCallback(self.chainWorker.contents)
}
