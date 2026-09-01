type sourceManagerStatus = Idle | WaitingForNewBlock | Querying

// Cumulative per-method request count/time for a source, aggregated from the
// requestStat arrays returned by its methods. Rendered into
// envio_source_request_* by Metrics.renderSourceRequests.
type requestStatAgg = {mutable count: int, mutable seconds: float}

type sourceState = {
  source: Source.t,
  feed: HeightFeed.t,
  mutable disabled: bool,
  // Timestamp (ms) when this source last failed during executeQuery.
  // Used to decide when to attempt recovery to this source.
  mutable lastFailedAt: option<float>,
  requestStats: dict<requestStatAgg>,
}

let recordStatsInto = (
  aggregates: dict<requestStatAgg>,
  requestStats: array<Source.requestStat>,
) => {
  requestStats->Array.forEach(({method, seconds}) => {
    switch aggregates->Utils.Dict.dangerouslyGetNonOption(method) {
    | Some(agg) =>
      agg.count = agg.count + 1
      agg.seconds = agg.seconds +. seconds
    | None => aggregates->Dict.set(method, {count: 1, seconds})
    }
  })
}

let recordRequestStats = (sourceState: sourceState, requestStats: array<Source.requestStat>) =>
  sourceState.requestStats->recordStatsInto(requestStats)

// Flattened (source, method) aggregates for Metrics.renderSourceRequests to
// inline into the /metrics response.
type requestStatSample = {
  sourceName: string,
  chainId: ChainId.t,
  method: string,
  count: int,
  seconds: float,
}

// Encapsulates the fetching logic for a chain's sources.
// with a mutable state for easier reasoning and testing.
type t = {
  sourcesState: array<sourceState>,
  mutable statusStart: Performance.timeRef,
  mutable status: sourceManagerStatus,
  // Cumulative time spent in each status, rendered into the
  // envio_indexing_idle/source_waiting/source_querying_seconds counters.
  mutable idleSeconds: float,
  mutable waitingForNewBlockSeconds: float,
  mutable queryingSeconds: float,
  newBlockStallTimeout: int,
  newBlockStallTimeoutRealtime: int,
  stalledPollingInterval: int,
  reducedPollingInterval: int,
  mutable activeSource: Source.t,
  mutable waitingForNewBlockStateId: option<int>,
  // Dedupes the "waiting for new blocks" trace so it fires once per contiguous
  // wait period instead of on every epoch that re-enters the wait before any
  // new block is found. Reset when blocks are found.
  mutable waitingLogged: bool,
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

let getRequestStatSamples = (sourceManager: t): array<requestStatSample> => {
  let samples = []
  sourceManager.sourcesState->Array.forEach(sourceState => {
    let chainId = sourceState.source.chainId
    sourceState.requestStats->Utils.Dict.forEachWithKey((agg, method) => {
      samples
      ->Array.push({
        sourceName: sourceState.source.name,
        chainId,
        method,
        count: agg.count,
        seconds: agg.seconds,
      })
      ->ignore
    })
  })
  samples
}

// Per-source known heights for envio_source_known_height. Sources with no
// observed height yet are skipped.
type sourceHeightSample = {
  sourceName: string,
  chainId: ChainId.t,
  height: int,
}

let getSourceHeightSamples = (sourceManager: t): array<sourceHeightSample> => {
  let samples = []
  sourceManager.sourcesState->Array.forEach(sourceState => {
    let knownHeight = sourceState.feed->HeightFeed.knownHeight
    if knownHeight > 0 {
      samples->Array.push({
        sourceName: sourceState.source.name,
        chainId: sourceState.source.chainId,
        height: knownHeight,
      })
    }
  })
  samples
}

// Per-source height subscription health for envio_source_height_stream_*.
// Every source a wait has asked for a stream is reported, including one whose
// stream has never come up — that is a stream nothing else would say anything
// about. A source that was never asked is skipped, so a chain that only ever
// polls renders none of it rather than sitting at zero on it.
type heightStreamSample = {
  sourceName: string,
  chainId: ChainId.t,
  stream: HeightFeed.streamSample,
}

let getHeightStreamSamples = (sourceManager: t): array<heightStreamSample> => {
  let samples = []
  sourceManager.sourcesState->Array.forEach(sourceState =>
    switch sourceState.feed->HeightFeed.sample {
    | Some(stream) =>
      samples->Array.push({
        sourceName: sourceState.source.name,
        chainId: sourceState.source.chainId,
        stream,
      })
    | None => ()
    }
  )
  samples
}

// Each accessor adds the in-progress interval of the current status, so a
// scrape during a long idle/wait/query isn't stale until the next transition.
let idleSeconds = (sourceManager: t) =>
  sourceManager.idleSeconds +.
  switch sourceManager.status {
  | Idle => sourceManager.statusStart->Performance.secondsSince
  | _ => 0.
  }

let waitingForNewBlockSeconds = (sourceManager: t) =>
  sourceManager.waitingForNewBlockSeconds +.
  switch sourceManager.status {
  | WaitingForNewBlock => sourceManager.statusStart->Performance.secondsSince
  | _ => 0.
  }

let queryingSeconds = (sourceManager: t) =>
  sourceManager.queryingSeconds +.
  switch sourceManager.status {
  | Querying => sourceManager.statusStart->Performance.secondsSince
  | _ => 0.
  }

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
    "msg": `HyperSync source is rate-limited - not critical, the indexer will retry in ${(waitMs / 1000)
        ->Int.toString}s. For higher limits upgrade your plan at https://envio.dev/app/api-tokens.`,
    "retry": retry,
    "waitMs": waitMs,
  })
  sourceManager->startRateLimitTimeout(~resetMs=waitMs)
  await Utils.delay(waitMs)
  sourceManager->stopRateLimitTimeout
}

