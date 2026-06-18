type sourceManagerStatus = Idle | WaitingForNewBlock | Querieng

type sourceState = {
  source: Source.t,
  mutable knownHeight: int,
  mutable unsubscribe: option<unit => unit>,
  mutable pendingHeightResolvers: array<int => unit>,
  mutable disabled: bool,
  // Timestamp (ms) when this source last failed during executeQuery.
  // Used to decide when to attempt recovery to this source.
  mutable lastFailedAt: option<float>,
}

// Encapsulates the fetching logic for a chain's sources.
// with a mutable state for easier reasoning and testing.
type t = {
  sourcesState: array<sourceState>,
  mutable statusStart: Hrtime.timeRef,
  mutable status: sourceManagerStatus,
  newBlockStallTimeout: int,
  newBlockStallTimeoutRealtime: int,
  stalledPollingInterval: int,
  reducedPollingInterval: int,
  getHeightRetryInterval: (~retry: int) => int,
  mutable activeSource: Source.t,
  mutable waitingForNewBlockStateId: option<int>,
  // Should take into consideration partitions fetching for previous states (before rollback)
  mutable fetchingPartitionsCount: int,
  recoveryTimeout: float,
  mutable hasRealtime: bool,
  mutable committedRateLimitTimeMs: float,
  mutable rateLimitWaiters: int,
  // Wall-clock timestamp (Date.now()) when the current rate-limit window
  // started, or None if not currently waiting. Wall-clock so consumers
  // (TUI) can compute elapsed time with their own Date.now() reads.
  mutable activeRateLimitStartMs: option<float>,
  // Wall-clock timestamp by which the server expects the longest current
  // wait to clear. Tracks the latest reset across concurrent waiters so
  // the displayed countdown reflects when the indexer will actually retry.
  mutable activeRateLimitResetAtMs: option<float>,
}

let getActiveSource = sourceManager => sourceManager.activeSource

// Partition queries currently in flight on this chain's sources. Summed across
// chains by CrossChainState to enforce the indexer-wide concurrency budget.
let inFlightCount = sourceManager => sourceManager.fetchingPartitionsCount

let getRateLimitTimeMs = sourceManager =>
  sourceManager.committedRateLimitTimeMs +.
  switch sourceManager.activeRateLimitStartMs {
  | Some(startMs) => Date.now() -. startMs
  | None => 0.0
  }

let isRateLimited = sourceManager => sourceManager.activeRateLimitStartMs->Option.isSome

let getRateLimitResetInMs = sourceManager =>
  switch sourceManager.activeRateLimitResetAtMs {
  | Some(resetAt) =>
    let remaining = resetAt -. Date.now()
    remaining > 0.0 ? Some(remaining) : None
  | None => None
  }

let startRateLimitTimeout = (sourceManager, ~resetMs) => {
  let now = Date.now()
  if sourceManager.rateLimitWaiters === 0 {
    sourceManager.activeRateLimitStartMs = Some(now)
  }
  let resetAt = now +. resetMs->Int.toFloat
  sourceManager.activeRateLimitResetAtMs = switch sourceManager.activeRateLimitResetAtMs {
  | Some(existing) => Some(Pervasives.max(existing, resetAt))
  | None => Some(resetAt)
  }
  sourceManager.rateLimitWaiters = sourceManager.rateLimitWaiters + 1
}

let stopRateLimitTimeout = sourceManager => {
  sourceManager.rateLimitWaiters = sourceManager.rateLimitWaiters - 1
  if sourceManager.rateLimitWaiters === 0 {
    switch sourceManager.activeRateLimitStartMs {
    | Some(startMs) =>
      sourceManager.committedRateLimitTimeMs =
        sourceManager.committedRateLimitTimeMs +. Date.now() -. startMs
      sourceManager.activeRateLimitStartMs = None
    | None => ()
    }
    sourceManager.activeRateLimitResetAtMs = None
  }
}

