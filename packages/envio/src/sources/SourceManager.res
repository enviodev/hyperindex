type sourceManagerStatus = Idle | WaitingForNewBlock | Querying

// Cumulative per-method request stats for a source, aggregated from the
// requestStat arrays returned by its methods. Rendered into the
// envio_source_request_* and envio_source_response_* metrics.
type requestStatAgg = {
  mutable count: int,
  mutable seconds: float,
  mutable responseBlocks: option<int>,
  mutable emptyResponseCount: int,
}

// Whether a source takes queries. A failing source is given another try once
// the recovery timeout passes. A source that stopped following its chain isn't:
// a timeout would hand it queries back every time it ran out, for as long as
// the indexer runs. It is held until its own height moves back near the head.
type health =
  | Working
  | Recovering({failedAt: float})
  // `failedAt` is when it last failed a query it was asked as the last resort.
  | Held({release: HeightFeed.subscription, failedAt: option<float>})

type sourceState = {
  source: Source.t,
  feed: HeightFeed.t,
  mutable disabled: bool,
  mutable health: health,
  requestStats: dict<requestStatAgg>,
}

let recordStatsInto = (
  aggregates: dict<requestStatAgg>,
  requestStats: array<Source.requestStat>,
) => {
  requestStats->Array.forEach(({method, seconds, ?responseBlocks}) => {
    let agg = switch aggregates->Utils.Dict.dangerouslyGetNonOption(method) {
    | Some(agg) => agg
    | None =>
      let agg = {count: 0, seconds: 0., responseBlocks: None, emptyResponseCount: 0}
      aggregates->Dict.set(method, agg)
      agg
    }
    agg.count = agg.count + 1
    agg.seconds = agg.seconds +. seconds
    switch responseBlocks {
    | Some(responseBlocks) =>
      agg.responseBlocks = Some(agg.responseBlocks->Option.getOr(0) + responseBlocks)
      if responseBlocks === 0 {
        agg.emptyResponseCount = agg.emptyResponseCount + 1
      }
    | None => ()
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
  responseBlocks: option<int>,
  emptyResponseCount: int,
}

// Encapsulates the fetching logic for a chain's sources.
// with a mutable state for easier reasoning and testing.
type t = {
  sourcesState: array<sourceState>,
  logger: Logger.t,
  mutable statusStart: Clock.timeRef,
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
  // The source the last items query went to. Unlike `activeSource`, a wait
  // answered by another source leaves it alone, so "Switching data-source" is
  // said when queries actually move.
  mutable queriedSource: Source.t,
  mutable waitingForNewBlockStateId: option<int>,
  // Dedupes the "waiting for new blocks" trace so it fires once per contiguous
  // wait period instead of on every epoch that re-enters the wait before any
  // new block is found. Reset when blocks are found.
  mutable waitingLogged: bool,
  // Includes requests still out for a state before a rollback.
  mutable requestsInFlight: int,
  recoveryTimeout: float,
  clock: Clock.t,
  // Why a source was last disabled for good. A disabled source is never
  // retried, so by the time the manager runs out of sources this is the reason
  // it did — and the only thing that tells a caller what to change.
  mutable disableReason: option<string>,
  mutable hasRealtime: bool,
  mutable committedRateLimitTimeMs: float,
  mutable rateLimitWaiters: int,
  // When the current rate-limit window started on `clock`, or None if not
  // currently waiting.
  mutable activeRateLimitStartMs: option<float>,
  // Timestamp on `clock` by which the server expects the longest current
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
        responseBlocks: agg.responseBlocks,
        emptyResponseCount: agg.emptyResponseCount,
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
  | Idle => sourceManager.clock->Clock.secondsSince(sourceManager.statusStart)
  | _ => 0.
  }

let waitingForNewBlockSeconds = (sourceManager: t) =>
  sourceManager.waitingForNewBlockSeconds +.
  switch sourceManager.status {
  | WaitingForNewBlock => sourceManager.clock->Clock.secondsSince(sourceManager.statusStart)
  | _ => 0.
  }

let queryingSeconds = (sourceManager: t) =>
  sourceManager.queryingSeconds +.
  switch sourceManager.status {
  | Querying => sourceManager.clock->Clock.secondsSince(sourceManager.statusStart)
  | _ => 0.
  }

// Item requests currently in flight on this chain's sources.
let inFlightCount = sourceManager => sourceManager.requestsInFlight

let getRateLimitTimeMs = sourceManager =>
  sourceManager.committedRateLimitTimeMs +.
  switch sourceManager.activeRateLimitStartMs {
  | Some(startMs) => sourceManager.clock.now() -. startMs
  | None => 0.0
  }

let getRateLimitResetInMs = sourceManager =>
  switch sourceManager.activeRateLimitResetAtMs {
  | Some(resetAt) =>
    let remaining = resetAt -. sourceManager.clock.now()
    remaining > 0.0 ? Some(remaining) : None
  | None => None
  }

let startRateLimitTimeout = (sourceManager, ~resetMs) => {
  let now = sourceManager.clock.now()
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
        sourceManager.committedRateLimitTimeMs +. sourceManager.clock.now() -. startMs
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
  let level = retry >= 2 ? #warn : #trace
  logger->Logger.logAt(
    level,
    `HyperSync source is rate-limited - not critical, the indexer will retry in ${(waitMs / 1000)
        ->Int.toString}s. For higher limits upgrade your plan at https://envio.dev/app/api-tokens.`,
    ~params={"retry": retry, "waitMs": waitMs},
  )
  sourceManager->startRateLimitTimeout(~resetMs=waitMs)
  await sourceManager.clock->Clock.delay(~label="rate-limit reset", waitMs)
  sourceManager->stopRateLimitTimeout
}

// A response is trusted only after its page has proved that it is
// internally coherent. `requiredBlockNumbers` is used by getBlockHashes to
// reject a response that simply omitted one of the requested hashes.
// A page that contradicts itself: the same block with two hashes, or a
// requested hash missing.
type inconsistency = {
  method: string,
  blockNumber: option<int>,
  storedHash: option<string>,
  receivedHash: option<string>,
  missingBlockNumbers: array<int>,
}

let validateResponsePage = (
  ~method: string,
  ~page: BufferPage.t,
  ~requiredBlockNumbers: array<int>=[],
): option<inconsistency> =>
  switch page->BufferPage.responseConflict->Null.toOption {
  | Some({blockNumber, storedHash, receivedHash}) =>
    Some({
      method,
      blockNumber: Some(blockNumber),
      storedHash: Some(storedHash),
      receivedHash: Some(receivedHash),
      missingBlockNumbers: [],
    })
  | None =>
    switch page->BufferPage.missingHashes(requiredBlockNumbers) {
    | [] => None
    | missingBlockNumbers =>
      Some({method, blockNumber: None, storedHash: None, receivedHash: None, missingBlockNumbers})
    }
  }

// The provider's own words about a failure, logged as an error object so a
// log line shows its message the same way whichever source it came from.
let causeError = (cause: string) => JsError.make(cause)

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

type timing = {
  newBlockStallTimeout?: int,
  newBlockStallTimeoutRealtime?: int,
  stalledPollingInterval?: int,
  reducedPollingInterval?: int,
  recoveryTimeout?: float,
  getHeightRetryInterval?: (~retry: int) => int,
  heightPollTimeout?: int,
  clock?: Clock.t,
}

let make = (~sources: array<Source.t>, ~logger: Logger.t, ~isRealtime, ~timing: timing={}) => {
  let clock = timing.clock->Option.getOr(Clock.real)
  let newBlockStallTimeout = timing.newBlockStallTimeout->Option.getOr(60_000)
  let newBlockStallTimeoutRealtime = timing.newBlockStallTimeoutRealtime->Option.getOr(20_000)
  let stalledPollingInterval = timing.stalledPollingInterval->Option.getOr(5_000)
  let reducedPollingInterval = timing.reducedPollingInterval->Option.getOr(60_000)
  let recoveryTimeout = timing.recoveryTimeout->Option.getOr(60_000.0)
  let getHeightRetryInterval = switch timing.getHeightRetryInterval {
  | Some(getHeightRetryInterval) => getHeightRetryInterval
  | None =>
    makeGetHeightRetryInterval(
      ~initialRetryInterval=1000,
      ~backoffMultiplicative=2,
      ~maxRetryInterval=60_000,
    )
  }
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
          ~logger,
          ~recordRequestStats=stats => requestStats->recordStatsInto(stats),
          ~getHeightRetryInterval,
          ~pollTimeoutMillis=timing.heightPollTimeout->Option.getOr(60_000),
          ~clock,
        ),
        disabled: false,
        health: Working,
        requestStats,
      }
    }),
    logger,
    activeSource: initialActiveSource,
    queriedSource: initialActiveSource,
    waitingForNewBlockStateId: None,
    waitingLogged: false,
    requestsInFlight: 0,
    newBlockStallTimeout,
    newBlockStallTimeoutRealtime,
    stalledPollingInterval,
    reducedPollingInterval,
    recoveryTimeout,
    clock,
    statusStart: clock->Clock.readTimeRef,
    status: Idle,
    idleSeconds: 0.,
    waitingForNewBlockSeconds: 0.,
    queryingSeconds: 0.,
    disableReason: None,
    hasRealtime,
    committedRateLimitTimeMs: 0.0,
    rateLimitWaiters: 0,
    activeRateLimitStartMs: None,
    activeRateLimitResetAtMs: None,
  }
}

