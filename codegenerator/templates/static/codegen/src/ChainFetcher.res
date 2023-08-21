// TODO: move to `eventFetching`

type t = {
  logger: Pino.t,
  fetchedEventQueue: ChainEventQueue.t,
  chainConfig: Config.chainConfig,
  chainWorker: ChainWorker.chainWorker,
}

//CONSTRUCTION
let make = (
  ~chainConfig: Config.chainConfig,
  ~maxQueueSize,
  ~chainWorkerTypeSelected: Env.workerTypeSelected,
): t => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chainId})
  let chainWorker = chainWorkerTypeSelected->ChainWorker.make(~chainConfig)

  {
    fetchedEventQueue: ChainEventQueue.make(~maxQueueSize),
    logger,
    chainConfig,
    chainWorker,
  }
}

//Public methods
let startFetchingEvents = async (self: t) => {
  switch self.chainWorker->ChainWorker.startFetchingEvents(
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
let popAndAwaitQueueItem = async (self: t): EventFetching.eventBatchQueueItem => {
  await self.fetchedEventQueue->ChainEventQueue.popSingleAndAwaitItem
}

/**
Pops the front item on the fetchedEventQueue
*/
let popQueueItem = (self: t): option<EventFetching.eventBatchQueueItem> => {
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
): promise<array<EventFetching.eventBatchQueueItem>> => {
  self.chainWorker->ChainWorker.addDynamicContractAndFetchMissingEvents(
    ~dynamicContracts,
    ~fromBlock,
    ~fromLogIndex,
    ~logger=self.logger,
  )
}

type latestFetchedBlockTimestamp = int
type eventQueuePeek =
  NoItem(latestFetchedBlockTimestamp, Types.chainId) | Item(EventFetching.eventBatchQueueItem)

let peekFrontItemOfQueue = (self: t): eventQueuePeek => {
  let optFront = self.fetchedEventQueue->ChainEventQueue.peekFront

  switch optFront {
  | None =>
    let latestFetchedBlockTimestamp = self.chainWorker->ChainWorker.getLatestFetchedBlockTimestamp
    NoItem(latestFetchedBlockTimestamp, self.chainConfig.chainId)
  | Some(item) => Item(item)
  }
}

let addNewRangeQueriedCallback = (self: t) => {
  ChainWorker.addNewRangeQueriedCallback(self.chainWorker)
}