// Shared between executeQuery and getBlockHashes: wait out the server's
// suggested reset window. Cap at 5 minutes to protect against
// pathologically large server values. Escalates the log from trace to
// warn after the second consecutive retry so the indexer doesn't go
// silent under chronic throttling.
let waitForRateLimitReset = async (sourceManager: t, ~resetMs, ~retry, ~logger) => {
  let waitMs = Pervasives.min(resetMs, 300_000)
  let log = retry >= 2 ? Logging.childWarn : Logging.childTrace
  logger->log({
    "msg": `HyperSync source is rate-limited — not critical, the indexer will retry in ${(waitMs / 1000)
        ->Int.toString}s. For higher limits upgrade your plan at https://envio.dev/app/api-tokens.`,
    "retry": retry,
    "waitMs": waitMs,
  })
  sourceManager->startRateLimitTimeout(~resetMs=waitMs)
  await Utils.delay(waitMs)
  sourceManager->stopRateLimitTimeout
}

let onReorg = (sourceManager: t, ~rollbackTargetBlock) => {
  sourceManager.sourcesState->Array.forEach(({source}) => {
    switch source.onReorg {
    | Some(cb) => cb(~rollbackTargetBlock)
    | None => ()
    }
  })
}

type sourceRole = Primary | Secondary

// Determines whether a source is Primary or Secondary given the current mode.
// isRealtime=false (backfill): Sync=Primary, Fallback=Secondary, Realtime=ignored (None).
// isRealtime=true with hasRealtime: Realtime=Primary, Sync+Fallback=Secondary.
// isRealtime=true without hasRealtime: Sync=Primary, Fallback=Secondary.
let getSourceRole = (~sourceFor: Source.sourceFor, ~isRealtime, ~hasRealtime) =>
  switch (isRealtime, sourceFor) {
  | (false, Sync) => Some(Primary)
  | (false, Fallback) => Some(Secondary)
  | (false, Realtime) => None
  | (true, Realtime) => Some(Primary)
  | (true, Sync) => hasRealtime ? Some(Secondary) : Some(Primary)
  | (true, Fallback) => Some(Secondary)
  }

let makeGetHeightRetryInterval = (
  ~initialRetryInterval,
  ~backoffMultiplicative,
  ~maxRetryInterval,
) => {
  (~retry: int) => {
    let backoff = if retry === 0 {
      1
    } else {
      retry * backoffMultiplicative
    }
    Pervasives.min(initialRetryInterval * backoff, maxRetryInterval)
  }
}

let make = (
  ~sources: array<Source.t>,
  ~isRealtime,
  ~newBlockStallTimeout=60_000,
  ~newBlockStallTimeoutRealtime=20_000,
  ~stalledPollingInterval=5_000,
  ~reducedPollingInterval=60_000,
  ~recoveryTimeout=60_000.0,
  ~getHeightRetryInterval=makeGetHeightRetryInterval(
    ~initialRetryInterval=1000,
    ~backoffMultiplicative=2,
    ~maxRetryInterval=60_000,
  ),
) => {
  let hasRealtime = sources->Array.some(s => s.sourceFor === Realtime)
  let initialActiveSource = switch sources->Array.find(source =>
    getSourceRole(~sourceFor=source.sourceFor, ~isRealtime, ~hasRealtime) === Some(Primary)
  ) {
  | Some(source) => source
  | None =>
    JsError.throwWithMessage("Invalid configuration, no data-source for historical sync provided")
  }
  Prometheus.IndexingConcurrency.set(
    ~concurrency=0,
    ~chainId=initialActiveSource.chain->ChainMap.Chain.toChainId,
  )
  {
    sourcesState: sources->Array.map(source => {
      source,
      knownHeight: 0,
      unsubscribe: None,
      pendingHeightResolvers: [],
      disabled: false,
      lastFailedAt: None,
    }),
    activeSource: initialActiveSource,
    waitingForNewBlockStateId: None,
    fetchingPartitionsCount: 0,
    newBlockStallTimeout,
    newBlockStallTimeoutRealtime,
    stalledPollingInterval,
    reducedPollingInterval,
    getHeightRetryInterval,
    recoveryTimeout,
    statusStart: Hrtime.makeTimer(),
    status: Idle,
    hasRealtime,
    committedRateLimitTimeMs: 0.0,
    rateLimitWaiters: 0,
    activeRateLimitStartMs: None,
    activeRateLimitResetAtMs: None,
  }
}

