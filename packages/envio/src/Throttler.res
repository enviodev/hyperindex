type t = {
  mutable lastRunTimeMillis: float,
  mutable isRunning: bool,
  mutable isAwaitingInterval: bool,
  mutable scheduled: option<unit => promise<unit>>,
  intervalMillis: float,
  logger: Logger.t,
  clock: Clock.t,
}

let make = (~intervalMillis: int, ~logger, ~clock=Clock.real) => {
  // A clock reads from its own origin, which the first run must not wait on.
  lastRunTimeMillis: -.(intervalMillis->Int.toFloat),
  isRunning: false,
  isAwaitingInterval: false,
  scheduled: None,
  intervalMillis: intervalMillis->Int.toFloat,
  logger,
  clock,
}

let rec startInternal = (throttler: t) => {
  switch throttler {
  | {scheduled: Some(fn), isRunning: false, isAwaitingInterval: false} =>
    let timeSinceLastRun = throttler.clock.now() -. throttler.lastRunTimeMillis

    //Only execute if we are passed the interval
    if timeSinceLastRun >= throttler.intervalMillis {
      throttler.isRunning = true
      throttler.scheduled = None
      throttler.lastRunTimeMillis = throttler.clock.now()

      // Defer off the schedule call so work queued before it (e.g. a batch) runs first.
      NodeJs.setImmediate(() => {
        (
          async () => {
            switch await fn() {
            | exception exn =>
              throttler.logger->Logger.errorWithExn("Scheduled action failed in throttler", exn)
            | _ => ()
            }
            throttler.isRunning = false

            throttler->startInternal
          }
        )()->ignore
      })
    } else {
      //Store isAwaitingInterval in state so that timers don't continuously get created
      throttler.isAwaitingInterval = true
      let _ = throttler.clock.setTimeout(
        ~label="throttled write",
        () => {
          throttler.isAwaitingInterval = false
          throttler->startInternal
        },
        Int.fromFloat(throttler.intervalMillis -. timeSinceLastRun),
      )
    }
  | _ => ()
  }
}

let schedule = (throttler: t, fn) => {
  throttler.scheduled = Some(fn)
  throttler->startInternal
}
