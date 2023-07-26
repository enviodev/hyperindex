
type t<'a> = {
  pushBacklogCallbacks: array<unit => unit>,
  popBacklogCallbacks: array<unit => unit>,
  maxQueueLength: int,
  maxBatchChunkSize: int,
  queue: SDSL.Deque.t<array<'a>>,
}

let default_max_queue_length = 10
let default_max_queue_chunk_size = 1000

let make = (~maxQueueLength=?, ~maxBatchChunkSize=?, ()): t<'a> => {
  pushBacklogCallbacks: [],
  popBacklogCallbacks: [],
  maxQueueLength: maxQueueLength->Belt.Option.getWithDefault(default_max_queue_length),
  maxBatchChunkSize: maxBatchChunkSize->Belt.Option.getWithDefault(default_max_queue_chunk_size),
  queue: SDSL.Deque.make(),
}

let push = async (self: t<'a>, batch: array<'a>) => {
  while batch->Js.Array2.length > 0 {
    let nextChunk = batch->Js.Array2.spliceInPlace(~pos=0, ~remove=self.maxBatchChunkSize, ~add=[])
    let currentQueueSize = self.queue->SDSL.Deque.size

    //If the queue size reaches its max, add wait for a callback to say that there is
    //space on the queue and you can continue chunking/adding
    if currentQueueSize >= self.maxQueueLength {
      await Promise.make((resolve, _reject) => {
        self.pushBacklogCallbacks
        ->Js.Array2.push(() => {
          resolve(. ())
        })
        ->ignore
      })
    }
    self.queue->SDSL.Deque.pushBack(nextChunk)->ignore
    //If there are any items awaiting pop due to empty queue
    //Signal that there is now a batch on the queue
    self.popBacklogCallbacks->Js.Array2.pop->Belt.Option.map(popCallback => popCallback())->ignore
  }
}

let pop = async (self: t<'a>): array<'a> => {
  let optBatch = self.queue->SDSL.Deque.popFront

  let batch = switch optBatch {
  | Some(batch) => batch
  | None =>
    //Wait for a callback to say that a batch has been pushed to the queue
    await Promise.make((resolve, _reject) => {
      self.popBacklogCallbacks->Js.Array2.push(() => resolve(. ()))->ignore
    })
    //Get the item unsafely from the queue since the callback will confirm that there
    //a batch in the queue
    self.queue->SDSL.Deque.popFront->Belt.Option.getUnsafe
  }

  //If there are any items awaiting push due to hitting max queue size
  //Signal that there is now space in the queue for another batch
  self.pushBacklogCallbacks->Js.Array2.pop->Belt.Option.map(pushCallback => pushCallback())->ignore

  //return the batch
  batch
}