let trackNewStatus = (sourceManager: t, ~newStatus) => {
  let promCounter = switch sourceManager.status {
  | Idle => Prometheus.IndexingIdleTime.counter
  | WaitingForNewBlock => Prometheus.IndexingSourceWaitingTime.counter
  | Querieng => Prometheus.IndexingQueryTime.counter
  }
  promCounter->Prometheus.SafeCounter.handleFloat(
    ~labels=sourceManager.activeSource.chain->ChainMap.Chain.toChainId,
    ~value=sourceManager.statusStart->Hrtime.timeSince->Hrtime.toSecondsFloat,
  )
  sourceManager.statusStart = Hrtime.makeTimer()
  sourceManager.status = newStatus
}

let fetchNext = async (
  sourceManager: t,
  ~fetchState: FetchState.t,
  ~executeQuery,
  ~waitForNewBlock,
  ~onNewBlock,
  ~concurrencyLimit,
  ~stateId,
) => {
  let nextQuery = fetchState->FetchState.getNextQuery(~concurrencyLimit)

  switch nextQuery {
  | ReachedMaxConcurrency
  | NothingToQuery => ()
  | WaitingForNewBlock =>
    switch sourceManager.waitingForNewBlockStateId {
    | Some(waitingStateId) if waitingStateId >= stateId => ()
    | Some(_) // Case for the prev state before a rollback
    | None =>
      sourceManager->trackNewStatus(~newStatus=WaitingForNewBlock)
      sourceManager.waitingForNewBlockStateId = Some(stateId)
      let knownHeight = await waitForNewBlock(~knownHeight=fetchState.knownHeight)
      switch sourceManager.waitingForNewBlockStateId {
      | Some(waitingStateId) if waitingStateId === stateId => {
          sourceManager->trackNewStatus(~newStatus=Idle)
          sourceManager.waitingForNewBlockStateId = None
          onNewBlock(~knownHeight)
        }
      | Some(_) // Don't reset it if we are waiting for another state
      | None => ()
      }
    }
  | Ready(queries) => {
      fetchState->FetchState.startFetchingQueries(~queries)
      sourceManager.fetchingPartitionsCount =
        sourceManager.fetchingPartitionsCount + queries->Array.length
      Prometheus.IndexingConcurrency.set(
        ~concurrency=sourceManager.fetchingPartitionsCount,
        ~chainId=sourceManager.activeSource.chain->ChainMap.Chain.toChainId,
      )
      sourceManager->trackNewStatus(~newStatus=Querieng)
      let _ = await queries
      ->Array.map(q => {
        let promise = q->executeQuery
        let _ = promise->Promise.thenResolve(_ => {
          sourceManager.fetchingPartitionsCount = sourceManager.fetchingPartitionsCount - 1
          Prometheus.IndexingConcurrency.set(
            ~concurrency=sourceManager.fetchingPartitionsCount,
            ~chainId=sourceManager.activeSource.chain->ChainMap.Chain.toChainId,
          )
          if sourceManager.fetchingPartitionsCount === 0 {
            sourceManager->trackNewStatus(~newStatus=Idle)
          }
        })
        promise
      })
      ->Promise.all
    }
  }
}

type status = Active | Stalled | Done

