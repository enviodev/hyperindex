open Belt

// Ideally the ChainFetcher name suits this better
// But currently the ChainFetcher module is immutable
// and handles both processing and fetching.
// So this module is to encapsulate the fetching logic only
// with a mutable state for easier reasoning and testing.
type t = {
  sources: array<Source.t>,
  maxPartitionConcurrency: int,
  newBlockFallbackStallTimeout: int,
  stalledPollingInterval: int,
  mutable activeSource: Source.t,
  mutable waitingForNewBlockStateId: option<int>,
  // Should take into consideration partitions fetching for previous states (before rollback)
  mutable fetchingPartitionsCount: int,
}

let getActiveSource = sourceManager => sourceManager.activeSource

let make = (
  ~sources: array<Source.t>,
  ~maxPartitionConcurrency,
  ~newBlockFallbackStallTimeout=20_000,
  ~stalledPollingInterval=5_000,
) => {
  let initialActiveSource = switch sources->Js.Array2.find(source => source.sourceFor === Sync) {
  | None => Js.Exn.raiseError("Invalid configuration, no data-source for historical sync provided")
  | Some(source) => source
  }
  {
    maxPartitionConcurrency,
    sources,
    activeSource: initialActiveSource,
    waitingForNewBlockStateId: None,
    fetchingPartitionsCount: 0,
    newBlockFallbackStallTimeout,
    stalledPollingInterval,
  }
}

let fetchNext = async (
  sourceManager: t,
  ~fetchState: FetchState.t,
  ~currentBlockHeight,
  ~executeQuery,
  ~waitForNewBlock,
  ~onNewBlock,
  ~maxPerChainQueueSize,
  ~stateId,
) => {
  let {maxPartitionConcurrency, activeSource} = sourceManager

  switch fetchState->FetchState.getNextQuery(
    ~concurrencyLimit={
      maxPartitionConcurrency - sourceManager.fetchingPartitionsCount
    },
    ~maxQueueSize=maxPerChainQueueSize,
    ~currentBlockHeight,
    ~stateId,
  ) {
  | ReachedMaxConcurrency
  | NothingToQuery => ()
  | WaitingForNewBlock =>
    switch sourceManager.waitingForNewBlockStateId {
    | Some(waitingStateId) if waitingStateId >= stateId => ()
    | Some(_) // Case for the prev state before a rollback
    | None =>
      sourceManager.waitingForNewBlockStateId = Some(stateId)
      let currentBlockHeight = await waitForNewBlock(~currentBlockHeight)
      switch sourceManager.waitingForNewBlockStateId {
      | Some(waitingStateId) if waitingStateId === stateId => {
          sourceManager.waitingForNewBlockStateId = None
          onNewBlock(~currentBlockHeight)
        }
      | Some(_) // Don't reset it if we are waiting for another state
      | None => ()
      }
    }
  | Ready(queries) => {
      fetchState->FetchState.startFetchingQueries(~queries, ~stateId)
      sourceManager.fetchingPartitionsCount =
        sourceManager.fetchingPartitionsCount + queries->Array.length
      let _ =
        await queries
        ->Array.map(q => {
          let promise = q->executeQuery(~source=activeSource)
          let _ = promise->Promise.thenResolve(_ => {
            sourceManager.fetchingPartitionsCount = sourceManager.fetchingPartitionsCount - 1
          })
          promise
        })
        ->Promise.all
    }
  }
}

type status = Active | Stalled | Done

