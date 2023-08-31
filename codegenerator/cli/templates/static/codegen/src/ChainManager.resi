// TODO: move to `eventFetching`

type t = {
  chainFetchers: Js.Dict.t<ChainFetcher.t>,
  arbitraryEventPriorityQueue: SDSL.PriorityQueue.t<Types.eventBatchQueueItem>,
}
type nextEventErr = NoItemsInArray

let make: (
  ~configs: Config.chainConfigs,
  ~maxQueueSize: int,
  ~shouldSyncFromRawEvents: bool,
) => t
let startFetchers: t => unit
let getChainFetcher: (t, ~chainId: int) => ChainFetcher.t
let createBatch: (
  t,
  ~minBatchSize: int,
  ~maxBatchSize: int,
) => promise<array<Types.eventBatchQueueItem>>
let addItemToArbitraryEvents: (t, Types.eventBatchQueueItem) => unit
