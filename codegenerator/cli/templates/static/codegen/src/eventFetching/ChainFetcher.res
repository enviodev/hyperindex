type t = {
  logger: Pino.t,
  fetchedEventQueue: ChainEventQueue.t,
  chainConfig: Config.chainConfig,
  chainWorker: ref<ChainWorker.chainWorker>,
}

//CONSTRUCTION
let make = (~chainConfig: Config.chainConfig, ~maxQueueSize, ~shouldSyncFromRawEvents: bool): t => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chainId})

  //Dangerous! Ref is not defined yet but will be defined in the next step
  let chainWorkerRef = ref(None->Obj.magic)

  let chainConfigWorkerNoCallback = {
    let noneCallback = None
    switch chainConfig.syncSource {
    | Rpc(_) => ChainWorker.RpcSelectedWithCallback(noneCallback)
    | Skar(_) => ChainWorker.SkarSelectedWithCallback(noneCallback)
    | EthArchive(_) => ChainWorker.EthArchiveSelectedWithCallback(noneCallback)
    }
  }

  let chainWorkerWithCallback = if shouldSyncFromRawEvents {
    let finishedSyncCallback = async (worker: ChainWorker.RawEventsWorker.t) => {
      await worker->ChainWorker.RawEventsWorker.stopFetchingEvents
      chainWorkerRef := chainConfigWorkerNoCallback->ChainWorker.make(~chainConfig)
    }
    ChainWorker.RawEventsSelectedWithCallback(Some(finishedSyncCallback))
  } else {
    chainConfigWorkerNoCallback
  }

  chainWorkerRef := chainWorkerWithCallback->ChainWorker.make(~chainConfig)

  {
    fetchedEventQueue: ChainEventQueue.make(~maxQueueSize),
    logger,
    chainConfig,
    chainWorker: chainWorkerRef,
  }
}

//Public methods
let startFetchingEvents = async (self: t) => {
  switch self.chainWorker.contents->ChainWorker.startFetchingEvents(
    ~logger=self.logger,
    ~fetchedEventQueue=self.fetchedEventQueue,
  ) {
  | exception err =>
    self.logger->Logging.childError({
      "err": err,
      "msg": `error while running chainWorker on chain ${self.chainConfig.chainId->Belt.Int.toString}`,
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
  NoItem(latestFetchedBlockTimestamp, Types.chainId) | Item(Types.eventBatchQueueItem)

let peekFrontItemOfQueue = (self: t): eventQueuePeek => {
  let optFront = self.fetchedEventQueue->ChainEventQueue.peekFront

  switch optFront {
  | None =>
    let latestFetchedBlockTimestamp =
      self.chainWorker.contents->ChainWorker.getLatestFetchedBlockTimestamp
    NoItem(latestFetchedBlockTimestamp, self.chainConfig.chainId)
  | Some(item) => Item(item)
  }
}

let addNewRangeQueriedCallback = (self: t) => {
  ChainWorker.addNewRangeQueriedCallback(self.chainWorker.contents)
}
