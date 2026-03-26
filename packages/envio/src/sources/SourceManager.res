open Belt

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

// Ideally the ChainFetcher name suits this better
// But currently the ChainFetcher module is immutable
// and handles both processing and fetching.
// So this module is to encapsulate the fetching logic only
// with a mutable state for easier reasoning and testing.
type t = {
  sourcesState: array<sourceState>,
  mutable statusStart: Hrtime.timeRef,
  mutable status: sourceManagerStatus,
  maxPartitionConcurrency: int,
  newBlockStallTimeout: int,
  newBlockStallTimeoutLive: int,
  stalledPollingInterval: int,
  getHeightRetryInterval: (~retry: int) => int,
  mutable activeSource: Source.t,
  mutable waitingForNewBlockStateId: option<int>,
  // Should take into consideration partitions fetching for previous states (before rollback)
  mutable fetchingPartitionsCount: int,
  recoveryTimeout: float,
  mutable hasLive: bool,
}

let getActiveSource = sourceManager => sourceManager.activeSource

type sourceRole = Primary | Secondary

// Determines whether a source is Primary or Secondary given the current mode.
// isLive=false (backfill): Sync=Primary, Fallback=Secondary, Live=ignored (None).
// isLive=true with hasLive: Live=Primary, Sync+Fallback=Secondary.
// isLive=true without hasLive: Sync=Primary, Fallback=Secondary.
let getSourceRole = (~sourceFor: Source.sourceFor, ~isLive, ~hasLive) =>
  switch (isLive, sourceFor) {
  | (false, Sync) => Some(Primary)
  | (false, Fallback) => Some(Secondary)
  | (false, Live) => None
  | (true, Live) => Some(Primary)
  | (true, Sync) => hasLive ? Some(Secondary) : Some(Primary)
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
  ~maxPartitionConcurrency,
  ~isLive,
  ~newBlockStallTimeout=60_000,
  ~newBlockStallTimeoutLive=20_000,
  ~stalledPollingInterval=5_000,
  ~recoveryTimeout=60_000.0,
  ~getHeightRetryInterval=makeGetHeightRetryInterval(
    ~initialRetryInterval=1000,
    ~backoffMultiplicative=2,
    ~maxRetryInterval=60_000,
  ),
) => {
  let hasLive = sources->Js.Array2.some(s => s.sourceFor === Live)
  let initialActiveSource =
    switch sources->Js.Array2.find(source =>
      getSourceRole(~sourceFor=source.sourceFor, ~isLive, ~hasLive) === Some(Primary)
    ) {
    | Some(source) => source
    | None =>
      Js.Exn.raiseError("Invalid configuration, no data-source for historical sync provided")
    }
  Prometheus.IndexingMaxConcurrency.set(
    ~maxConcurrency=maxPartitionConcurrency,
    ~chainId=initialActiveSource.chain->ChainMap.Chain.toChainId,
  )
  Prometheus.IndexingConcurrency.set(
    ~concurrency=0,
    ~chainId=initialActiveSource.chain->ChainMap.Chain.toChainId,
  )
  {
    maxPartitionConcurrency,
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
    newBlockStallTimeoutLive,
    stalledPollingInterval,
    getHeightRetryInterval,
    recoveryTimeout,
    statusStart: Hrtime.makeTimer(),
    status: Idle,
    hasLive,
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
  ~stateId,
) => {
  let {maxPartitionConcurrency} = sourceManager

  let nextQuery = fetchState->FetchState.getNextQuery(
    ~concurrencyLimit={
      maxPartitionConcurrency - sourceManager.fetchingPartitionsCount
    },
  )

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
      let _ =
        await queries
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
    if sourceState.source.sourceFor === Live {
      // Only clear hasLive if no other non-disabled Live sources remain
      let hasOtherLive = sourceManager.sourcesState->Js.Array2.some(s =>
        s !== sourceState && !s.disabled && s.source.sourceFor === Live
      )
      sourceManager.hasLive = hasOtherLive
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
  ~status: ref<status>,
  ~logger,
) => {
  let source = sourceState.source
  let initialHeight = sourceState.knownHeight
  let newHeight = ref(initialHeight)
  let retry = ref(0)

  while newHeight.contents <= knownHeight && status.contents !== Done {
    // If subscription exists, wait for next height event
    switch sourceState.unsubscribe {
    | Some(_) =>
      let height = await Promise.make((resolve, _reject) => {
        sourceState.pendingHeightResolvers->Array.push(resolve)
      })

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
          | Some(createSubscription) =>
            let unsubscribe = createSubscription(~onHeight=newHeight => {
              sourceState.knownHeight = newHeight
              // Resolve all pending height resolvers
              let resolvers = sourceState.pendingHeightResolvers
              sourceState.pendingHeightResolvers = []
              resolvers->Array.forEach(resolve => resolve(newHeight))
            })
            sourceState.unsubscribe = Some(unsubscribe)
          | None =>
            // Slowdown polling when the chain isn't progressing
            let pollingInterval = if status.contents === Stalled {
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
  | (None, Some(_)) => -1
  | (Some(_), None) => 1
  | (Some(a), Some(b)) => a < b ? -1 : a > b ? 1 : 0
  | (None, None) => 0
  }

// Priority: working primaries > working secondaries > all primaries.
let getNextSources = (sourceManager, ~isLive, ~excludedSources=?) => {
  let now = Js.Date.now()
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
        switch getSourceRole(~sourceFor=sourceState.source.sourceFor, ~isLive, ~hasLive=sourceManager.hasLive) {
        | Some(Primary) =>
          allPrimarySources->Array.push(sourceState)
          if isWorking {
            workingPrimarySources->Array.push(sourceState)
          }
        | Some(Secondary) if isWorking =>
          workingSecondarySources->Array.push(sourceState)
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
    allPrimarySources->Js.Array2.sortInPlaceWith(compareByOldestFailure)
  }
}

// Single source selection from getNextSources.
// Prefers activeSource if it's in the candidates. Fast path: check first item.
let getNextSource = (sourceManager, ~isLive, ~excludedSources=?) => {
  let sources = sourceManager->getNextSources(~isLive, ~excludedSources?)
  switch sources->Array.get(0) {
  | None => None
  | Some(first) if first.source === sourceManager.activeSource => Some(first)
  | _ =>
    switch sources->Js.Array2.find(s => s.source === sourceManager.activeSource) {
    | Some(_) as result => result
    | None => sources->Array.get(0)
    }
  }
}

// Polls for a block height greater than the given block number to ensure a new block is available for indexing.
let waitForNewBlock = async (sourceManager: t, ~knownHeight, ~isLive) => {
  let {sourcesState} = sourceManager

  let logger = Logging.createChild(
    ~params={
      "chainId": sourceManager.activeSource.chain->ChainMap.Chain.toChainId,
      "knownHeight": knownHeight,
    },
  )
  logger->Logging.childTrace("Initiating check for new blocks.")

  let mainSources = sourceManager->getNextSources(~isLive)

  let status = ref(Active)

  let stallTimeout = if isLive {
    sourceManager.newBlockStallTimeoutLive
  } else {
    sourceManager.newBlockStallTimeout
  }

  let (source, newBlockHeight) = await Promise.race(
    mainSources
    ->Array.map(async sourceState => {
      (
        sourceState.source,
        await sourceManager->getSourceNewHeight(~sourceState, ~knownHeight, ~status, ~logger),
      )
    })
    ->Array.concat([
      Utils.delay(stallTimeout)->Promise.then(() => {
        // Build fallback: sources not in mainSources with a valid role, even with recent lastFailedAt
        let fallbackSources = []
        sourcesState->Array.forEach(sourceState => {
          if (
            !(mainSources->Js.Array2.includes(sourceState)) &&
            getSourceRole(
              ~sourceFor=sourceState.source.sourceFor,
              ~isLive,
              ~hasLive=sourceManager.hasLive,
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
              await sourceManager->getSourceNewHeight(~sourceState, ~knownHeight, ~status, ~logger),
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

let executeQuery = async (sourceManager: t, ~query: FetchState.query, ~knownHeight, ~isLive) => {
  let noSourcesError = "The indexer doesn't have data-sources which can continue fetching. Please, check the error logs or reach out to the Envio team."

  // Sources where the query is impossible — lazily allocated, excluded for the duration of this query
  let excludedSourcesRef = ref(None)

  let toBlockRef = ref(query.toBlock)
  let responseRef = ref(None)
  let retryRef = ref(0)

  while responseRef.contents->Option.isNone {
    // Select the best source at the start of every iteration
    let sourceState = switch sourceManager->getNextSource(~isLive, ~excludedSources=?excludedSourcesRef.contents) {
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
        ~indexingContracts=query.indexingContracts,
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
      sourceManager.activeSource = source
      responseRef := Some(response)
    } catch {
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
          "msg": message,
          "toBlock": attemptedToBlock,
          "err": exn->Utils.prettifyExn,
        })
        retryRef := 0

      | FailedGettingItems({exn, attemptedToBlock, retry: WithBackoff({message, backoffMillis})}) =>
        let shouldSwitch = switch retry {
        // Don't attempt a switch on first two failures
        | 0 | 1 => false
        // Then try to switch every second failure
        | _ => retry->mod(2) === 0
        }

        // Start displaying warnings after 4 failures
        let log = retry >= 4 ? Logging.childWarn : Logging.childTrace
        logger->log({
          "msg": message,
          "toBlock": attemptedToBlock,
          "backOffMilliseconds": backoffMillis,
          "retry": retry,
          "err": exn->Utils.prettifyExn,
        })

        if shouldSwitch {
          sourceState.lastFailedAt = Some(Js.Date.now())
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
