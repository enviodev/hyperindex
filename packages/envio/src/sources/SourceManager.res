open Belt

type sourceManagerStatus = Idle | WaitingForNewBlock | Querieng

type sourceState = {
  source: Source.t,
  mutable knownHeight: int,
  mutable unsubscribe: option<unit => unit>,
  mutable pendingHeightResolvers: array<int => unit>,
  mutable disabled: bool,
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
  newBlockFallbackStallTimeout: int,
  newBlockFallbackStallTimeoutLive: int,
  stalledPollingInterval: int,
  getHeightRetryInterval: (~retry: int) => int,
  mutable activeSource: Source.t,
  mutable waitingForNewBlockStateId: option<int>,
  // Should take into consideration partitions fetching for previous states (before rollback)
  mutable fetchingPartitionsCount: int,
  // Timestamp (ms) when we switched to a fallback/secondary source.
  // After fallbackRecoveryTimeout ms, we attempt to switch back to a primary source.
  mutable fallbackSwitchTimestamp: option<float>,
  fallbackRecoveryTimeout: int,
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

let hasLiveSource = (sourceManager: t) =>
  sourceManager.sourcesState->Js.Array2.some(s => !s.disabled && s.source.sourceFor === Live)

let make = (
  ~sources: array<Source.t>,
  ~maxPartitionConcurrency,
  ~isLive=false,
  ~newBlockFallbackStallTimeout=60_000,
  ~newBlockFallbackStallTimeoutLive=20_000,
  ~stalledPollingInterval=5_000,
  ~fallbackRecoveryTimeout=60_000,
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
    }),
    activeSource: initialActiveSource,
    waitingForNewBlockStateId: None,
    fetchingPartitionsCount: 0,
    newBlockFallbackStallTimeout,
    newBlockFallbackStallTimeoutLive,
    stalledPollingInterval,
    getHeightRetryInterval,
    fallbackRecoveryTimeout,
    statusStart: Hrtime.makeTimer(),
    status: Idle,
    fallbackSwitchTimestamp: None,
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

