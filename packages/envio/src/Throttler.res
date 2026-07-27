type t = {
  mutable lastRunTimeMillis: float,
  mutable isRunning: bool,
  mutable isAwaitingInterval: bool,
  mutable scheduled: option<unit => promise<unit>>,
  intervalMillis: float,
  logger: Pino.t,
  params: Internal.logParams,
}

let make = (~intervalMillis: int, ~logger, ~params: Internal.logParams) => {
  lastRunTimeMillis: 0.,
  isRunning: false,
  isAwaitingInterval: false,
  scheduled: None,
  intervalMillis: intervalMillis->Int.toFloat,
  logger,
  params,
}

let rec startInternal = (throttler: t) => {
  switch throttler {
  | {scheduled: Some(fn), isRunning: false, isAwaitingInterval: false} =>
    let timeSinceLastRun = Date.now() -. throttler.lastRunTimeMillis

    //Only execute if we are passed the interval
    if timeSinceLastRun >= throttler.intervalMillis {
      throttler.isRunning = true
      throttler.scheduled = None
      throttler.lastRunTimeMillis = Date.now()

      // Defer off the schedule call so work queued before it (e.g. a batch) runs first.
      NodeJs.setImmediate(() => {
        (
          async () => {
            switch await fn() {
            | exception exn =>
              throttler.logger->Logging.error(
                throttler.params->Logging.withParams({
                  "msg": "Scheduled action failed in throttler",
                  "err": exn->Utils.prettifyExn,
                }),
              )
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
      let _ = setTimeout(() => {
        throttler.isAwaitingInterval = false
        throttler->startInternal
      }, Int.fromFloat(throttler.intervalMillis -. timeSinceLastRun))
    }
  | _ => ()
  }
}

let schedule = (throttler: t, fn) => {
  throttler.scheduled = Some(fn)
  throttler->startInternal
}
