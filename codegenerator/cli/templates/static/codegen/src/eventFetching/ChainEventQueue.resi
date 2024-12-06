type t = {
  pushBacklogCallbacks: SDSL.Queue.t<unit => unit>,
  popBacklogCallbacks: SDSL.Queue.t<unit => unit>,
  maxQueueSize: int,
  queue: SDSL.Queue.t<Internal.eventItem>,
}
let make: (~maxQueueSize: int) => t
let insertCallbackAwaitPromise: SDSL.Queue.t<unit => unit> => promise<unit>
let awaitQueueSpaceAndPushItem: (t, Internal.eventItem) => promise<unit>
let popSingleAndAwaitItem: t => promise<Internal.eventItem>
let popSingle: t => option<Internal.eventItem>
let peekFront: t => option<Internal.eventItem>
let pushItem: (t, Internal.eventItem) => bool
