type pendingNextQuery = HypersyncPendingNextQuery(HyperSyncWorker.blockRangeFetchArgs) | Rpc
type t = {
  logger: Pino.t,
  fetchedEventQueue: ChainEventQueue.t,
  chainConfig: Config.chainConfig,
  chainWorker: ref<ChainWorker.chainWorker>,
  pendingNextQuery: option<pendingNextQuery>,
  pendingDynamicContractRegistrations: Belt.Set.String.t,
  currentBlockHeight: int,
  mutable lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.t,
}
let make: (
  ~chainConfig: Config.chainConfig,
  ~lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.t,
  ~maxQueueSize: int,
  ~shouldSyncFromRawEvents: bool,
) => t
let startFetchingEvents: (
  t,
  ~checkHasReorgOccurred: (
    t,
    ReorgDetection.lastBlockScannedData,
    ~parentHash: option<string>,
    ~currentHeight: int,
  ) => unit,
) => promise<result<unit, exn>>
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
  NoItem(latestFetchedBlockTimestamp, ChainMap.Chain.t) | Item(Types.eventBatchQueueItem)
let peekFrontItemOfQueue: t => eventQueuePeek
let addNewRangeQueriedCallback: t => promise<unit>
