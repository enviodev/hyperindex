type t = {
  mutable lastRunTimeMillis: float,
  mutable isRunning: bool,
  mutable scheduled: option<unit => promise<unit>>,
  intervalMillis: float,
  logger: Pino.t,
}

let make = (~intervalMillis: int, ~logger) => {
  lastRunTimeMillis: 0.,
  isRunning: false,
  scheduled: None,
  intervalMillis: intervalMillis->Belt.Int.toFloat,
  logger,
}

let t = (logger, exn, message) =>
  logger->Pino.errorExn(message->Pino.createPinoMessageWithError(exn))

%%private(
  let rec startInternal = async (debouncer: t) => {
    switch debouncer {
    | {scheduled: Some(fn), isRunning: false} =>
      debouncer.isRunning = true
      debouncer.scheduled = None
      debouncer.lastRunTimeMillis = Js.Date.now()

      switch await fn() {
      | exception exn =>
        debouncer.logger->Pino.errorExn(
          Pino.createPinoMessageWithError("Scheduled action failed in debouncer", exn),
        )
      | _ => ()
      }
      debouncer.isRunning = false
      await startInternal(debouncer)
    | _ => ()
    }
  }
)

let schedule = (debouncer: t, fn) => {
  debouncer.scheduled = Some(fn)
  if !debouncer.isRunning {
    let timeSinceLastRun = Js.Date.now() -. debouncer.lastRunTimeMillis
    if timeSinceLastRun >= debouncer.intervalMillis {
      debouncer->startInternal->ignore
    } else {
      let _ = Js.Global.setTimeout(() => {
        debouncer->startInternal->ignore
      }, Belt.Int.fromFloat(debouncer.intervalMillis -. timeSinceLastRun))
    }
  }
}
