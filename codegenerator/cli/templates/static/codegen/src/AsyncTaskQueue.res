/**
Used for managing sequential execution of async tasks

Currently only implemented with concurrency level of 1
*/
type t = {
  queue: SDSL.Queue.t<unit => promise<unit>>,
  mutable isProcessing: bool,
}

let make = (): t => {queue: SDSL.Queue.make(), isProcessing: false}

let processQueue = async (~logger=?, self) => {
  if !self.isProcessing {
    self.isProcessing = true
    while self.isProcessing {
      switch self.queue->SDSL.Queue.pop {
      | Some(fn) => await fn->Time.retryAsyncWithExponentialBackOff(~logger)
      | None => self.isProcessing = false
      }
    }
  }
}

let add = (~logger=?, self, fn) => {
  Promise.make((res, _) => {
    let wrappedFn = () => fn()->Promise.thenResolve(() => res(. ()))
    let _size = self.queue->SDSL.Queue.push(wrappedFn)
    let _ = self->processQueue(~logger?)
  })
}
