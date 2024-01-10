let resolvePromiseAfterDelay = (~delayMilliseconds) =>
  Js.Promise2.make((~resolve, ~reject as _) => {
    let _interval = Js.Global.setTimeout(_ => {
      resolve(. ())
    }, delayMilliseconds)
  })

let rec retryAsyncWithExponentialBackOff = async (
  ~backOffMillis=1000,
  ~multiplicative=2,
  ~retryCount=0,
  ~maxRetries=5,
  ~logger: option<Pino.t>=None,
  f: unit => promise<'a>,
) => {
  try {
    await f()
  } catch {
  | Js.Exn.Error(exn) =>
    if retryCount < maxRetries {
      let nextRetryCount = retryCount + 1
      logger
      ->Belt.Option.map(l =>
        l->Logging.childErrorWithExn(
          exn->Obj.magic,
          `Failure. Retrying ${nextRetryCount->Belt.Int.toString}/${maxRetries->Belt.Int.toString} in ${backOffMillis->Belt.Int.toString}ms`,
        )
      )
      ->ignore
      await resolvePromiseAfterDelay(~delayMilliseconds=backOffMillis)

      await f->retryAsyncWithExponentialBackOff(
        ~backOffMillis=backOffMillis * multiplicative,
        ~multiplicative,
        ~retryCount=nextRetryCount,
        ~maxRetries,
      )
    } else {
      logger
      ->Belt.Option.map(l =>
        l->Logging.childErrorWithExn(
          exn->Obj.magic,
          `Failure. Max retries ${retryCount->Belt.Int.toString}/${maxRetries->Belt.Int.toString} exceeded`,
        )
      )
      ->ignore
      await Promise.reject(exn->Js.Exn.anyToExnInternal)
    }
  }
}
