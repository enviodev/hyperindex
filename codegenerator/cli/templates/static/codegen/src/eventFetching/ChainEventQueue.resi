type t = {
  pushBacklogCallbacks: SDSL.Queue.t<unit => unit>,
  popBacklogCallbacks: SDSL.Queue.t<unit => unit>,
  maxQueueSize: int,
  queue: SDSL.Queue.t<Types.eventBatchQueueItem>,
}
let make: (~maxQueueSize: int) => t
let insertCallbackAwaitPromise: SDSL.Queue.t<unit => unit> => promise<unit>
let awaitQueueSpaceAndPushItem: (t, Types.eventBatchQueueItem) => promise<unit>
let popSingleAndAwaitItem: t => promise<Types.eventBatchQueueItem>
let popSingle: t => option<Types.eventBatchQueueItem>
let peekFront: t => option<Types.eventBatchQueueItem>
let pushItem: (t, Types.eventBatchQueueItem) => bool
