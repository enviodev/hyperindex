// TODO: move to `eventFetching`
type t = {
  pushBacklogCallbacks: SDSL.Queue.t<unit => unit>,
  popBacklogCallbacks: SDSL.Queue.t<unit => unit>,
  maxQueueSize: int,
  queue: SDSL.Queue.t<EventFetching.eventBatchQueueItem>,
}
let make: (~maxQueueSize: int) => t
let insertCallbackAwaitPromise: SDSL.Queue.t<unit => unit> => promise<unit>
let awaitQueueSpaceAndPushItem: (t, EventFetching.eventBatchQueueItem) => promise<unit>
let popSingleAndAwaitItem: t => promise<EventFetching.eventBatchQueueItem>
let popSingle: t => option<EventFetching.eventBatchQueueItem>
let peekFront: t => option<EventFetching.eventBatchQueueItem>