let disableSource = (sourceManager: t, sourceState: sourceState) => {
  if !sourceState.disabled {
    sourceState.disabled = true
    switch sourceState.unsubscribe {
    | Some(unsubscribe) => unsubscribe()
    | None => ()
    }
    if sourceState.source.sourceFor === Realtime {
      // Only clear hasRealtime if no other non-disabled Realtime sources remain
      let hasOtherRealtime =
        sourceManager.sourcesState->Array.some(s =>
          s !== sourceState && !s.disabled && s.source.sourceFor === Realtime
        )
      sourceManager.hasRealtime = hasOtherRealtime
    }
    true
  } else {
    false
  }
}

let getSourceNewHeight = async (
  sourceManager,
  ~sourceState: sourceState,
  ~knownHeight,
  ~stallTimeout,
  ~isRealtime,
  ~status: ref<status>,
  ~logger,
  ~reducedPolling,
) => {
  let source = sourceState.source
  let initialHeight = sourceState.knownHeight
  let newHeight = ref(initialHeight)
  let retry = ref(0)

  while newHeight.contents <= knownHeight && status.contents !== Done {
    switch sourceState.unsubscribe {
    | Some(_) =>
      let subscriptionPromise = Promise.make((resolve, _reject) => {
        sourceState.pendingHeightResolvers->Array.push(resolve)
      })
      // If the subscription goes quiet for half the stall timeout, fall back to REST
      // polling. Jitter the trigger across [stallTimeout/2, stallTimeout) so indexers
      // that go quiet together don't all start polling at the same instant.
      let half = stallTimeout / 2
      let pollingFallback = Utils.delay(
        half + (Math.random() *. half->Int.toFloat)->Float.toInt,
      )->Promise.then(async () => {
        logger->Logging.childTrace({
          "msg": "onHeight subscription stale, switching to polling fallback",
          "source": source.name,
          "chainId": source.chain->ChainMap.Chain.toChainId,
        })
        let h = ref(initialHeight)
        while h.contents <= knownHeight && !(newHeight.contents > initialHeight) {
          try {
            h := (await source.getHeightOrThrow())
          } catch {
          | _ => ()
          }
          if h.contents <= knownHeight && !(newHeight.contents > initialHeight) {
            await Utils.delay(source.pollingInterval)
          }
        }
        h.contents
      })
      let height = await Promise.race([subscriptionPromise, pollingFallback])

      // Only accept heights greater than initialHeight
      if height > initialHeight {
        newHeight := height
      }
    | None =>
      // No subscription, use REST polling
      try {
        let height = await source.getHeightOrThrow()

        newHeight := height
        if height <= knownHeight {
          retry := 0

          // If createHeightSubscription is available and height hasn't changed,
          // create subscription instead of polling
          switch source.createHeightSubscription {
          | Some(createSubscription) if isRealtime =>
            let unsubscribe = createSubscription(~onHeight=newHeight => {
              // Ignore non-increasing heights. The height stream re-emits the current
              // head on every (re)connect; waking the wait loop on a height we already
              // know spins it and leaks fallback pollers (#1270).
              if newHeight > sourceState.knownHeight {
                sourceState.knownHeight = newHeight
                let resolvers = sourceState.pendingHeightResolvers
                sourceState.pendingHeightResolvers = []
                resolvers->Array.forEach(resolve => resolve(newHeight))
              }
            })
            sourceState.unsubscribe = Some(unsubscribe)
          | _ =>
            // Slowdown polling when the chain isn't progressing
            let pollingInterval = if reducedPolling {
              sourceManager.reducedPollingInterval
            } else if status.contents === Stalled {
              sourceManager.stalledPollingInterval
            } else {
              source.pollingInterval
            }
            await Utils.delay(pollingInterval)
          }
        }
      } catch {
      | exn =>
        let retryInterval = sourceManager.getHeightRetryInterval(~retry=retry.contents)
        logger->Logging.childTrace({
          "msg": `Height retrieval from ${source.name} source failed. Retrying in ${retryInterval->Int.toString}ms.`,
          "source": source.name,
          "err": exn->Utils.prettifyExn,
        })
        retry := retry.contents + 1
        await Utils.delay(retryInterval)
      }
    }
  }

  // Update Prometheus only if height increased
  if newHeight.contents > initialHeight {
    Prometheus.SourceHeight.set(
      ~sourceName=source.name,
      ~chainId=source.chain->ChainMap.Chain.toChainId,
      ~blockNumber=newHeight.contents,
    )
  }

  newHeight.contents
}

