type t = {
  mutable lastRunTimeMillis: float,
  mutable isRunning: bool,
  mutable isAwaitingInterval: bool,
  mutable scheduled: option<unit => promise<unit>>,
  intervalMillis: float,
  logger: Pino.t,
}

let make = (~intervalMillis: int, ~logger) => {
  lastRunTimeMillis: 0.,
  isRunning: false,
  isAwaitingInterval: false,
  scheduled: None,
  intervalMillis: intervalMillis->Belt.Int.toFloat,
  logger,
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

      switch await fn() {
      | exception exn =>
        throttler.logger->Pino.errorExn(
          Pino.createPinoMessageWithError("Scheduled action failed in throttler", exn),
        )
      | _ => ()
      }
      throttler.isRunning = false

      await throttler->startInternal
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
