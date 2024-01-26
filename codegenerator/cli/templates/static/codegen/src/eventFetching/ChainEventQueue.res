type t = {
  pushBacklogCallbacks: SDSL.Queue.t<unit => unit>,
  popBacklogCallbacks: SDSL.Queue.t<unit => unit>,
  maxQueueSize: int,
  queue: SDSL.Queue.t<Types.eventBatchQueueItem>,
}

let make = (~maxQueueSize): t => {
  pushBacklogCallbacks: SDSL.Queue.make(),
  popBacklogCallbacks: SDSL.Queue.make(),
  maxQueueSize,
  queue: SDSL.Queue.make(),
}

let insertCallbackAwaitPromise = (queue: SDSL.Queue.t<unit => unit>): promise<unit> => {
  Promise.make((resolve, _reject) => {
    queue->SDSL.Queue.push(() => resolve(. ()))->ignore
  })
}

let handlePopBackLogCallbacks = (self: t, ~numberOfItems: int) => {
  //Optimize iteration by only iterating the minimum between number
  //of awaiting pop callbacks and how maany values were added that can
  //be popped
  for _n in 1 to Js.Math.min_int(numberOfItems, self.popBacklogCallbacks->SDSL.Queue.size) {
    //If there are any items awaiting pop due to empty queue
    //Signal that there is now items on the queue
    self.popBacklogCallbacks->SDSL.Queue.pop->Belt.Option.map(popCallback => popCallback())->ignore
  }
}

/**
Checks to see if queue is at or over max capacity
*/
let isQueueAtMax = self => self.queue->SDSL.Queue.size >= self.maxQueueSize

/**
Pushes Item Regardless of max size and returns true if queue is over max size
*/
let pushItem = (self: t, item: Types.eventBatchQueueItem) => {
  self.queue->SDSL.Queue.push(item)->ignore
  self->isQueueAtMax
}

let awaitQueueSpaceAndPushItem = async (self: t, item: Types.eventBatchQueueItem) => {
  //Check if the queue is already full and wait for space before
  //pushing next batch
  let currentQueueSize = self.queue->SDSL.Queue.size
  if currentQueueSize >= self.maxQueueSize {
    await self.pushBacklogCallbacks->insertCallbackAwaitPromise
  }

  self.queue->SDSL.Queue.push(item)->ignore

  self->handlePopBackLogCallbacks(~numberOfItems=1)
}

let handlePushBackLogCallbacks = (self: t) => {
  if self.queue->SDSL.Queue.size < self.maxQueueSize {
    //If there are any items awaiting push due to hitting max queue size
    //And popping has brought the queue under its max threshold
    //Signal that there is now space in the queue for another batch
    self.pushBacklogCallbacks
    ->SDSL.Queue.pop
    ->Belt.Option.map(pushCallback => pushCallback())
    ->ignore
  }
}

let popSingleAndAwaitItem = async (self: t): Types.eventBatchQueueItem => {
  let optItem = self.queue->SDSL.Queue.pop

  let item = switch optItem {
  | Some(item) => item
  | None =>
    //Wait for a callback to say that an item has been pushed to the queue
    await self.popBacklogCallbacks->insertCallbackAwaitPromise
    //Get the item unsafely from the queue since the callback will confirm that there
    //an item in the queue
    self.queue->SDSL.Queue.pop->Belt.Option.getUnsafe
  }

  self->handlePushBackLogCallbacks

  //return the item
  item
}

let popSingle = (self: t): option<Types.eventBatchQueueItem> => {
  let optItem = self.queue->SDSL.Queue.pop

  self->handlePushBackLogCallbacks

  optItem
}

let peekFront = (self: t): option<Types.eventBatchQueueItem> => {
  self.queue->SDSL.Queue.front
}
