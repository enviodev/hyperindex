type t = {
  logger: Pino.t,
  fetchedEventQueue: ChainEventQueue.t,
  chainConfig: Config.chainConfig,
  chainWorker: ChainWorker.chainWorker,
}
let make: (
  ~chainConfig: Config.chainConfig,
  ~maxQueueSize: int,
  ~chainWorkerTypeSelected: Env.workerTypeSelected,
) => t
let startFetchingEvents: t => promise<result<unit, exn>>
/**
Pops the front item on the fetchedEventQueue and awaits an item if there is none.
*/
let popAndAwaitQueueItem: t => promise<EventFetching.eventBatchQueueItem>
let popQueueItem: t => option<EventFetching.eventBatchQueueItem>
let addDynamicContractAndFetchMissingEvents: (
  t,
  ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ~fromBlock: int,
  ~fromLogIndex: int,
) => promise<array<EventFetching.eventBatchQueueItem>>
type latestFetchedBlockTimestamp = int
type eventQueuePeek =
  | NoItem(latestFetchedBlockTimestamp, Types.chainId)
  | Item(EventFetching.eventBatchQueueItem)
let peekFrontItemOfQueue: t => eventQueuePeek
let addNewRangeQueriedCallback: t => promise<unit>