let getSourceNewHeight = async (
  ~source: Source.t,
  ~currentBlockHeight,
  ~stalledPollingInterval,
  ~status: ref<status>,
  ~logger,
) => {
  let newHeight = ref(0)
  //Amount the retry interval is multiplied between each retry
  let backOffMultiplicative = 2
  let initalRetryIntervalMillis = 1000
  //Interval after which to retry request (multiplied by backOffMultiplicative between each retry)
  let retryIntervalMillis = ref(initalRetryIntervalMillis)

  while newHeight.contents <= currentBlockHeight && status.contents !== Done {
    try {
      let height = await source.getHeightOrThrow()
      newHeight := height
      if height <= currentBlockHeight {
        // Slowdown polling when the chain isn't progressing
        let delayMilliseconds = if status.contents === Stalled {
          retryIntervalMillis := stalledPollingInterval // Reset possible backOff
          stalledPollingInterval
        } else {
          retryIntervalMillis := initalRetryIntervalMillis // Reset possible backOff
          source.pollingInterval
        }
        await Time.resolvePromiseAfterDelay(~delayMilliseconds)
      }
    } catch {
    | exn =>
      logger->Logging.childTrace({
        "msg": `Height retrieval from ${source.name} source failed. Retrying in ${retryIntervalMillis.contents->Int.toString}ms.`,
        "source": source.name,
        "error": exn->ErrorHandling.prettifyExn,
      })
      await Time.resolvePromiseAfterDelay(
        ~delayMilliseconds=Pervasives.max(
          retryIntervalMillis.contents * backOffMultiplicative,
          60_000,
        ),
      )
    }
  }
  newHeight.contents
}

// Polls for a block height greater than the given block number to ensure a new block is available for indexing.
let waitForNewBlock = async (sourceManager: t, ~currentBlockHeight) => {
  let {stalledPollingInterval, sources} = sourceManager

  let logger = Logging.createChild(
    ~params={
      "chainId": sourceManager.activeSource.chain->ChainMap.Chain.toChainId,
      "currentBlockHeight": currentBlockHeight,
    },
  )
  logger->Logging.childTrace("Initiating check for new blocks.")

  let syncSources = []
  let fallbackSources = []
  sources->Array.forEach(source => {
    if (
      source.sourceFor === Sync ||
        // Even if the active source is a fallback, still include
        // it to the list. So we don't wait for a timeout again
        // if all main sync sources are still not valid
        source === sourceManager.activeSource
    ) {
      syncSources->Array.push(source)
    } else {
      fallbackSources->Array.push(source)
    }
  })

  let status = ref(Active)

  let (source, newBlockHeight) = await Promise.race(
    syncSources
    ->Array.map(async source => {
      (
        source,
        await getSourceNewHeight(
          ~source,
          ~currentBlockHeight,
          ~status,
          ~logger,
          ~stalledPollingInterval,
        ),
      )
    })
    ->Array.concat([
      Utils.delay(sourceManager.newBlockFallbackStallTimeout)->Promise.then(() => {
        if status.contents !== Done {
          status := Stalled

          switch fallbackSources {
          | [] =>
            logger->Logging.childError(
              `No new blocks detected within ${(sourceManager.newBlockFallbackStallTimeout / 1000)
                  ->Int.toString}s. Polling will continue at a reduced rate. For better reliability, refer to our RPC fallback guide: https://docs.envio.dev/docs/HyperIndex/rpc-sync`,
            )
          | _ =>
            logger->Logging.childWarn(
              `No new blocks detected within ${(sourceManager.newBlockFallbackStallTimeout / 1000)
                  ->Int.toString}s. Continuing polling with fallback RPC sources from the configuration.`,
            )
          }
        }
        // Promise.race will be forever pending if fallbackSources is empty
        // which is good for this use case
        Promise.race(
          fallbackSources->Array.map(async source => {
            (
              source,
              await getSourceNewHeight(
                ~source,
                ~currentBlockHeight,
                ~status,
                ~logger,
                ~stalledPollingInterval,
              ),
            )
          }),
        )
      }),
    ]),
  )

  sourceManager.activeSource = source

  // Show a higher level log if we displayed a warning/error after newBlockFallbackStallTimeout
  let log = status.contents === Stalled ? Logging.childInfo : Logging.childTrace
  logger->log({
    "msg": `New blocks successfully found.`,
    "source": source.name,
    "newBlockHeight": newBlockHeight,
  })

  status := Done

  newBlockHeight
}