let trackNewStatus = (sourceManager: t, ~newStatus) => {
  let elapsed = sourceManager.clock->Clock.secondsSince(sourceManager.statusStart)
  switch sourceManager.status {
  | Idle => sourceManager.idleSeconds = sourceManager.idleSeconds +. elapsed
  | WaitingForNewBlock =>
    sourceManager.waitingForNewBlockSeconds = sourceManager.waitingForNewBlockSeconds +. elapsed
  | Querying => sourceManager.queryingSeconds = sourceManager.queryingSeconds +. elapsed
  }
  sourceManager.statusStart = sourceManager.clock->Clock.readTimeRef
  sourceManager.status = newStatus
}

// Carries out a chain's share of a fetch tick: runs the requests the plan
// handed out, or waits for a new block.
let dispatch = async (
  sourceManager: t,
  ~knownHeight,
  ~executeQuery,
  ~waitForNewBlock,
  ~onNewBlock,
  ~work: IndexingPlan.chainFetchWork,
  ~stateId,
) =>
  if work.waitForNewBlock {
    switch sourceManager.waitingForNewBlockStateId {
    | Some(waitingStateId) if waitingStateId >= stateId => ()
    | Some(_) // Case for the prev state before a rollback
    | None =>
      sourceManager->trackNewStatus(~newStatus=WaitingForNewBlock)
      sourceManager.waitingForNewBlockStateId = Some(stateId)
      let knownHeight = await waitForNewBlock(~knownHeight)
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
  } else {
    sourceManager.requestsInFlight = sourceManager.requestsInFlight + work.requests->Array.length
    sourceManager->trackNewStatus(~newStatus=Querying)
    let _ = await work.requests
    ->Array.map(request => {
      let promise = request->executeQuery
      let _ = promise->Promise.thenResolve(_ => {
        sourceManager.requestsInFlight = sourceManager.requestsInFlight - 1
        if sourceManager.requestsInFlight === 0 {
          sourceManager->trackNewStatus(~newStatus=Idle)
        }
      })
      promise
    })
    ->Promise.all
  }

// Stops the held source's height poll.
let releaseHold = (sourceState: sourceState) =>
  switch sourceState.health {
  | Held({release}) => release.unsubscribe()
  | Working | Recovering(_) => ()
  }

// Answering clears a recovery but not a hold: a held source can still answer a
// range below where it stopped, or one sent before it was held, and neither
// says it is back near the head. Only its height releases it.
let markAnswered = (sourceState: sourceState) =>
  switch sourceState.health {
  | Recovering(_) => sourceState.health = Working
  | Working | Held(_) => ()
  }

// A held source stays held: failing a query it was only asked as the last
// resort says nothing new about where it is. The time still counts, so the last
// resort moves on to another source.
let markFailed = (sourceState: sourceState, ~now) =>
  switch sourceState.health {
  | Held({release}) => sourceState.health = Held({release, failedAt: Some(now)})
  | Working | Recovering(_) => sourceState.health = Recovering({failedAt: now})
  }

let isWorking = (sourceManager: t, sourceState: sourceState, ~now) =>
  switch sourceState.health {
  | Working => true
  | Recovering({failedAt}) => now -. failedAt >= sourceManager.recoveryTimeout
  | Held(_) => false
  }

// The head as far as this chain's sources have said.
let highestKnownHeight = (sourceManager: t) =>
  sourceManager.sourcesState->Array.reduce(0, (highest, {feed}) =>
    Pervasives.max(highest, feed->HeightFeed.knownHeight)
  )

// Released once its own height moves and lands within the distance the chain
// counts as near the head. Moving at all shows a source that stopped is
// following its chain again, but one resyncing from far behind would only fail
// the queries at the head it is handed. Polls at the reduced interval: nothing
// waits on the source while it is held, and a source that stopped following its
// chain can stay stopped for weeks. Polls behind its height stream too, through
// every drop and reconnect: a source that stopped following its chain is exactly
// the one whose stream can keep its keep-alives flowing while its heights stop,
// and while the fallback answers every wait, nothing else would ever ask it
// again.
let holdUntilCaughtUp = (sourceManager: t, sourceState: sourceState) => {
  let headDistance = Core.getAddon().headDistance()
  let rec hold = (~failedAt) => {
    let subscription = sourceState.feed->HeightFeed.onHeightAbove(
      ~knownHeight=sourceState.feed->HeightFeed.knownHeight,
      ~interval=() => sourceManager.reducedPollingInterval,
      ~pollsBehindStream=true,
      ~onHeight=height =>
        sourceState.health = if sourceManager->highestKnownHeight - height <= headDistance {
          Working
        } else {
          // Still held, and still the failure it had: losing it would rank the
          // source first in the last resort as if it had never failed.
          hold(
            ~failedAt=switch sourceState.health {
            | Held({failedAt}) => failedAt
            | Working | Recovering(_) => None
            },
          )
        },
    )
    Held({release: subscription, failedAt})
  }
  // A query can fail on a source after another one benched it, and nothing
  // would ever stop the poll of a hold taken then.
  switch sourceState.health {
  | Working | Recovering(_) if !sourceState.disabled => sourceState.health = hold(~failedAt=None)
  | Working | Recovering(_) | Held(_) => ()
  }
}

let disableSource = (sourceManager: t, sourceState: sourceState) => {
  if !sourceState.disabled {
    sourceState.disabled = true
    sourceState->releaseHold
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

// The source that failed longest ago first, one that never failed before any.
let lastFailedAt = (sourceState: sourceState) =>
  switch sourceState.health {
  | Working | Held({failedAt: None}) => Float.Constants.negativeInfinity
  | Recovering({failedAt}) | Held({failedAt: Some(failedAt)}) => failedAt
  }

let compareByOldestFailure = (a: sourceState, b: sourceState) =>
  Float.compare(a->lastFailedAt, b->lastFailedAt)

// Priority: working primaries > working secondaries > all primaries > all
// secondaries.
let getNextSources = (sourceManager: t, ~isRealtime, ~excludedSources=?) => {
  let now = sourceManager.clock.now()
  let workingPrimarySources = []
  let allPrimarySources = []
  let workingSecondarySources = []
  let allSecondarySources = []
  for i in 0 to sourceManager.sourcesState->Array.length - 1 {
    let sourceState = sourceManager.sourcesState->Array.getUnsafe(i)
    if !sourceState.disabled {
      let isExcluded = switch excludedSources {
      | Some(set) => set->Utils.Set.has(sourceState)
      | None => false
      }
      if !isExcluded {
        let isWorking = sourceManager->isWorking(sourceState, ~now)
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
        | Some(Secondary) =>
          allSecondarySources->Array.push(sourceState)
          if isWorking {
            workingSecondarySources->Array.push(sourceState)
          }
        | None => ()
        }
      }
    }
  }
  if workingPrimarySources->Array.length > 0 {
    workingPrimarySources
  } else if workingSecondarySources->Array.length > 0 {
    workingSecondarySources
  } else {
    // Nothing is working: the last resort, the source that failed longest ago
    // first. A failing or held secondary is still better than no source at all
    // once every primary is benched.
    let lastResort =
      allPrimarySources->Utils.Array.isEmpty ? allSecondarySources : allPrimarySources
    lastResort->Array.sort(compareByOldestFailure)
    lastResort
  }
}

// Single source selection from getNextSources. Stays on the active source while
// it is working. In the last resort nothing is, and staying would retry the
// same source for as long as it keeps failing while another one might answer.
let getNextSource = (sourceManager, ~isRealtime, ~excludedSources=?) => {
  let sources = sourceManager->getNextSources(~isRealtime, ~excludedSources?)
  let now = sourceManager.clock.now()
  switch sources->Array.find(s =>
    s.source === sourceManager.activeSource && sourceManager->isWorking(s, ~now)
  ) {
  | Some(_) as active => active
  | None => sources->Array.get(0)
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

let sleepBackoff = (sourceManager: t, millis) =>
  sourceManager.clock->Clock.delay(~label="retry backoff", millis)

// Back off before retrying the same request, failing the source over first when
// another one can actually take over. Marking it failed only demotes this
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
  ~failoverAfterRetries=2,
  ~excludedSources=?,
) => {
  // Give the source a few attempts before demoting it, then re-try a failover
  // every second attempt.
  let switchedToWorkingSource = if (
    retry >= failoverAfterRetries && (retry - failoverAfterRetries)->mod(2) === 0
  ) {
    let now = sourceManager.clock.now()
    sourceState->markFailed(~now)
    switch sourceManager->getNextSource(~isRealtime, ~excludedSources?) {
    | Some(next) => sourceManager->isWorking(next, ~now)
    | None => false
    }
  } else {
    false
  }
  if switchedToWorkingSource {
    // The next attempt goes to a different source, which is progress on its
    // own - only pace it when the caller asked for a floor.
    if minBackoffMillis > 0 {
      await sourceManager->sleepBackoff(minBackoffMillis)
    }
  } else {
    await sourceManager->sleepBackoff(
      backoffMillis->Pervasives.max(minBackoffMillis)->Pervasives.min(maxRetryBackoffMillis),
    )
  }
}

// A replica behind its siblings usually catches up within seconds, and failing
// over demotes an otherwise healthy source for the whole recovery timeout. So
// the source keeps the query for about 10s (100ms doubling, capped at 1s per
// attempt) before a failover is tried. Past that window the source is behind
// for real, and with nowhere to fail over to it is polled less and less often,
// doubling from 1s up to the shared cap.
let behindHeadFailoverRetries = 12

let behindHeadBackoffMillis = retry =>
  if retry < behindHeadFailoverRetries {
    Utils.expBackoff(~base=100, ~exp=retry, ~maxMillis=1_000)
  } else {
    Utils.expBackoff(
      ~base=1_000,
      ~exp=retry - behindHeadFailoverRetries,
      ~maxMillis=maxRetryBackoffMillis,
    )
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
  ~logger: Logger.t,
  ~blockNumber: int,
  ~excludedSources=?,
) => {
  let backoffMillis = retry->behindHeadBackoffMillis
  let source = sourceState.source.name
  let block = blockNumber->Int.toString
  // The condition is routine and resolves without the user doing anything, so
  // the wording says so; the error object would only add internals.
  let (level, msg) = if retry < behindHeadFailoverRetries {
    (
      #trace,
      `${source} hasn't reached block ${block} on all of its servers yet. This is normal near the latest block and resolves by itself - retrying shortly.`,
    )
  } else {
    (
      #warn,
      `${source} is still catching up to block ${block}. This is a delay on the provider's side; indexing will continue automatically, using another data source if one is configured.`,
    )
  }
  logger->Logger.logAt(level, msg, ~params={"retry": retry, "backOffMilliseconds": backoffMillis})
  if retry >= behindHeadFailoverRetries {
    sourceManager->holdUntilCaughtUp(sourceState)
  }
  await sourceManager->backoffBeforeRetry(
    sourceState,
    ~retry,
    ~isRealtime,
    ~backoffMillis,
    ~minBackoffMillis=minRecoverableBackoffMillis,
    ~failoverAfterRetries=behindHeadFailoverRetries,
    ~excludedSources?,
  )
}

// A query that has failed this many times running has outlived every failover
// the schedule above can offer: it has rotated through the chain's sources
// several times over and none of them answered. Whatever the reported cause,
// the chain is no longer making progress and the operator has to hear about it.
let stallRetries = 13

// Which level a retry is reported at, and what it says once the retries have
// outlasted the rotation.
let stalledLog = (~retry, ~warnAfter, ~msg, ~stalled) =>
  if retry >= stallRetries {
    (#error, msg ++ stalled)
  } else {
    (retry >= warnAfter ? #warn : #trace, msg)
  }

// The response contradicted itself (the same block twice with different hashes,
// or a requested hash missing). It may be a reorg mid-request, so refetch before
// concluding anything about the chain.
let retryInconsistentResponse = async (
  sourceManager: t,
  sourceState: sourceState,
  ~retry,
  ~isRealtime,
  ~logger: Logger.t,
  ~inconsistency: inconsistency,
  ~excludedSources=?,
) => {
  let backoffMillis = retry->retryBackoffMillis
  let msg = `Received a partial indicator of a possible reorg from the ${sourceState.source.name} source while fetching ${inconsistency.method}. Retrying the request to better identify whether a reorg happened.`
  let (level, msg) = stalledLog(
    ~retry,
    ~warnAfter=2,
    ~msg,
    ~stalled=" It has disagreed with itself on every attempt for several minutes now, so this chain has stopped making progress - the endpoint is likely serving blocks and logs from nodes on different chains.",
  )
  logger->Logger.logAt(
    level,
    msg,
    ~params={
      "method": inconsistency.method,
      "retry": retry,
      "backOffMilliseconds": backoffMillis,
      "err": inconsistency,
    },
  )
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

// The source could not serve the page and reported nothing that changes the
// query, so the only move left is to wait and let the schedule try another
// source. Escalates once the retries have outlasted every failover.
let retryFailedPage = async (
  sourceManager: t,
  sourceState: sourceState,
  ~retry,
  ~isRealtime,
  ~logger: Logger.t,
  ~msg: string,
  ~backoffMillis: int,
  ~minBackoffMillis=0,
  ~cause: option<string>,
  ~excludedSources=?,
) => {
  let (level, msg) = stalledLog(
    ~retry,
    ~warnAfter=4,
    ~msg,
    ~stalled=" No source available to this chain has served this query on any attempt since, so indexing has stopped making progress.",
  )
  logger->Logger.logAt(
    level,
    msg,
    ~params={
      "backOffMilliseconds": backoffMillis,
      "retry": retry,
      "err": cause->Option.map(causeError),
    },
  )
  await sourceManager->backoffBeforeRetry(
    sourceState,
    ~retry,
    ~isRealtime,
    ~backoffMillis,
    ~minBackoffMillis,
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

  let logger = sourceManager.logger->Logger.withFields({
    "knownHeight": knownHeight,
  })
  if !sourceManager.waitingLogged {
    logger->Logger.trace(
      reducedPolling
        ? `Waiting for new blocks with reduced polling (${(sourceManager.reducedPollingInterval / 1000)
              ->Int.toString}s) until the indexer enters realtime mode.`
        : "Initiating check for new blocks.",
    )
    sourceManager.waitingLogged = true
  }

  let mainSources = sourceManager->getNextSources(~isRealtime)

  // Whether this wait has already run out its stall window. It only changes the
  // cadence the sources poll at and the level the closing line is logged at.
  let stalled = ref(false)

  // Use a much longer stall timeout when reduced polling is active, so a chain
  // deliberately asking rarely doesn't report itself stalled between polls.
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
      sourceManager.clock->Clock.clearRef(pokeTimeoutId)
      sourceManager.clock->Clock.clearRef(stallTimeoutId)
    }

    let settled = ref(false)
    let settle = (answered: sourceState, height) =>
      if !settled.contents {
        settled := true
        // Before anything else: the sources still watching have no reason to
        // keep polling for a height this wait already has.
        cleanup()

        // A source recruited because the wait stalled answered it, so the
        // sources the wait was built on heard nothing for a whole window while
        // the chain moved on. One that ends more than a block behind has stopped
        // following its chain: a single block is too little to tell that from a
        // block it hasn't polled yet, and a source with no height has told us
        // nothing either way.
        if stalled.contents && !(mainSources->Array.includes(answered)) {
          mainSources->Array.forEach(sourceState => {
            let ownHeight = sourceState.feed->HeightFeed.knownHeight
            if ownHeight > 0 && height - ownHeight > 1 {
              sourceManager->holdUntilCaughtUp(sourceState)
            }
          })
        }
        let source = answered.source
        sourceManager.activeSource = source
        // Show a higher level log if we displayed a warning/error after newBlockStallTimeout
        let level = stalled.contents ? #info : #trace
        logger->Logger.logAt(
          level,
          `New blocks successfully found.`,
          ~params={"source": source.name, "newBlockHeight": height},
        )
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
          ~onHeight=height => settle(sourceState, height),
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
        pokeTimeoutId :=
          Some(
            sourceManager.clock.setTimeout(
              ~label="stall poke",
              () => {
                pokeTimeoutId := None
                if !settled.contents {
                  watched->Array.forEach(subscription => subscription.distrustStream())
                }

                // Re-checked: distrusting can answer the wait, and a timer armed
                // after the cleanup that follows is one nothing can ever clear.
                if !settled.contents {
                  armPokeTimeout()
                }
              },
              sourceManager.clock->Clock.jitter(stallTimeout),
            ),
          )

      // Punctual, unlike the poke above: newBlockStallTimeout is a promise to the
      // operator about when they hear about a quiet chain, and spreading that
      // would report it early. Fires once — the warning is worth saying once per
      // wait, and a fallback stays recruited.
      let armStallTimeout = () =>
        stallTimeoutId :=
          Some(
            sourceManager.clock.setTimeout(
              ~label="stall timeout",
              () => {
                stallTimeoutId := None
                if !settled.contents {
                  stalled := true

                  // Build fallback: non-disabled sources not in mainSources with a valid role, even ones failing or held
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

                  switch fallbackSources {
                  | [] =>
                    logger->Logger.warn(
                      `No new blocks detected within ${(stallTimeout / 1000)
                          ->Int.toString}s. Polling will continue at a reduced rate. For better reliability, refer to our RPC fallback guide: https://docs.envio.dev/docs/HyperIndex/rpc-sync`,
                    )
                  | _ =>
                    logger->Logger.warn(
                      `No new blocks detected within ${(stallTimeout / 1000)
                          ->Int.toString}s. Continuing polling with secondary RPC sources from the configuration.`,
                    )
                  }

                  // Recruited to poll, not to stream: see `watch`.
                  fallbackSources->Array.forEach(sourceState =>
                    sourceState->watch(~withStream=false)
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
              },
              stallTimeout,
            ),
          )

      armPokeTimeout()
      armStallTimeout()
    }
  })
}

let executeQuery = async (
  sourceManager: t,
  ~request: IndexingPlan.fetchRequest,
  ~knownHeight,
  ~isRealtime,
  ~reorgableFrom,
  ~isStale,
) => {
  // Read when the manager actually runs out of sources, not on the way in: the
  // reason is recorded by the failure that disabled the last one.
  let noSourcesError = () =>
    switch sourceManager.disableReason {
    | Some(reason) =>
      `The indexer doesn't have data-sources which can continue fetching. The last one was disabled because ${reason}`
    | None => "The indexer doesn't have data-sources which can continue fetching. Please, check the error logs or reach out to the Envio team."
    }

  // Sources where the query is impossible - lazily allocated, excluded for the duration of this query
  let excludedSourcesRef = ref(None)

  let fromBlock = request->IndexingPlan.Request.fromBlock
  let toBlockRef = ref(request->IndexingPlan.Request.toBlock)
  let responseRef = ref(None)
  let retryRef = ref(0)

  // A rollback or a stop while the query waited out a backoff leaves nobody to
  // take its response, so further attempts would only load the source.
  while responseRef.contents->Option.isNone && !isStale() {
    // Select the best source at the start of every iteration
    let sourceState = switch sourceManager->getNextSource(
      ~isRealtime,
      ~excludedSources=?excludedSourcesRef.contents,
    ) {
    | Some(s) =>
      if s.source !== sourceManager.queriedSource {
        let logger = sourceManager.logger
        logger->Logger.info(
          "Switching data-source",
          ~params={
            "source": s.source.name,
            "previousSource": sourceManager.queriedSource.name,
            "fromBlock": fromBlock,
          },
        )
      }
      s
    | None =>
      let logger = sourceManager.logger
      %raw(`null`)->ErrorHandling.mkLogAndRaise(~logger, ~msg=noSourcesError())
    }
    sourceManager.activeSource = sourceState.source
    sourceManager.queriedSource = sourceState.source
    let source = sourceState.source
    let toBlock = toBlockRef.contents
    let retry = retryRef.contents

    let logger = sourceManager.logger->Logger.withFields({
      "logType": "Block Range Query",
      "source": source.name,
      "fromBlock": fromBlock,
      "toBlock": toBlock,
      "addresses": request->IndexingPlan.Request.addressCount,
      "retry": retry,
    })

    let startedAt = Performance.now()
    let outcome = switch await source.getItems(
      ~request,
      ~toBlock,
      ~retry,
      ~reorgableFrom,
      ~knownHeight,
    ) {
    | outcome => outcome
    | exception exn => exn->ErrorHandling.mkLogAndRaise(~logger, ~msg="Failed to fetch block Range")
    }
    sourceState->recordRequestStats(outcome.requestStats)
    switch outcome.result {
    | Ok({page, latestFetchedBlockNumber, knownHeight: reportedHeight}) =>
      switch validateResponsePage(~method="getItems", ~page) {
      | Some(inconsistency) =>
        await sourceManager->retryInconsistentResponse(
          sourceState,
          ~retry,
          ~isRealtime,
          ~logger,
          ~inconsistency,
          ~excludedSources=?excludedSourcesRef.contents,
        )
        retryRef := retryRef.contents + 1
      | None =>
        sourceState->markAnswered
        // A height reported with the page is fresh for exactly this source, so
        // during a long backfill (when nothing is waiting on the feed) it keeps
        // the per-source envio_source_known_height current — and if a wait is
        // in flight, a height learned this way can settle it.
        reportedHeight->Option.forEach(height => sourceState.feed->HeightFeed.recordHeight(height))
        responseRef :=
          Some({
            Source.page,
            latestFetchedBlockNumber,
            knownHeight: reportedHeight->Option.getOr(knownHeight),
            totalTimeElapsed: startedAt->Performance.secondsSince,
            sourceIndex: sourceManager.sourcesState->Array.indexOf(sourceState),
          })
      }

    | Error(RateLimited({resetMs})) =>
      await sourceManager->waitForRateLimitReset(~resetMs, ~retry, ~logger)
      retryRef := retryRef.contents + 1

    | Error(BehindHead({blockNumber})) =>
      await sourceManager->retryBehindHead(
        sourceState,
        ~retry,
        ~isRealtime,
        ~logger,
        ~blockNumber,
        ~excludedSources=?excludedSourcesRef.contents,
      )
      retryRef := retryRef.contents + 1

    | Error(Unusable({message, ?blockNumber})) =>
      // Several requests can fail on the same source at once; only the one
      // that disables it reports why.
      if sourceManager->disableSource(sourceState) {
        sourceManager.disableReason = Some(message)
        logger->Logger.error(message, ~params={"blockNumber": blockNumber})
      }
      retryRef := 0

    // A suggestion that doesn't narrow the range asks for the query that just
    // failed. Retrying it unchanged and without a wait makes no progress and
    // never counts against the source, so pace it like any other failure and
    // let the schedule move on to one that can answer.
    | Error(NarrowRange({toBlock, attemptedToBlock})) if toBlock >= attemptedToBlock =>
      await sourceManager->retryFailedPage(
        sourceState,
        ~retry,
        ~isRealtime,
        ~logger,
        ~msg=`The ${source.name} source rejected the block range and suggested #${toBlock->Int.toString}, which is no narrower than the #${attemptedToBlock->Int.toString} it just refused.`,
        ~backoffMillis=retry->retryBackoffMillis,
        ~minBackoffMillis=minRecoverableBackoffMillis,
        ~cause=None,
        ~excludedSources=?excludedSourcesRef.contents,
      )
      retryRef := retryRef.contents + 1

    | Error(NarrowRange({toBlock, attemptedToBlock})) =>
      logger->Logger.trace(
        "Failed getting data for the block range. Immediately retrying with the suggested block range from response.",
        ~params={"toBlock": attemptedToBlock, "suggestedToBlock": toBlock},
      )
      toBlockRef := Some(toBlock)
      // The next attempt asks a strictly smaller question, so it starts a
      // fresh schedule rather than continuing this one.
      retryRef := 0

    | Error(WrongSourceForQuery({message})) =>
      // Not marked failed: the source isn't broken, the query just can't work
      // on it.
      let excludedSources = switch excludedSourcesRef.contents {
      | Some(s) => s
      | None =>
        let s = Utils.Set.make()
        excludedSourcesRef := Some(s)
        s
      }
      excludedSources->Utils.Set.add(sourceState)->ignore
      logger->Logger.warn(message ++ " - Attempting another source")
      retryRef := 0

    | Error(Backoff({message, ?backoffMillis, ?cause})) =>
      await sourceManager->retryFailedPage(
        sourceState,
        ~retry,
        ~isRealtime,
        ~logger,
        ~msg=message,
        ~backoffMillis=backoffMillis->Option.getOr(retry->retryBackoffMillis),
        ~cause,
        ~excludedSources=?excludedSourcesRef.contents,
      )
      retryRef := retryRef.contents + 1
    }
  }

  responseRef.contents
}

let getBlockHashes = async (sourceManager: t, ~blockNumbers: array<int>, ~isRealtime: bool) => {
  let responseRef = ref(None)
  let retryRef = ref(0)
  let cannotReadHashes = Utils.Set.make()
  sourceManager.sourcesState->Array.forEach(sourceState =>
    if sourceState.source.getBlockHashes->Option.isNone {
      cannotReadHashes->Utils.Set.add(sourceState)->ignore
    }
  )

  while responseRef.contents->Option.isNone {
    let (sourceState, getBlockHashes) = switch sourceManager->getNextSource(
      ~isRealtime,
      ~excludedSources=cannotReadHashes,
    ) {
    | Some({source: {getBlockHashes: Some(getBlockHashes)}} as s) => (s, getBlockHashes)
    | _ =>
      let logger = sourceManager.logger
      %raw(`null`)->ErrorHandling.mkLogAndRaise(
        ~logger,
        ~msg="No data-sources available for fetching block hashes.",
      )
    }
    sourceManager.activeSource = sourceState.source
    let source = sourceState.source
    let retry = retryRef.contents

    let logger = sourceManager.logger->Logger.withFields({
      "logType": "Block Hash Query",
      "source": source.name,
      "retry": retry,
    })

    let outcome = switch await getBlockHashes(blockNumbers) {
    | outcome => outcome
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(~logger, ~msg="Failed to fetch block hashes")
    }
    sourceState->recordRequestStats(outcome.requestStats)
    switch outcome.result {
    | Ok(page) =>
      switch validateResponsePage(
        ~method="getBlockHashes",
        ~page,
        ~requiredBlockNumbers=blockNumbers,
      ) {
      | Some(inconsistency) =>
        await sourceManager->retryInconsistentResponse(
          sourceState,
          ~retry,
          ~isRealtime,
          ~logger,
          ~inconsistency,
        )
        retryRef := retryRef.contents + 1
      | None =>
        sourceState->markAnswered
        responseRef := Some(page)
      }

    | Error(RateLimited({resetMs})) =>
      await sourceManager->waitForRateLimitReset(~resetMs, ~retry, ~logger)
      retryRef := retryRef.contents + 1

    | Error(BehindHead({blockNumber})) =>
      await sourceManager->retryBehindHead(sourceState, ~retry, ~isRealtime, ~logger, ~blockNumber)
      retryRef := retryRef.contents + 1

    | Error((Backoff(_) | NarrowRange(_) | WrongSourceForQuery(_) | Unusable(_)) as failure) =>
      let backoffMillis = retry->retryBackoffMillis
      let level = retry >= 4 ? #warn : #trace
      logger->Logger.logAt(
        level,
        "Failed to fetch block hashes. Retrying.",
        ~params={
          "retry": retry,
          "backOffMilliseconds": backoffMillis,
          "failure": failure,
        },
      )
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