// A response is trusted only after its BlockStore has proved that it is
// internally coherent. `requiredBlockNumbers` is used by getBlockHashes to
// reject a response that simply omitted one of the requested hashes.
let validateResponseBlockStore = (
  ~method: string,
  ~blockStore: BlockStore.t,
  ~requiredBlockNumbers: array<int>=[],
) => {
  switch blockStore->BlockStore.responseConflict->Null.toOption {
  | Some({blockNumber, storedHash, receivedHash}) =>
    throw(
      Source.InconsistentResponse({
        method,
        blockNumber: Some(blockNumber),
        storedHash: Some(storedHash),
        receivedHash: Some(receivedHash),
        missingBlockNumbers: [],
      }),
    )
  | None =>
    let missingBlockNumbers = blockStore->BlockStore.missingHashes(requiredBlockNumbers)
    if missingBlockNumbers->Array.length > 0 {
      throw(
        Source.InconsistentResponse({
          method,
          blockNumber: None,
          storedHash: None,
          receivedHash: None,
          missingBlockNumbers,
        }),
      )
    }
  }
}

let onReorg = (sourceManager: t) => {
  sourceManager.sourcesState->Array.forEach(({source}) => {
    switch source.onReorg {
    | Some(cb) => cb()
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
  {
    sourcesState: sources->Array.map(source => {
      let requestStats = Dict.make()
      {
        source,
        feed: HeightFeed.make(
          ~source,
          ~recordRequestStats=stats => requestStats->recordStatsInto(stats),
          ~getHeightRetryInterval,
        ),
        disabled: false,
        lastFailedAt: None,
        requestStats,
      }
    }),
    activeSource: initialActiveSource,
    waitingForNewBlockStateId: None,
    waitingLogged: false,
    fetchingPartitionsCount: 0,
    newBlockStallTimeout,
    newBlockStallTimeoutRealtime,
    stalledPollingInterval,
    reducedPollingInterval,
    recoveryTimeout,
    statusStart: Performance.now(),
    status: Idle,
    idleSeconds: 0.,
    waitingForNewBlockSeconds: 0.,
    queryingSeconds: 0.,
    hasRealtime,
    committedRateLimitTimeMs: 0.0,
    rateLimitWaiters: 0,
    activeRateLimitStartMs: None,
    activeRateLimitResetAtMs: None,
  }
}

let trackNewStatus = (sourceManager: t, ~newStatus) => {
  let elapsed = sourceManager.statusStart->Performance.secondsSince
  switch sourceManager.status {
  | Idle => sourceManager.idleSeconds = sourceManager.idleSeconds +. elapsed
  | WaitingForNewBlock =>
    sourceManager.waitingForNewBlockSeconds = sourceManager.waitingForNewBlockSeconds +. elapsed
  | Querying => sourceManager.queryingSeconds = sourceManager.queryingSeconds +. elapsed
  }
  sourceManager.statusStart = Performance.now()
  sourceManager.status = newStatus
}

// Carry out the fetch decision made by CrossChainState.checkAndFetch: either
// dispatch the admitted queries or start waiting for a new block. Selection
// (getNextQuery + cross-chain admission) happens upstream so the budget is split
// per query across all chains.
let dispatch = async (
  sourceManager: t,
  ~fetchState: FetchState.t,
  ~executeQuery,
  ~waitForNewBlock,
  ~onNewBlock,
  ~action: FetchState.nextQuery,
  ~stateId,
) => {
  switch action {
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
      // Queries are already marked in flight by ChainState.startFetchingQueries
      // when they were admitted; here we just execute them.
      sourceManager.fetchingPartitionsCount =
        sourceManager.fetchingPartitionsCount + queries->Array.length
      sourceManager->trackNewStatus(~newStatus=Querying)
      let _ = await queries
      ->Array.map(q => {
        let promise = q->executeQuery
        let _ = promise->Promise.thenResolve(_ => {
          sourceManager.fetchingPartitionsCount = sourceManager.fetchingPartitionsCount - 1
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

let disableSource = (sourceManager: t, sourceState: sourceState) => {
  if !sourceState.disabled {
    sourceState.disabled = true
    sourceState.feed->HeightFeed.stop
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
    // All primaries in recovery - sort by oldest lastFailedAt (closest to recovery first)
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

let maxRetryBackoffMillis = 60_000

// One schedule for every retry of the same request, whatever made it fail:
// 100ms doubling up to the cap. `backoffBeforeRetry` still applies the caller's
// floor and the cap on top.
let retryBackoffMillis = retry =>
  Utils.expBackoff(~base=100, ~exp=retry, ~maxMillis=maxRetryBackoffMillis)

// Floor for the retries driven by a condition the source reported itself
// (behind the head, inconsistent response). Unlike a caller-supplied backoff of
// 0, these must never busy-loop when there is no other source to move to.
let minRecoverableBackoffMillis = 50

// Back off before retrying the same request, failing the source over first when
// another one can actually take over. Marking `lastFailedAt` only demotes this
// source in the selection order - with no working alternative the next attempt
// lands right back here, so `minBackoffMillis` is what keeps a retry loop that
// never changes source from spinning at full speed.
let backoffBeforeRetry = async (
  sourceManager: t,
  sourceState: sourceState,
  ~retry,
  ~isRealtime,
  ~backoffMillis,
  ~minBackoffMillis=0,
  ~excludedSources=?,
) => {
  // Give the source two attempts before demoting it, then re-try a failover
  // every second attempt.
  let switchedToWorkingSource = if retry >= 2 && retry->mod(2) === 0 {
    let now = Date.now()
    sourceState.lastFailedAt = Some(now)
    switch sourceManager->getNextSource(~isRealtime, ~excludedSources?) {
    | Some(next) =>
      switch next.lastFailedAt {
      | None => true
      | Some(failedAt) => now -. failedAt >= sourceManager.recoveryTimeout
      }
    | None => false
    }
  } else {
    false
  }
  if switchedToWorkingSource {
    // The next attempt goes to a different source, which is progress on its
    // own - only pace it when the caller asked for a floor.
    if minBackoffMillis > 0 {
      await Utils.delay(minBackoffMillis)
    }
  } else {
    await Utils.delay(
      backoffMillis->Pervasives.max(minBackoffMillis)->Pervasives.min(maxRetryBackoffMillis),
    )
  }
}

// The queried block hasn't reached the backend instance that served the
// request. Expected around the head of a load-balanced backend, so early
// attempts stay quiet and short; a source that stays behind fails over like any
// other. Shared by every ecosystem's getItems and getBlockHashes.
let retryBehindHead = async (
  sourceManager: t,
  sourceState: sourceState,
  ~retry,
  ~isRealtime,
  ~logger: Pino.t,
  ~blockNumber: int,
  ~method: string,
  ~err: exn,
  ~excludedSources=?,
) => {
  let backoffMillis = retry->retryBackoffMillis
  let log = retry >= 4 ? Logging.childWarn : Logging.childTrace
  logger->log({
    "msg": `Block #${blockNumber->Int.toString} is not available on the ${sourceState.source.name} source yet. Instances of a load-balanced backend drift slightly around the head, so this is expected - indexing continues after an automatic retry.`,
    "method": method,
    "retry": retry,
    "backOffMilliseconds": backoffMillis,
    "err": err->Utils.prettifyExn,
  })
  await sourceManager->backoffBeforeRetry(
    sourceState,
    ~retry,
    ~isRealtime,
    ~backoffMillis,
    ~minBackoffMillis=minRecoverableBackoffMillis,
    ~excludedSources?,
  )
}

// A source that keeps contradicting itself is not mid-reorg, it is broken, and
// no amount of retrying moves the chain forward. Roughly five minutes of the
// backoff schedule below.
let inconsistentResponseStallRetries = 13

// The response contradicted itself (the same block twice with different hashes,
// or a requested hash missing). It may be a reorg mid-request, so refetch before
// concluding anything about the chain.
let retryInconsistentResponse = async (
  sourceManager: t,
  sourceState: sourceState,
  ~retry,
  ~isRealtime,
  ~logger: Pino.t,
  ~method: string,
  ~err: exn,
  ~excludedSources=?,
) => {
  let backoffMillis = retry->retryBackoffMillis
  let msg = `Received a partial indicator of a possible reorg from the ${sourceState.source.name} source while fetching ${method}. Retrying the request to better identify whether a reorg happened.`
  let (log, msg) = if retry >= inconsistentResponseStallRetries {
    (
      Logging.childError,
      msg ++ " It has disagreed with itself on every attempt for several minutes now, so this chain has stopped making progress - the endpoint is likely serving blocks and logs from nodes on different chains.",
    )
  } else {
    (retry >= 2 ? Logging.childWarn : Logging.childTrace, msg)
  }
  logger->log({
    "msg": msg,
    "method": method,
    "retry": retry,
    "backOffMilliseconds": backoffMillis,
    "err": err->Utils.prettifyExn,
  })
  // Before the backoff, not after: local state may point at an orphaned chain,
  // and a sibling query on this source would keep reading it for as long as the
  // wait lasts.
  sourceState.source.onReorg->Option.forEach(cb => cb())
  await sourceManager->backoffBeforeRetry(
    sourceState,
    ~retry,
    ~isRealtime,
    ~backoffMillis,
    ~minBackoffMillis=minRecoverableBackoffMillis,
    ~excludedSources?,
  )
}

// Polls for a block height greater than the given block number to ensure a new block is available for indexing.
/*
Resolves at the first height above `knownHeight` that any eligible source
reports. A waiter is registered per source and the first one to fire wins,
cancelling the rest.
*/
let waitForNewBlock = (sourceManager: t, ~knownHeight, ~isRealtime, ~reducedPolling) => {
  let {sourcesState} = sourceManager

  let logger = Logging.createChild(
    ~params={
      "chainId": sourceManager.activeSource.chainId,
      "knownHeight": knownHeight,
    },
  )
  if !sourceManager.waitingLogged {
    logger->Logging.childTrace(
      reducedPolling
        ? `Waiting for new blocks with reduced polling (${(sourceManager.reducedPollingInterval / 1000)
              ->Int.toString}s). Chain is caught up, waiting for other chains to backfill.`
        : "Initiating check for new blocks.",
    )
    sourceManager.waitingLogged = true
  }

  let mainSources = sourceManager->getNextSources(~isRealtime)

  // Whether this wait has already run out its stall window. It only changes the
  // cadence the sources poll at and the level the closing line is logged at.
  let stalled = ref(false)

  // Use a much longer stall timeout when reduced polling is active
  // to avoid spurious stall warnings while waiting for other chains to backfill
  let stallTimeout = if reducedPolling {
    sourceManager.reducedPollingInterval * 2
  } else if isRealtime {
    sourceManager.newBlockStallTimeoutRealtime
  } else {
    sourceManager.newBlockStallTimeout
  }

  Promise.make((resolve, _reject) => {
    // Every waiter this wait holds, on primaries and on any fallback recruited
    // later, so a stall reaches all of them.
    let watched: array<HeightFeed.subscription> = []
    let pokeTimeoutId = ref(None)
    let stallTimeoutId = ref(None)

    // Safe to repeat: unsubscribing twice removes a waiter that is already gone.
    let cleanup = () => {
      watched->Array.forEach(subscription => subscription.unsubscribe())
      watched->Utils.Array.clearInPlace
      pokeTimeoutId->Utils.clearTimeoutRef
      stallTimeoutId->Utils.clearTimeoutRef
    }

    let settled = ref(false)
    let settle = (source: Source.t, height) =>
      if !settled.contents {
        settled := true
        // Before anything else: the sources still watching have no reason to
        // keep polling for a height this wait already has.
        cleanup()
        sourceManager.activeSource = source
        // Show a higher level log if we displayed a warning/error after newBlockStallTimeout
        let log = stalled.contents ? Logging.childInfo : Logging.childTrace
        logger->log({
          "msg": `New blocks successfully found.`,
          "source": source.name,
          "newBlockHeight": height,
        })
        sourceManager.waitingLogged = false
        resolve(height)
      }

    // Registering can answer the wait on the spot, from a height the source
    // already knew, so every site has to cope with the wait being over — either
    // before it got here, or because of its own call. Handled once here rather
    // than at each place that registers.
    let watch = (sourceState: sourceState, ~withStream) =>
      if !settled.contents {
        if withStream {
          // Lazy and explicit: a source that can push heights subscribes when a
          // realtime wait starts wanting them, and not before. A stream outlives
          // the wait that asked for it and nothing takes it back off, so only the
          // sources this wait was built on ask for one — a source recruited
          // because another stalled is here to poll, and would otherwise hold a
          // connection open for the life of the process on the strength of one
          // stall.
          sourceState.feed->HeightFeed.enableStream
        }
        let subscription = sourceState.feed->HeightFeed.onHeightAbove(
          ~knownHeight,
          // Read per poll rather than captured, so a wait that goes on to stall
          // slows its own polling down without anything having to restart it.
          ~interval=() =>
            if reducedPolling {
              sourceManager.reducedPollingInterval
            } else if stalled.contents {
              sourceManager.stalledPollingInterval
            } else {
              sourceState.source.pollingInterval
            },
          ~onHeight=height => settle(sourceState.source, height),
        )
        if settled.contents {
          // This registration is what answered the wait, and the cleanup that ran
          // inside it could not reach a subscription it had not returned yet.
          subscription.unsubscribe()
        } else {
          watched->Array.push(subscription)->ignore
        }
      }

    mainSources->Array.forEach(sourceState => sourceState->watch(~withStream=isRealtime))

    if !settled.contents {
      // Spread across the window, and re-spread on every repeat: every indexer on
      // one provider goes quiet in the same instant that provider does, and
      // putting them all on one schedule is how a quiet chain becomes a stampede.
      // Re-armed because distrusting a stream is a one-shot — the next height it
      // delivers takes it back at its word — and the silence that earned it can
      // come straight back.
      let rec armPokeTimeout = () =>
        pokeTimeoutId := Some(setTimeout(() => {
              pokeTimeoutId := None
              if !settled.contents {
                watched->Array.forEach(subscription => subscription.distrustStream())
              }

              // Re-checked: distrusting can answer the wait, and a timer armed
              // after the cleanup that follows is one nothing can ever clear.
              if !settled.contents {
                armPokeTimeout()
              }
            }, Utils.jitter(stallTimeout)))

      // Punctual, unlike the poke it used to share a timer with:
      // newBlockStallTimeout is a promise to the operator about when they hear
      // about a quiet chain, and spreading that would report it early. Fires once
      // — the warning is worth saying once per wait, and a fallback stays
      // recruited.
      let armStallTimeout = () =>
        stallTimeoutId := Some(setTimeout(() => {
              stallTimeoutId := None
              if !settled.contents {
                stalled := true

                // Build fallback: non-disabled sources not in mainSources with a valid role, even with recent lastFailedAt
                let fallbackSources = []
                sourcesState->Array.forEach(
                  sourceState => {
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
                  },
                )

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

                // Recruited to poll, not to stream: see `watch`.
                fallbackSources->Array.forEach(
                  sourceState => sourceState->watch(~withStream=false),
                )

                // A fallback recruited here can still be holding a stream from an
                // earlier wait that made it a primary, and a live stream is not
                // polled behind. It has to inherit the verdict the primaries
                // already earned — this wait has heard nothing for a whole window
                // — or it would sit silent behind that stream until the next
                // spread poke. Distrusting a waiter that already does so is a
                // no-op, so this reaches the new ones only.
                if !settled.contents {
                  watched->Array.forEach(subscription => subscription.distrustStream())
                }
              }
            }, stallTimeout))

      armPokeTimeout()
      armStallTimeout()
    }
  })
}


let executeQuery = async (
  sourceManager: t,
  ~query: FetchState.query,
  ~knownHeight,
  ~isRealtime,
) => {
  let noSourcesError = "The indexer doesn't have data-sources which can continue fetching. Please, check the error logs or reach out to the Envio team."

  // Sources where the query is impossible - lazily allocated, excluded for the duration of this query
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
        let logger = Logging.createChild(~params={"chainId": sourceManager.activeSource.chainId})
        logger->Logging.childInfo({
          "msg": "Switching data-source",
          "source": s.source.name,
          "previousSource": sourceManager.activeSource.name,
          "fromBlock": query.fromBlock,
        })
      }
      s
    | None =>
      let logger = Logging.createChild(~params={"chainId": sourceManager.activeSource.chainId})
      %raw(`null`)->ErrorHandling.mkLogAndRaise(~logger, ~msg=noSourcesError)
    }
    sourceManager.activeSource = sourceState.source
    let source = sourceState.source
    let toBlock = toBlockRef.contents
    let retry = retryRef.contents

    let logger = Logging.createChild(
      ~params={
        "chainId": source.chainId,
        "logType": "Block Range Query",
        "partitionId": query.partitionId,
        "source": source.name,
        "fromBlock": query.fromBlock,
        "toBlock": toBlock,
        "addresses": query.addresses->AddressSet.size,
        "retry": retry,
      },
    )

    try {
      let response = await source.getItemsOrThrow(
        ~fromBlock=query.fromBlock,
        ~toBlock,
        ~addressSet=query.addresses,
        ~partitionId=query.partitionId,
        ~knownHeight,
        ~selection=query.selection->FetchState.narrowSelectionToRange(~toBlock),
        ~itemsTarget=query.itemsTarget,
        ~retry,
        ~logger,
      )
      sourceState->recordRequestStats(response.requestStats)
      validateResponseBlockStore(~method="getItems", ~blockStore=response.blockStore)
      sourceState.lastFailedAt = None

      // The response carries a fresh height for exactly this source, so during a
      // long backfill (when nothing is waiting on the feed) it keeps the
      // per-source envio_source_known_height current — and if a wait is in
      // flight, a height learned this way can settle it.
      sourceState.feed->HeightFeed.recordHeight(response.knownHeight)
      responseRef := Some(response)
    } catch {
    | Source.RateLimited({resetMs, requestStats}) =>
      sourceState->recordRequestStats(requestStats)
      await sourceManager->waitForRateLimitReset(~resetMs, ~retry, ~logger)
      retryRef := retryRef.contents + 1

    | Source.SourceBehindHead({blockNumber, requestStats}) as err =>
      sourceState->recordRequestStats(requestStats)
      await sourceManager->retryBehindHead(
        sourceState,
        ~retry,
        ~isRealtime,
        ~logger,
        ~blockNumber,
        ~method="getItems",
        ~err,
        ~excludedSources=?excludedSourcesRef.contents,
      )
      retryRef := retryRef.contents + 1

    | Source.InconsistentResponse(_) as err =>
      await sourceManager->retryInconsistentResponse(
        sourceState,
        ~retry,
        ~isRealtime,
        ~logger,
        ~method="getItems",
        ~err,
        ~excludedSources=?excludedSourcesRef.contents,
      )
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
        // Don't set lastFailedAt - the source isn't broken, the query just can't work on it
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
        await sourceManager->backoffBeforeRetry(
          sourceState,
          ~retry,
          ~isRealtime,
          ~backoffMillis,
          ~excludedSources=?excludedSourcesRef.contents,
        )
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
      let logger = Logging.createChild(~params={"chainId": sourceManager.activeSource.chainId})
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
        "chainId": source.chainId,
        "logType": "Block Hash Query",
        "source": source.name,
        "retry": retry,
      },
    )

    try {
      let res = await source.getBlockHashes(~blockNumbers, ~logger)
      sourceState->recordRequestStats(res.requestStats)
      switch res.result {
      | Ok(data) =>
        validateResponseBlockStore(
          ~method="getBlockHashes",
          ~blockStore=data,
          ~requiredBlockNumbers=blockNumbers,
        )
        sourceState.lastFailedAt = None
        responseRef := Some(data)
      | Error(exn) => throw(exn)
      }
    } catch {
    | Source.RateLimited({resetMs, requestStats}) =>
      sourceState->recordRequestStats(requestStats)
      await sourceManager->waitForRateLimitReset(~resetMs, ~retry, ~logger)
      retryRef := retryRef.contents + 1

    | Source.SourceBehindHead({blockNumber, requestStats}) as err =>
      sourceState->recordRequestStats(requestStats)
      await sourceManager->retryBehindHead(
        sourceState,
        ~retry,
        ~isRealtime,
        ~logger,
        ~blockNumber,
        ~method="getBlockHashes",
        ~err,
      )
      retryRef := retryRef.contents + 1

    | Source.InconsistentResponse(_) as err =>
      await sourceManager->retryInconsistentResponse(
        sourceState,
        ~retry,
        ~isRealtime,
        ~logger,
        ~method="getBlockHashes",
        ~err,
      )
      retryRef := retryRef.contents + 1

    | exn =>
      let backoffMillis = retry->retryBackoffMillis
      let log = retry >= 4 ? Logging.childWarn : Logging.childTrace
      logger->log({
        "msg": "Failed to fetch block hashes. Retrying.",
        "retry": retry,
        "backOffMilliseconds": backoffMillis,
        "err": exn->Utils.prettifyExn,
      })
      await sourceManager->backoffBeforeRetry(
        sourceState,
        ~retry,
        ~isRealtime,
        ~backoffMillis,
        ~minBackoffMillis=minRecoverableBackoffMillis,
      )
      retryRef := retryRef.contents + 1
    }
  }

  responseRef.contents->Option.getUnsafe
}
