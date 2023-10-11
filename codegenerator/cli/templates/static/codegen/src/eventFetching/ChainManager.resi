type t = {
  chainFetchers: Js.Dict.t<ChainFetcher.t>,
  arbitraryEventPriorityQueue: SDSL.PriorityQueue.t<Types.eventBatchQueueItem>,
}
type nextEventErr = NoItemsInArray

let make: (~configs: Config.chainConfigs, ~maxQueueSize: int, ~shouldSyncFromRawEvents: bool) => t
let startFetchers: t => unit
let getChainFetcher: (t, ~chainId: int) => ChainFetcher.t
let createBatch: (
  t,
  ~minBatchSize: int,
  ~maxBatchSize: int,
) => promise<array<Types.eventBatchQueueItem>>
let addItemToArbitraryEvents: (t, Types.eventBatchQueueItem) => unit

type blockGroupedBatchItems = array<Types.eventBatchQueueItem>
let popBlockBatchItems: t => option<blockGroupedBatchItems>
let popBlockBatchAndAwaitItems: t => promise<option<blockGroupedBatchItems>>

module ExposedForTesting_Hidden: {
  let priorityQueueComparitor: (Types.eventBatchQueueItem, Types.eventBatchQueueItem) => int
  let getComparitorFromItem: Types.eventBatchQueueItem => (int, int, int, int)
  let createDetermineNextEventFunction: (
    ~isUnorderedHeadMode: bool,
    array<ChainFetcher.eventQueuePeek>,
  ) => result<ChainFetcher.eventQueuePeek, nextEventErr>
}
