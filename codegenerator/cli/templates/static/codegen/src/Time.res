let resolvePromiseAfterDelay = (~delayMilliseconds) => Utils.delay(delayMilliseconds)

let rec retryAsyncWithExponentialBackOff = async (
  ~backOffMillis=100,
  ~multiplicative=4,
  ~retryCount=0,
  ~maxRetries=5,
  ~logger: Pino.t,
  f: unit => promise<'a>,
) => {
  try {
    await f()
  } catch {
  | exn =>
    if retryCount < maxRetries {
      let nextRetryCount = retryCount + 1
      logger->Logging.childWarn({
        "message": `Retrying query ${nextRetryCount->Belt.Int.toString}/${maxRetries->Belt.Int.toString} in ${backOffMillis->Belt.Int.toString}ms - waiting for correct result.`,
        "error": exn,
      })
      await resolvePromiseAfterDelay(~delayMilliseconds=backOffMillis)

      await f->retryAsyncWithExponentialBackOff(
        ~backOffMillis=backOffMillis * multiplicative,
        ~multiplicative,
        ~retryCount=nextRetryCount,
        ~maxRetries,
        ~logger,
      )
    } else {
      exn
      ->ErrorHandling.make(
        ~logger,
        ~msg=`Failure. Max retries ${retryCount->Belt.Int.toString}/${maxRetries->Belt.Int.toString} exceeded`,
      )
      ->ErrorHandling.log
      await Promise.reject(exn->Js.Exn.anyToExnInternal)
    }
  }
}