let compareByOldestFailure = (a: sourceState, b: sourceState) =>
  switch (a.lastFailedAt, b.lastFailedAt) {
  | (None, Some(_)) => Ordering.less
  | (Some(_), None) => Ordering.greater
  | (Some(a), Some(b)) => a < b ? Ordering.less : a > b ? Ordering.greater : Ordering.equal
  | (None, None) => Ordering.equal
  }

// Priority: working primaries > working secondaries > all primaries.
let getNextSources = (sourceManager, ~isRealtime, ~excludedSources=?) => {
  let now = Date.now()
  let workingPrimarySources = []
  let allPrimarySources = []
  let workingSecondarySources = []
  for i in 0 to sourceManager.sourcesState->Array.length - 1 {
    let sourceState = sourceManager.sourcesState->Array.getUnsafe(i)
    if !sourceState.disabled {
      let isExcluded = switch excludedSources {
      | Some(set) => set->Utils.Set.has(sourceState)
      | None => false
      }
      if !isExcluded {
        let isWorking = switch sourceState.lastFailedAt {
        | Some(failedAt) => now -. failedAt >= sourceManager.recoveryTimeout
        | None => true
        }
        switch getSourceRole(
          ~sourceFor=sourceState.source.sourceFor,
          ~isRealtime,
          ~hasRealtime=sourceManager.hasRealtime,
        ) {
        | Some(Primary) =>
          allPrimarySources->Array.push(sourceState)
          if isWorking {
            workingPrimarySources->Array.push(sourceState)
          }
        | Some(Secondary) if isWorking => workingSecondarySources->Array.push(sourceState)
        | _ => ()
        }
      }
    }
  }
  if workingPrimarySources->Array.length > 0 {
    workingPrimarySources
  } else if workingSecondarySources->Array.length > 0 {
    workingSecondarySources
  } else {
    // All primaries in recovery — sort by oldest lastFailedAt (closest to recovery first)
    allPrimarySources->Array.sort(compareByOldestFailure)
    allPrimarySources
  }
}

// Single source selection from getNextSources.
// Prefers activeSource if it's in the candidates. Fast path: check first item.
let getNextSource = (sourceManager, ~isRealtime, ~excludedSources=?) => {
  let sources = sourceManager->getNextSources(~isRealtime, ~excludedSources?)
  switch sources->Array.get(0) {
  | None => None
  | Some(first) if first.source === sourceManager.activeSource => Some(first)
  | _ =>
    switch sources->Array.find(s => s.source === sourceManager.activeSource) {
    | Some(_) as result => result
    | None => sources->Array.get(0)
    }
  }
}

