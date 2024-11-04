type t = {
  mutable lastRunTimeMillis: float,
  mutable isRunning: bool,
  mutable scheduled: option<unit => promise<unit>>,
  delayMillis: float,
  //TODO: move Logger into envio lib and store logger in Debouncer instead
  logExn: (exn, string) => unit,
}

let make = (~delayMillis: int, ~logExn) => {
  lastRunTimeMillis: 0.,
  isRunning: false,
  scheduled: None,
  delayMillis: delayMillis->Belt.Int.toFloat,
  logExn,
}

%%private(
  let rec startInternal = async (debouncer: t) => {
    switch debouncer {
    | {scheduled: Some(fn), isRunning: false} =>
      debouncer.isRunning = true
      debouncer.scheduled = None
      debouncer.lastRunTimeMillis = Js.Date.now()

      switch await fn() {
      | exception exn =>
        //TODO: logging should happen like this after it's moved
        // debouncer.logger->Logging.childErrorWithExn(exn, "Scheduled action failed in debouncer")
        debouncer.logExn(exn, "Scheduled action failed in debouncer")
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
    if timeSinceLastRun >= debouncer.delayMillis {
      debouncer->startInternal->ignore
    } else {
      let _ = Js.Global.setTimeout(() => {
        debouncer->startInternal->ignore
      }, Belt.Int.fromFloat(debouncer.delayMillis -. debouncer.lastRunTimeMillis))
    }
  }
}
