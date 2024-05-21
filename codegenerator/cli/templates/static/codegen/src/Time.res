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
  | exn =>
    if retryCount < maxRetries {
      let nextRetryCount = retryCount + 1
      exn
      ->ErrorHandling.make(
        ~logger?,
        ~msg=`Failure. Retrying ${nextRetryCount->Belt.Int.toString}/${maxRetries->Belt.Int.toString} in ${backOffMillis->Belt.Int.toString}ms`,
      )
      ->ErrorHandling.log
      await resolvePromiseAfterDelay(~delayMilliseconds=backOffMillis)

      await f->retryAsyncWithExponentialBackOff(
        ~backOffMillis=backOffMillis * multiplicative,
        ~multiplicative,
        ~retryCount=nextRetryCount,
        ~maxRetries,
      )
    } else {
      exn
      ->ErrorHandling.make(
        ~logger?,
        ~msg=`Failure. Max retries ${retryCount->Belt.Int.toString}/${maxRetries->Belt.Int.toString} exceeded`,
      )
      ->ErrorHandling.log
      await Promise.reject(exn->Js.Exn.anyToExnInternal)
    }
  }
}