// Polls for a block height greater than the given block number to ensure a new block is available for indexing.
let waitForNewBlock = async (sourceManager: t, ~knownHeight, ~isRealtime, ~reducedPolling) => {
  let {sourcesState} = sourceManager

  let logger = Logging.createChild(
    ~params={
      "chainId": sourceManager.activeSource.chain->ChainMap.Chain.toChainId,
      "knownHeight": knownHeight,
    },
  )
  if reducedPolling {
    logger->Logging.childTrace(
      `Waiting for new blocks with reduced polling (${(sourceManager.reducedPollingInterval / 1000)
          ->Int.toString}s). Chain is caught up, waiting for other chains to backfill.`,
    )
  } else {
    logger->Logging.childTrace("Initiating check for new blocks.")
  }

  let mainSources = sourceManager->getNextSources(~isRealtime)

  let status = ref(Active)

  // Use a much longer stall timeout when reduced polling is active
  // to avoid spurious stall warnings while waiting for other chains to backfill
  let stallTimeout = if reducedPolling {
    sourceManager.reducedPollingInterval * 2
  } else if isRealtime {
    sourceManager.newBlockStallTimeoutRealtime
  } else {
    sourceManager.newBlockStallTimeout
  }

  let (source, newBlockHeight) = await Promise.race(
    mainSources
    ->Array.map(async sourceState => {
      (
        sourceState.source,
        await sourceManager->getSourceNewHeight(
          ~sourceState,
          ~knownHeight,
          ~stallTimeout,
          ~isRealtime,
          ~status,
          ~logger,
          ~reducedPolling,
        ),
      )
    })
    ->Array.concat([
      Utils.delay(stallTimeout)->Promise.then(() => {
        // Build fallback: non-disabled sources not in mainSources with a valid role, even with recent lastFailedAt
        let fallbackSources = []
        sourcesState->Array.forEach(sourceState => {
          if (
            !sourceState.disabled &&
            !(mainSources->Array.includes(sourceState)) &&
            getSourceRole(
              ~sourceFor=sourceState.source.sourceFor,
              ~isRealtime,
              ~hasRealtime=sourceManager.hasRealtime,
            )->Option.isSome
          ) {
            fallbackSources->Array.push(sourceState)
          }
        })

        if status.contents !== Done {
          status := Stalled

          switch fallbackSources {
          | [] =>
            logger->Logging.childWarn(
              `No new blocks detected within ${(stallTimeout / 1000)
                  ->Int.toString}s. Polling will continue at a reduced rate. For better reliability, refer to our RPC fallback guide: https://docs.envio.dev/docs/HyperIndex/rpc-sync`,
            )
          | _ =>
            logger->Logging.childWarn(
              `No new blocks detected within ${(stallTimeout / 1000)
                  ->Int.toString}s. Continuing polling with secondary RPC sources from the configuration.`,
            )
          }
        }
        // Promise.race will be forever pending if fallbackSources is empty
        // which is good for this use case
        Promise.race(
          fallbackSources->Array.map(async sourceState => {
            (
              sourceState.source,
              await sourceManager->getSourceNewHeight(
                ~sourceState,
                ~knownHeight,
                ~stallTimeout,
                ~isRealtime,
                ~status,
                ~logger,
                ~reducedPolling,
              ),
            )
          }),
        )
      }),
    ]),
  )

  sourceManager.activeSource = source

  // Show a higher level log if we displayed a warning/error after newBlockStallTimeout
  let log = status.contents === Stalled ? Logging.childInfo : Logging.childTrace
  logger->log({
    "msg": `New blocks successfully found.`,
    "source": source.name,
    "newBlockHeight": newBlockHeight,
  })

  status := Done

  newBlockHeight
}

