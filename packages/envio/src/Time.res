let resolvePromiseAfterDelay = (~delayMilliseconds) => Utils.delay(delayMilliseconds)

let rec retryAsyncWithExponentialBackOff = async (
  ~backOffMillis=100,
  ~multiplicative=4,
  ~retryCount=0,
  ~maxRetries=5,
  ~logger: Logger.t,
  f: unit => promise<'a>,
) => {
  try {
    await f()
  } catch {
  | exn =>
    if retryCount < maxRetries {
      let nextRetryCount = retryCount + 1
      logger->Logger.logAt(
        retryCount === 0 ? #trace : #warn,
        `Retrying query ${nextRetryCount->Int.toString}/${maxRetries->Int.toString} in ${backOffMillis->Int.toString}ms - waiting for correct result.`,
        ~params={"err": exn->Utils.prettifyExn},
      )
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
        ~msg=`Failure. Max retries ${retryCount->Int.toString}/${maxRetries->Int.toString} exceeded`,
      )
      ->ErrorHandling.log
      await Promise.reject(exn->JsExn.anyToExnInternal)
    }
  }
}
