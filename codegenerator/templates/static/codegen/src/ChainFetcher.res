type eventType = EventFetching.eventBatchQueueItem

type t<'workerType> = {
  logger: Pino.t,
  fetchedEventQueue: ChainEventQueue.t,
  chainConfig: Config.chainConfig,
  chainWorker: ('workerType, module(ChainWorker.ChainWorker with type t = 'workerType)),
}

//CONSTRUCTION
let make = (
  ~chainConfig: Config.chainConfig,
  ~maxQueueSize,
  ~chainWorker: ('chainWorker, module(ChainWorker.ChainWorker with type t = 'chainWorker)),
): t<'chainWorker> => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chainId})

  {
    fetchedEventQueue: ChainEventQueue.make(~maxQueueSize),
    logger,
    chainConfig,
    chainWorker,
  }
}

//Public methods
let startFetchingEvents = async (self: t<'chainWorker>) => {
  switch await self.chainWorker->ChainWorker.startFethcingEventsOnWorker(
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

//Pops the front item on the fetchedEventQueue and awaits an item if there is none
let popAndAwaitQueueItem = async (self: t<'chainWorker>): eventType => {
  await self.fetchedEventQueue->ChainEventQueue.popSingleAndAwaitItem
}

//Pops the front item on the fetchedEventQueue
let popQueueItem = (self: t<'chainWorker>): option<eventType> => {
  self.fetchedEventQueue->ChainEventQueue.popSingle
}

//Registers the new contract
//fetches all the unfetched events
let addDynamicContractAndFetchMissingEvents = (
  self: t<'chainWorker>,
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

let peekFrontItemOfQueue = (self: t<'chainWorker>): eventQueuePeek => {
  let optFront = self.fetchedEventQueue->ChainEventQueue.peekFront

  switch optFront {
  | None =>
    let latestFetchedBlockTimestamp = self.chainWorker->ChainWorker.getLatestFetchedBlockTimestamp
    NoItem(latestFetchedBlockTimestamp, self.chainConfig.chainId)
  | Some(item) => Item(item)
  }
}

let addNewRangeQueriedCallback = (self: t<'chainWorker>) => {
  ChainWorker.addNewRangeQueriedCallback(self.chainWorker)
}