let executeQuery = async (
  sourceManager: t,
  ~query: FetchState.query,
  ~knownHeight,
  ~isRealtime,
) => {
  let noSourcesError = "The indexer doesn't have data-sources which can continue fetching. Please, check the error logs or reach out to the Envio team."

  // Sources where the query is impossible — lazily allocated, excluded for the duration of this query
  let excludedSourcesRef = ref(None)

  let toBlockRef = ref(query.toBlock)
  let responseRef = ref(None)
  let retryRef = ref(0)

  while responseRef.contents->Option.isNone {
    // Select the best source at the start of every iteration
    let sourceState = switch sourceManager->getNextSource(
      ~isRealtime,
      ~excludedSources=?excludedSourcesRef.contents,
    ) {
    | Some(s) =>
      if s.source !== sourceManager.activeSource {
        let logger = Logging.createChild(
          ~params={"chainId": sourceManager.activeSource.chain->ChainMap.Chain.toChainId},
        )
        logger->Logging.childInfo({
          "msg": "Switching data-source",
          "source": s.source.name,
          "previousSource": sourceManager.activeSource.name,
          "fromBlock": query.fromBlock,
        })
      }
      s
    | None =>
      let logger = Logging.createChild(
        ~params={"chainId": sourceManager.activeSource.chain->ChainMap.Chain.toChainId},
      )
      %raw(`null`)->ErrorHandling.mkLogAndRaise(~logger, ~msg=noSourcesError)
    }
    sourceManager.activeSource = sourceState.source
    let source = sourceState.source
    let toBlock = toBlockRef.contents
    let retry = retryRef.contents

    let logger = Logging.createChild(
      ~params={
        "chainId": source.chain->ChainMap.Chain.toChainId,
        "logType": "Block Range Query",
        "partitionId": query.partitionId,
        "source": source.name,
        "fromBlock": query.fromBlock,
        "toBlock": toBlock,
        "addresses": query.addressesByContractName->FetchState.addressesByContractNameCount,
        "retry": retry,
      },
    )

    try {
      let response = await source.getItemsOrThrow(
        ~fromBlock=query.fromBlock,
        ~toBlock,
        ~addressesByContractName=query.addressesByContractName,
        ~indexingAddresses=query.indexingAddresses,
        ~partitionId=query.partitionId,
        ~knownHeight,
        ~selection=query.selection,
        ~retry,
        ~logger,
      )
      logger->Logging.childTrace({
        "msg": "Fetched block range from server",
        "toBlock": response.latestFetchedBlockNumber,
        "numEvents": response.parsedQueueItems->Array.length,
        "stats": response.stats,
      })
      sourceState.lastFailedAt = None
      responseRef := Some(response)
    } catch {
    | Source.RateLimited({resetMs}) =>
      await sourceManager->waitForRateLimitReset(~resetMs, ~retry, ~logger)
      retryRef := retryRef.contents + 1

    | Source.GetItemsError(error) =>
      switch error {
      | UnsupportedSelection(_)
      | FailedGettingFieldSelection(_) => {
          // These errors are impossible to recover, so we disable the source
          // so it's not attempted anymore
          let notAlreadyDisabled = sourceManager->disableSource(sourceState)

          // In case there are multiple partitions
          // failing at the same time. Log only once
          if notAlreadyDisabled {
            switch error {
            | UnsupportedSelection({message}) => logger->Logging.childError(message)
            | FailedGettingFieldSelection({exn, message, blockNumber, logIndex}) =>
              logger->Logging.childError({
                "msg": message,
                "err": exn->Utils.prettifyExn,
                "blockNumber": blockNumber,
                "logIndex": logIndex,
              })
            | _ => ()
            }
          }

          retryRef := 0
        }
      | FailedGettingItems({attemptedToBlock, retry: WithSuggestedToBlock({toBlock})}) =>
        logger->Logging.childTrace({
          "msg": "Failed getting data for the block range. Immediately retrying with the suggested block range from response.",
          "toBlock": attemptedToBlock,
          "suggestedToBlock": toBlock,
        })
        toBlockRef := Some(toBlock)
        retryRef := 0
      | FailedGettingItems({exn, attemptedToBlock, retry: ImpossibleForTheQuery({message})}) =>
        // Don't set lastFailedAt — the source isn't broken, the query just can't work on it
        let excludedSources = switch excludedSourcesRef.contents {
        | Some(s) => s
        | None =>
          let s = Utils.Set.make()
          excludedSourcesRef := Some(s)
          s
        }
        excludedSources->Utils.Set.add(sourceState)->ignore

        logger->Logging.childWarn({
          "msg": message ++ " - Attempting another source",
          "toBlock": attemptedToBlock,
          "err": exn->Utils.prettifyExn,
        })
        retryRef := 0

      | FailedGettingItems({exn, attemptedToBlock, retry: WithBackoff({message, backoffMillis})}) =>
        // Start displaying warnings after 4 failures
        let log = retry >= 4 ? Logging.childWarn : Logging.childTrace
        logger->log({
          "msg": message,
          "toBlock": attemptedToBlock,
          "backOffMilliseconds": backoffMillis,
          "retry": retry,
          "err": exn->Utils.prettifyExn,
        })

        let shouldSwitch = switch retry {
        // Don't attempt a switch on first two failures
        | 0 | 1 => false
        // Then try to switch every second failure
        | _ => retry->mod(2) === 0
        }

        if shouldSwitch {
          let now = Date.now()
          sourceState.lastFailedAt = Some(now)
          // Check if there's a working (recovered) source to switch to immediately
          let nextSource =
            sourceManager->getNextSource(~isRealtime, ~excludedSources=?excludedSourcesRef.contents)
          let hasWorkingAlternative = switch nextSource {
          | Some(s) =>
            switch s.lastFailedAt {
            | None => true
            | Some(failedAt) => now -. failedAt >= sourceManager.recoveryTimeout
            }
          | None => false
          }
          if !hasWorkingAlternative {
            await Utils.delay(Pervasives.min(backoffMillis, 60_000))
          }
        } else {
          await Utils.delay(Pervasives.min(backoffMillis, 60_000))
        }
        retryRef := retryRef.contents + 1
      }

    // TODO: Handle more error cases and hang/retry instead of throwing
    | exn => exn->ErrorHandling.mkLogAndRaise(~logger, ~msg="Failed to fetch block Range")
    }
  }

  responseRef.contents->Option.getUnsafe
}

