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

let t = (logger, exn, message) =>
  logger->Pino.errorExn(message->Pino.createPinoMessageWithError(exn))

%%private(
  let rec startInternal = async (debouncer: t) => {
    switch debouncer {
    | {scheduled: Some(fn), isRunning: false, isAwaitingInterval: false} =>
      let timeSinceLastRun = Js.Date.now() -. debouncer.lastRunTimeMillis

      //Only execute if we are passed the interval
      if timeSinceLastRun >= debouncer.intervalMillis {
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

        await debouncer->startInternal
      } else {
        //Store isAwaitingInterval in state so that timers don't continuously get created
        debouncer.isAwaitingInterval = true
        let timeOutInterval = debouncer.intervalMillis -. timeSinceLastRun
        await Js.Promise2.make((~resolve, ~reject as _) => {
          let _ = Js.Global.setTimeout(() => {
            debouncer.isAwaitingInterval = false
            resolve()
          }, Belt.Int.fromFloat(timeOutInterval))
        })

        await debouncer->startInternal
      }
    | _ => ()
    }
  }
)

let schedule = (debouncer: t, fn) => {
  debouncer.scheduled = Some(fn)
  debouncer->startInternal->ignore
}
