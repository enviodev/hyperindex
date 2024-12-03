type t = {
  pushBacklogCallbacks: SDSL.Queue.t<unit => unit>,
  popBacklogCallbacks: SDSL.Queue.t<unit => unit>,
  maxQueueSize: int,
  queue: SDSL.Queue.t<Types.eventItem>,
}
let make: (~maxQueueSize: int) => t
let insertCallbackAwaitPromise: SDSL.Queue.t<unit => unit> => promise<unit>
let awaitQueueSpaceAndPushItem: (t, Types.eventItem) => promise<unit>
let popSingleAndAwaitItem: t => promise<Types.eventItem>
let popSingle: t => option<Types.eventItem>
let peekFront: t => option<Types.eventItem>
let pushItem: (t, Types.eventItem) => bool