let getBlockHashes = async (sourceManager: t, ~blockNumbers: array<int>, ~isRealtime: bool) => {
  let responseRef = ref(None)
  let retryRef = ref(0)

  while responseRef.contents->Option.isNone {
    let sourceState = switch sourceManager->getNextSource(~isRealtime) {
    | Some(s) => s
    | None =>
      let logger = Logging.createChild(
        ~params={"chainId": sourceManager.activeSource.chain->ChainMap.Chain.toChainId},
      )
      %raw(`null`)->ErrorHandling.mkLogAndRaise(
        ~logger,
        ~msg="No data-sources available for fetching block hashes.",
      )
    }
    sourceManager.activeSource = sourceState.source
    let source = sourceState.source
    let retry = retryRef.contents

    let logger = Logging.createChild(
      ~params={
        "chainId": source.chain->ChainMap.Chain.toChainId,
        "logType": "Block Hash Query",
        "source": source.name,
        "retry": retry,
      },
    )

    try {
      let res = await source.getBlockHashes(~blockNumbers, ~logger)
      switch res {
      | Ok(data) =>
        sourceState.lastFailedAt = None
        responseRef := Some(data)
      | Error(exn) => throw(exn)
      }
    } catch {
    | Source.RateLimited({resetMs}) =>
      await sourceManager->waitForRateLimitReset(~resetMs, ~retry, ~logger)
      retryRef := retryRef.contents + 1

    | exn =>
      let backoffMillis = switch retry {
      | 0 => 500
      | _ => 1000 * retry
      }
      let log = retry >= 4 ? Logging.childWarn : Logging.childTrace
      logger->log({
        "msg": "Failed to fetch block hashes. Retrying.",
        "retry": retry,
        "backOffMilliseconds": backoffMillis,
        "err": exn->Utils.prettifyExn,
      })

      let shouldSwitch = switch retry {
      | 0 | 1 => false
      | _ => retry->mod(2) === 0
      }

      if shouldSwitch {
        sourceState.lastFailedAt = Some(Date.now())
      }
      await Utils.delay(Pervasives.min(backoffMillis, 60_000))
      retryRef := retryRef.contents + 1
    }
  }

  responseRef.contents->Option.getUnsafe
}
