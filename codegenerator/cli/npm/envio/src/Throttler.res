type t = {
  mutable lastRunTimeMillis: float,
  mutable isRunning: bool,
  mutable isAwaitingInterval: bool,
  mutable scheduled: option<unit => promise<unit>>,
  intervalMillis: float,
  logger: Pino.t,
  executionTimeoutMillis: float,
}

// Default execution timeout of 30 seconds
let defaultExecutionTimeoutMillis = 30000.

let make = (~intervalMillis: int, ~logger, ~executionTimeoutMillis=?) => {
  lastRunTimeMillis: 0.,
  isRunning: false,
  isAwaitingInterval: false,
  scheduled: None,
  intervalMillis: intervalMillis->Belt.Int.toFloat,
  logger,
  executionTimeoutMillis: executionTimeoutMillis
  ->Belt.Option.map(Belt.Int.toFloat)
  ->Belt.Option.getWithDefault(defaultExecutionTimeoutMillis),
}

exception ExecutionTimeout

// Execute a function with a timeout. If the function doesn't complete within
// the timeout, the promise rejects with ExecutionTimeout.
// Note: This doesn't cancel the underlying operation, but allows the Throttler
// to continue processing instead of being stuck forever.
let withTimeout = (fn: unit => promise<unit>, ~timeoutMillis: float) => {
  Promise.race([
    fn(),
    Promise.make((_, reject) => {
      let _ = Js.Global.setTimeout(() => {
        reject(ExecutionTimeout)
      }, timeoutMillis->Belt.Float.toInt)
    }),
  ])
}

let rec startInternal = async (throttler: t) => {
  switch throttler {
  | {scheduled: Some(fn), isRunning: false, isAwaitingInterval: false} =>
    let timeSinceLastRun = Js.Date.now() -. throttler.lastRunTimeMillis

    //Only execute if we are passed the interval
    if timeSinceLastRun >= throttler.intervalMillis {
      throttler.isRunning = true
      throttler.scheduled = None
      throttler.lastRunTimeMillis = Js.Date.now()

      switch await withTimeout(fn, ~timeoutMillis=throttler.executionTimeoutMillis) {
      | exception ExecutionTimeout =>
        throttler.logger.error(
          Pino.createPinoMessage(
            "Scheduled action timed out in throttler - the underlying operation may still be running",
          ),
        )
      | exception exn =>
        throttler.logger->Pino.errorExn(
          Pino.createPinoMessageWithError(
            "Scheduled action failed in throttler",
            exn->Utils.prettifyExn,
          ),
        )
      | _ => ()
      }
      throttler.isRunning = false

      // Wrap recursive call in try-catch to ensure Throttler continues
      // even if there's an unexpected error
      switch await throttler->startInternal {
      | exception exn =>
        throttler.logger->Pino.errorExn(
          Pino.createPinoMessageWithError(
            "Unexpected error in throttler startInternal",
            exn->Utils.prettifyExn,
          ),
        )
      | _ => ()
      }
    } else {
      //Store isAwaitingInterval in state so that timers don't continuously get created
      throttler.isAwaitingInterval = true
      let _ = Js.Global.setTimeout(() => {
        throttler.isAwaitingInterval = false
        throttler->startInternal->ignore
      }, Belt.Int.fromFloat(throttler.intervalMillis -. timeSinceLastRun))
    }
  | _ => ()
  }
}

let schedule = (throttler: t, fn) => {
  throttler.scheduled = Some(fn)
  throttler->startInternal->ignore
}
