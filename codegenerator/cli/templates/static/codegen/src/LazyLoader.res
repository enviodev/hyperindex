exception LoaderTimeout(string)

type blockNumber = int

let s = Belt.MutableSet.Int.make()

// NOTE: any additional metadata that would be useful for debugging issues or displaying to users can be added here
type asyncMapMetadata = {suggestedFix: string, asyncTaskName: string, caller: string}
type asyncMap<'a> = {
  // The number of loaded results to keep cached. (For block loading this should be our maximum block interval)
  _cacheSize: int,
  // The maximum number of results we can try to load simultaneously.
  _loaderPoolSize: int,
  // How long to wait before retrying failures
  // TODO: Add randomized exponential back-off
  _retryDelayMillis: int,
  // How long to wait before cancelling a load request
  _timeoutMillis: int,
  // The promises we return to callers. We satisfy them asynchronously.
  externalPromises: Js.Dict.t<promise<'a>>,
  // The handled used to populate the external promises once we have loaded their data.
  resolvers: Js.Dict.t<(. 'a) => unit>,
  // The keys currently being loaded
  inProgress: Belt.MutableSet.Int.t,
  // Keys  for items that we have not started loading yet.
  loaderQueue: SDSL.PriorityQueue.t<int>,
  // Keys for items that have been loaded already. Used to evict the oldest keys from cache.
  loadedKeys: SDSL.PriorityQueue.t<int>,
  // The function used to load the result.
  loaderFn: int => promise<'a>,
  // Details for debugging, tracing, and loging issues
  metadata: asyncMapMetadata,
}

let make = (
  ~loaderFn,
  ~cacheSize: int=10_000,
  ~loaderPoolSize: int=10,
  ~retryDelayMillis=5_000,
  ~timeoutMillis=300_000, // After 5 minutes (unclear what is best to do here - crash or just keep printing the error)
  ~metadata,
  (),
) => {
  _cacheSize: cacheSize,
  _loaderPoolSize: loaderPoolSize,
  _retryDelayMillis: retryDelayMillis,
  _timeoutMillis: timeoutMillis,
  externalPromises: Js.Dict.empty(),
  resolvers: Js.Dict.empty(),
  inProgress: Belt.MutableSet.Int.make(),
  loaderQueue: SDSL.PriorityQueue.makeAsc(),
  loadedKeys: SDSL.PriorityQueue.makeAsc(),
  loaderFn,
  metadata,
}

let deleteKey: (Js.Dict.t<'a>, string) => unit = (_obj, _k) => %raw(`delete _obj[_k]`)

// If something takes longer than this to load, reject the promise and try again
let timeoutAfter = timeoutMillis =>
  Time.resolvePromiseAfterDelay(~delayMilliseconds=timeoutMillis)->Promise.then(() =>
    Promise.reject(
      LoaderTimeout(`Query took longer than ${Belt.Int.toString(timeoutMillis / 1000)} seconds`),
    )
  )

let rec loadNext = async (am: asyncMap<'a>, k: int) => {
  let key = k->Belt.Int.toString
  // Track that we are loading it now
  am.inProgress->Belt.MutableSet.Int.add(k)

  let awaitTaskPromiseAndLoadNextWithTimeout = async () => {
    let val = await Promise.race([am.loaderFn(k), timeoutAfter(am._timeoutMillis)])
    // Resolve the external promise
    am.resolvers->Js.Dict.get(key)->Belt.Option.map(r => r(. val))->ignore

    // Track that it is no longer in progress
    am.inProgress->Belt.MutableSet.Int.remove(k)

    // Track that we've loaded this key
    am.loadedKeys->SDSL.PriorityQueue.push(k)

    // Delete the oldest key if the cache is overly full
    if am.loadedKeys->SDSL.PriorityQueue.length > am._cacheSize {
      switch am.loadedKeys->SDSL.PriorityQueue.pop {
      | None => ()
      | Some(old) => am.externalPromises->deleteKey(old->Belt.Int.toString)
      }
    }

    // Load the next one, if there is anything in the queue
    switch am.loaderQueue->SDSL.PriorityQueue.pop {
    | None => ()
    | Some(next) => await loadNext(am, next)
    }
  }

  await (
    switch await awaitTaskPromiseAndLoadNextWithTimeout() {
    | _ => Promise.resolve()
    | exception err =>
      Logging.error({
        "err": err,
        "msg": `EE1100: Top level promise timeout reached. Please review other errors or warnings in the code. This function will retry in ${(am._retryDelayMillis / 1000)
            ->Belt.Int.toString} seconds. It is highly likely that your indexer isn't syncing on one or more chains currently. Also take a look at the "suggestedFix" in the metadata of this command`,
        "metadata": am.metadata,
      })
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=am._retryDelayMillis)
      awaitTaskPromiseAndLoadNextWithTimeout()
    }
  )
}

let get = (am: asyncMap<'a>, k: int): promise<'a> => {
  let key = k->Belt.Int.toString
  switch am.externalPromises->Js.Dict.get(key) {
  | Some(x) => x
  | None => {
      // Create a promise to deliver the eventual value asynchronously
      let promise = Promise.make((resolve, _) => {
        // Expose the resolver externally, so that we can run it from the loader.
        am.resolvers->Js.Dict.set(key, resolve)
      })
      // Cache the promise to de-duplicate requests
      am.externalPromises->Js.Dict.set(key, promise)

      //   Do we have a free loader in the pool?
      if am.inProgress->Belt.MutableSet.Int.size < am._loaderPoolSize {
        loadNext(am, k)->ignore
      } else {
        // Queue the loader
        am.loaderQueue->SDSL.PriorityQueue.push(k)
      }

      promise
    }
  }
}
