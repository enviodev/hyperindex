type t = {
  logger: Pino.t,
  fetchedEventQueue: ChainEventQueue.t,
  chainConfig: Config.chainConfig,
  chainWorker: ref<ChainWorker.chainWorker>,
}
let make: (
  ~chainConfig: Config.chainConfig,
  ~maxQueueSize: int,
  ~shouldSyncFromRawEvents: bool,
) => t
let startFetchingEvents: t => promise<result<unit, exn>>
/**
Pops the front item on the fetchedEventQueue and awaits an item if there is none.
*/
let popAndAwaitQueueItem: t => promise<Types.eventBatchQueueItem>
let popQueueItem: t => option<Types.eventBatchQueueItem>
let addDynamicContractAndFetchMissingEvents: (
  t,
  ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ~fromBlock: int,
  ~fromLogIndex: int,
) => promise<array<Types.eventBatchQueueItem>>
type latestFetchedBlockTimestamp = int
type eventQueuePeek =
  | NoItem(latestFetchedBlockTimestamp, Types.chainId)
  | Item(Types.eventBatchQueueItem)
let peekFrontItemOfQueue: t => eventQueuePeek
let addNewRangeQueriedCallback: t => promise<unit>