let disableSource = (sourceState: sourceState) => {
  if !sourceState.disabled {
    sourceState.disabled = true
    switch sourceState.unsubscribe {
    | Some(unsubscribe) => unsubscribe()
    | None => ()
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

  let hasLive = sourceManager->hasLiveSource
  let primarySources = []
  let fallbackSources = []
  sourcesState->Array.forEach(sourceState => {
    let source = sourceState.source
    if sourceState.disabled {
      // Skip disabled sources
      ()
    } else {
      switch getSourceRole(~sourceFor=source.sourceFor, ~isLive, ~hasLive) {
      | Some(Primary) => primarySources->Array.push(sourceState)
      | Some(Secondary) =>
        // If the active source is acting as secondary, still include
        // it in the primary list so we don't wait for a timeout again
        // when all primary sources are still unavailable.
        if source === sourceManager.activeSource {
          primarySources->Array.push(sourceState)
        } else {
          fallbackSources->Array.push(sourceState)
        }
      | None => ()
      }
    }
  })

  let status = ref(Active)

  let stallTimeout = if isLive {
    sourceManager.newBlockFallbackStallTimeoutLive
  } else {
    sourceManager.newBlockFallbackStallTimeout
  }

  let (source, newBlockHeight) = await Promise.race(
    primarySources
    ->Array.map(async sourceState => {
      (
        sourceState.source,
        await sourceManager->getSourceNewHeight(~sourceState, ~knownHeight, ~status, ~logger),
      )
    })
    ->Array.concat([
      Utils.delay(stallTimeout)->Promise.then(() => {
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
                  ->Int.toString}s. Continuing polling with fallback RPC sources from the configuration.`,
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

  // Record the timestamp when we switch to a secondary/fallback source via stall timeout,
  // so the recovery timer in executeQuery starts from the actual switch moment.
  if (
    status.contents === Stalled &&
      sourceManager.fallbackSwitchTimestamp === None &&
      getSourceRole(~sourceFor=source.sourceFor, ~isLive, ~hasLive=sourceManager->hasLiveSource) ===
        Some(Secondary)
  ) {
    sourceManager.fallbackSwitchTimestamp = Some(Js.Date.now())
  }

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

let getNextSyncSourceState = (
  sourceManager,
  // This is needed to include the Fallback source to rotation
  ~initialSourceState: sourceState,
  ~currentSourceState: sourceState,
  // After multiple failures start returning secondary sources as well
  // But don't try it when primary sources fail because of invalid configuration
  // note: The logic might be changed in the future
  ~attemptFallbacks=false,
  ~isLive,
) => {
  let before = []
  let after = []

  let hasActive = ref(false)
  let hasLive = sourceManager->hasLiveSource

  sourceManager.sourcesState->Array.forEach(sourceState => {
    let source = sourceState.source

    // Skip disabled sources
    if sourceState.disabled {
      ()
    } else if sourceState === currentSourceState {
      hasActive := true
    } else {
      let shouldInclude = switch getSourceRole(~sourceFor=source.sourceFor, ~isLive, ~hasLive) {
      | Some(Primary) => true
      | Some(Secondary) => attemptFallbacks || sourceState === initialSourceState
      | None => false
      }
      if shouldInclude {
        (hasActive.contents ? after : before)->Array.push(sourceState)
      }
    }
  })

  switch after->Array.get(0) {
  | Some(s) => s
  | None =>
    switch before->Array.get(0) {
    | Some(s) => s
    | None => currentSourceState
    }
  }
}

let getFirstPrimarySourceState = (sourceManager: t, ~isLive) => {
  let hasLive = sourceManager->hasLiveSource
  sourceManager.sourcesState->Js.Array2.find(s =>
    !s.disabled &&
      getSourceRole(~sourceFor=s.source.sourceFor, ~isLive, ~hasLive) === Some(Primary)
  )
}

// Called when activeSource changes to track fallback/secondary state.
// Sets fallbackSwitchTimestamp when switching to a secondary source,
// clears it when switching back to a primary source.
let onActiveSourceChanged = (sourceManager: t, ~isLive) => {
  let hasLive = sourceManager->hasLiveSource
  if (
    getSourceRole(~sourceFor=sourceManager.activeSource.sourceFor, ~isLive, ~hasLive) ===
      Some(Primary)
  ) {
    sourceManager.fallbackSwitchTimestamp = None
  } else if sourceManager.fallbackSwitchTimestamp === None {
    sourceManager.fallbackSwitchTimestamp = Some(Js.Date.now())
  }
}

let executeQuery = async (sourceManager: t, ~query: FetchState.query, ~knownHeight, ~isLive) => {
  let toBlockRef = ref(query.toBlock)
  let responseRef = ref(None)
  let retryRef = ref(0)
  let initialSourceState =
    sourceManager.sourcesState
    ->Js.Array2.find(s => s.source === sourceManager.activeSource)
    ->Option.getUnsafe
  let sourceStateRef = ref(initialSourceState)
  let shouldUpdateActiveSource = ref(false)

  while responseRef.contents->Option.isNone {
    let sourceState = sourceStateRef.contents
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
      responseRef := Some(response)
    } catch {
    | Source.GetItemsError(error) =>
      switch error {
      | UnsupportedSelection(_)
      | FailedGettingFieldSelection(_) => {
          let nextSourceState =
            sourceManager->getNextSyncSourceState(
              ~initialSourceState,
              ~currentSourceState=sourceState,
              ~isLive,
            )

          // These errors are impossible to recover, so we disable the source
          // so it's not attempted anymore
          let notAlreadyDisabled = disableSource(sourceState)

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

          if nextSourceState === sourceState {
            %raw(`null`)->ErrorHandling.mkLogAndRaise(
              ~logger,
              ~msg="The indexer doesn't have data-sources which can continue fetching. Please, check the error logs or reach out to the Envio team.",
            )
          } else {
            logger->Logging.childInfo({
              "msg": "Switching to another data-source",
              "source": nextSourceState.source.name,
            })
            sourceStateRef := nextSourceState
            shouldUpdateActiveSource := true
            retryRef := 0
          }
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
        let nextSourceState =
          sourceManager->getNextSyncSourceState(
            ~initialSourceState,
            ~currentSourceState=sourceState,
            ~attemptFallbacks=true,
            ~isLive,
          )

        let hasAnotherSource = nextSourceState !== initialSourceState

        logger->Logging.childWarn({
          "msg": message ++ (hasAnotherSource ? " - Attempting to another source" : ""),
          "toBlock": attemptedToBlock,
          "err": exn->Utils.prettifyExn,
        })

        if !hasAnotherSource {
          %raw(`null`)->ErrorHandling.mkLogAndRaise(
            ~logger,
            ~msg="The indexer doesn't have data-sources which can continue fetching. Please, check the error logs or reach out to the Envio team.",
          )
        } else {
          sourceStateRef := nextSourceState
          shouldUpdateActiveSource := false
          retryRef := 0
        }

      | FailedGettingItems({exn, attemptedToBlock, retry: WithBackoff({message, backoffMillis})}) =>
        // Starting from the 11th failure (retry=10)
        // include fallback sources for switch
        // (previously it would consider only sync sources or the initial one)
        // This is a little bit tricky to find the right number,
        // because meaning between RPC and HyperSync is different for the error
        // but since Fallback was initially designed to be used only for height check
        // just keep the value high
        let attemptFallbacks = retry >= 10

        let nextSourceState = switch retry {
        // Don't attempt a switch on first two failure
        | 0 | 1 => sourceState
        | _ =>
          // Then try to switch every second failure
          if retry->mod(2) === 0 {
            sourceManager->getNextSyncSourceState(
              ~initialSourceState,
              ~attemptFallbacks,
              ~currentSourceState=sourceState,
              ~isLive,
            )
          } else {
            sourceState
          }
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

        let shouldSwitch = nextSourceState !== sourceState
        if shouldSwitch {
          logger->Logging.childInfo({
            "msg": "Switching to another data-source",
            "source": nextSourceState.source.name,
          })
          sourceStateRef := nextSourceState
          shouldUpdateActiveSource := true
        } else {
          await Utils.delay(Pervasives.min(backoffMillis, 60_000))
        }
        retryRef := retryRef.contents + 1
      }

    // TODO: Handle more error cases and hang/retry instead of throwing
    | exn => exn->ErrorHandling.mkLogAndRaise(~logger, ~msg="Failed to fetch block Range")
    }
  }

  if shouldUpdateActiveSource.contents {
    sourceManager.activeSource = sourceStateRef.contents.source
    sourceManager->onActiveSourceChanged(~isLive)
  }

  // Attempt recovery from fallback to primary after timeout
  switch sourceManager.fallbackSwitchTimestamp {
  | Some(switchedAt)
    if Js.Date.now() -. switchedAt >=
      sourceManager.fallbackRecoveryTimeout->Int.toFloat =>
    switch sourceManager->getFirstPrimarySourceState(~isLive) {
    | Some(primarySourceState) =>
      let logger = Logging.createChild(
        ~params={
          "chainId": sourceManager.activeSource.chain->ChainMap.Chain.toChainId,
        },
      )
      logger->Logging.childInfo({
        "msg": "Attempting to switch back to primary source after fallback recovery period",
        "source": primarySourceState.source.name,
        "previousSource": sourceManager.activeSource.name,
      })
      sourceManager.activeSource = primarySourceState.source
      sourceManager->onActiveSourceChanged(~isLive)
    | None => ()
    }
  | _ => ()
  }

  responseRef.contents->Option.getUnsafe
}
