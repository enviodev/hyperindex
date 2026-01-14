exception LoaderTimeout(string)

type rec asyncMap<'key, 'value> = {
  // The number of loaded results to keep cached. (For block loading this should be our maximum block interval)
  _cacheSize: int,
  // The maximum number of results we can try to load simultaneously.
  _loaderPoolSize: int,
  // Base delay for exponential backoff (first retry delay)
  _baseRetryDelayMillis: int,
  // Maximum delay between retries (caps exponential growth)
  _maxRetryDelayMillis: int,
  // Maximum number of retry attempts before giving up on a key
  _maxRetries: int,
  // How long to wait before cancelling a load request
  _timeoutMillis: int,
  // The promises we return to callers. We satisfy them asynchronously.
  externalPromises: Utils.Map.t<'key, promise<'value>>,
  // The handled used to populate the external promises once we have loaded their data.
  resolvers: Utils.Map.t<'key, 'value => unit>,
  // The keys currently being loaded
  inProgress: Utils.Set.t<'key>,
  // Keys  for items that we have not started loading yet.
  loaderQueue: SDSL.Queue.t<'key>,
  // Keys for items that have been loaded already. Used to evict the oldest keys from cache.
  loadedKeys: SDSL.Queue.t<'key>,
  // Track retry attempts per key for exponential backoff
  retryAttempts: Utils.Map.t<'key, int>,
  // The function used to load the result.
  loaderFn: 'key => promise<'value>,
  // Callback on load error
  onError: option<(asyncMap<'key, 'value>, ~exn: exn) => unit>,
}

let make = (
  ~loaderFn,
  ~onError=?,
  ~cacheSize: int=10_000,
  ~loaderPoolSize: int=10,
  ~baseRetryDelayMillis=1_000,
  ~maxRetryDelayMillis=60_000,
  ~maxRetries=10,
  ~timeoutMillis=300_000,
) => // After 5 minutes (unclear what is best to do here - crash or just keep printing the error)
{
  _cacheSize: cacheSize,
  _loaderPoolSize: loaderPoolSize,
  _baseRetryDelayMillis: baseRetryDelayMillis,
  _maxRetryDelayMillis: maxRetryDelayMillis,
  _maxRetries: maxRetries,
  _timeoutMillis: timeoutMillis,
  externalPromises: Utils.Map.make(),
  resolvers: Utils.Map.make(),
  inProgress: Utils.Set.make(),
  loaderQueue: SDSL.Queue.make(),
  loadedKeys: SDSL.Queue.make(),
  retryAttempts: Utils.Map.make(),
  loaderFn,
  onError,
}

let deleteKey: (dict<'value>, string) => unit = (_obj, _k) => %raw(`delete _obj[_k]`)

// Calculate delay with exponential backoff and jitter
// Formula: min(baseDelay * 2^attempt, maxDelay) * (0.5 + random * 0.5)
// The jitter factor (0.5 to 1.0) helps prevent thundering herd problems
let calculateBackoffDelay = (~baseDelayMillis, ~maxDelayMillis, ~attempt) => {
  // Calculate exponential delay: base * 2^attempt
  let exponentialDelay =
    Belt.Int.toFloat(baseDelayMillis) *. Js.Math.pow_float(~base=2.0, ~exp=Belt.Int.toFloat(attempt))
  // Cap at max delay
  let cappedDelay = Pervasives.min(exponentialDelay, Belt.Int.toFloat(maxDelayMillis))
  // Add jitter: multiply by random factor between 0.5 and 1.0
  let jitterFactor = 0.5 +. Js.Math.random() *. 0.5
  Belt.Int.fromFloat(cappedDelay *. jitterFactor)
}

// If something takes longer than this to load, reject the promise and try again
let timeoutAfter = timeoutMillis =>
  Utils.delay(timeoutMillis)->Promise.then(() =>
    Promise.reject(
      LoaderTimeout(`Query took longer than ${Belt.Int.toString(timeoutMillis / 1000)} seconds`),
    )
  )

let rec loadNext = async (am: asyncMap<'key, 'value>, k: 'key) => {
  // Track that we are loading it now
  let _ = am.inProgress->Utils.Set.add(k)

  let tryLoadWithRetries = async () => {
    let rec attemptLoad = async (~attempt) => {
      switch await Promise.race([am.loaderFn(k), timeoutAfter(am._timeoutMillis)]) {
      | val => {
          // Success - clear retry attempts and resolve
          let _ = am.retryAttempts->Utils.Map.delete(k)
          // Resolve the external promise
          am.resolvers
          ->Utils.Map.get(k)
          ->Belt.Option.forEach(r => {
            let _ = am.resolvers->Utils.Map.delete(k)
            r(val)
          })
        }
      | exception err =>
        // Notify error callback
        switch am.onError {
        | None => ()
        | Some(onError) => onError(am, ~exn=err)
        }

        // Check if we should retry
        if attempt < am._maxRetries {
          // Calculate delay with exponential backoff and jitter
          let delayMillis = calculateBackoffDelay(
            ~baseDelayMillis=am._baseRetryDelayMillis,
            ~maxDelayMillis=am._maxRetryDelayMillis,
            ~attempt,
          )
          // Track retry attempt
          let _ = am.retryAttempts->Utils.Map.set(k, attempt + 1)
          await Utils.delay(delayMillis)
          await attemptLoad(~attempt=attempt + 1)
        } else {
          // Max retries exceeded - clear state and re-raise
          let _ = am.retryAttempts->Utils.Map.delete(k)
          raise(err)
        }
      }
    }

    // Get current attempt count (0 if first try)
    let currentAttempt = am.retryAttempts->Utils.Map.get(k)->Belt.Option.getWithDefault(0)
    await attemptLoad(~attempt=currentAttempt)

    // Track that it is no longer in progress
    let _ = am.inProgress->Utils.Set.delete(k)

    // Track that we've loaded this key
    let loadedKeysNumber = am.loadedKeys->SDSL.Queue.push(k)

    // Delete the oldest key if the cache is overly full
    if loadedKeysNumber > am._cacheSize {
      switch am.loadedKeys->SDSL.Queue.pop {
      | None => ()
      | Some(old) =>
        let _ = am.externalPromises->Utils.Map.delete(old)
      }
    }

    // Load the next one, if there is anything in the queue
    switch am.loaderQueue->SDSL.Queue.pop {
    | None => ()
    | Some(next) => await loadNext(am, next)
    }
  }

  await tryLoadWithRetries()
}

let get = (am: asyncMap<'key, 'value>, k: 'key): promise<'value> => {
  switch am.externalPromises->Utils.Map.get(k) {
  | Some(x) => x
  | None => {
      // Create a promise to deliver the eventual value asynchronously
      let promise = Promise.make((resolve, _) => {
        // Expose the resolver externally, so that we can run it from the loader.
        let _ = am.resolvers->Utils.Map.set(k, resolve)
      })
      // Cache the promise to de-duplicate requests
      let _ = am.externalPromises->Utils.Map.set(k, promise)

      //   Do we have a free loader in the pool?
      if am.inProgress->Utils.Set.size < am._loaderPoolSize {
        loadNext(am, k)->ignore
      } else {
        // Queue the loader
        let _ = am.loaderQueue->SDSL.Queue.push(k)
      }

      promise
    }
  }
}
