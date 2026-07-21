// Owns all per-(effect, scope) runtime state and its lifecycle. A single store
// of tables holds the cache alongside the counters and rate-limit window that
// must outlive a rollback; `resetForRollback` clears only the cache in place so
// that survival is structural rather than remembered.

// Per-scope rate-limit window and queue. A chain-scoped effect gets one of
// these per chain, so each chain's throughput is independent.
type effectRateLimitState = {
  callsPerDuration: int,
  durationMs: int,
  mutable availableCalls: int,
  mutable windowStartTime: float,
  mutable nextWindowPromise: option<promise<unit>>,
}

// Per-(effect, scope) counters rendered into the envio_effect_* metrics. Live
// on the cache table and survive a rollback because the table does, keeping the
// prometheus counters monotonic across a reorg.
type effectStats = {
  effectName: string,
  scope: Internal.chainScope,
  // Wall-clock time with at least one call in flight.
  mutable callSeconds: float,
  // Cumulative per-call time; exceeds callSeconds under parallel execution.
  mutable callSecondsTotal: float,
  mutable callCount: float,
  mutable activeCallsCount: int,
  mutable prevCallStartTimerRef: Performance.timeRef,
  mutable queueCount: int,
  mutable queueWaitSeconds: float,
  mutable invalidationsCount: float,
  // Number of persisted cache rows; seeded from the db on restart. hasCache
  // marks that the effect persists at all, so an empty table still gets a
  // zero-valued gauge sample.
  mutable cacheCount: int,
  mutable hasCache: bool,
}

type effectCacheInMemTable = {
  // Cache keys whose handler output is persisted on the next write. Drained
  // each write; eviction is driven by the per-entry checkpointId instead.
  mutable idsToStore: array<string>,
  mutable invalidationsCount: int,
  // Each entry is stamped with the checkpoint that referenced it (or
  // loadedFromDbCheckpointId for db reads), so committed entries can be
  // dropped once persisted/re-derivable, mirroring entity changes.
  mutable dict: dict<Change.t<Internal.effectOutput>>,
  mutable changesCount: float,
  effect: Internal.effect,
  // The scope this cache is for and its resolved db table (the address). The
  // in-mem table is keyed by `table.tableName`, so a cross-chain and a
  // chain-scoped cache for the same effect stay isolated.
  scope: Internal.chainScope,
  table: Table.table,
  rateLimitState: option<effectRateLimitState>,
  stats: effectStats,
}

// Cache-row count loaded from the db on restart for an effect whose in-mem
// table hasn't been created yet this session, keyed by cache table name. Enough
// to render envio_effect_cache until the effect runs; consumed (and removed) at
// table creation so the table becomes the sole owner.
type unregisteredCacheCount = {
  effectName: string,
  scope: Internal.chainScope,
  count: int,
}

type t = {
  // The single per-(effect, scope) store. Cache-derived fields are cleared on
  // rollback; stats and the rate-limit window survive because the table does.
  tables: dict<effectCacheInMemTable>,
  unregisteredCacheCounts: dict<unregisteredCacheCount>,
}

let make = (): t => {tables: Dict.make(), unregisteredCacheCounts: Dict.make()}

let setUnregisteredCacheCount = (self: t, ~effectName, ~scope, ~count) => {
  let tableName = Internal.EffectCache.toTableName(~effectName, ~scope)
  self.unregisteredCacheCounts->Dict.set(tableName, {effectName, scope, count})
}

// --- Metric mutations. The stats records are opaque outside this module, so
// every counter change goes through these. ---

// Track a call starting at timerRef: bump the active count and extend the
// wall-clock callSeconds, which counts overlapping calls once.
let startCall = (stats: effectStats, ~timerRef) => {
  let hadActiveCalls = stats.activeCallsCount > 0
  stats.activeCallsCount = stats.activeCallsCount + 1
  if hadActiveCalls {
    let elapsed = Performance.secondsBetween(~from=stats.prevCallStartTimerRef, ~to=timerRef)
    if elapsed > 0. {
      stats.callSeconds = stats.callSeconds +. elapsed
    }
  }
  stats.prevCallStartTimerRef = timerRef
}

// Finish a call started at startTimerRef: close the wall-clock interval and
// record the call's own cumulative duration.
let endCall = (stats: effectStats, ~startTimerRef) => {
  stats.activeCallsCount = stats.activeCallsCount - 1
  let newTimer = Performance.now()
  stats.callSeconds =
    stats.callSeconds +. Performance.secondsBetween(~from=stats.prevCallStartTimerRef, ~to=newTimer)
  stats.prevCallStartTimerRef = newTimer

  stats.callCount = stats.callCount +. 1.
  stats.callSecondsTotal = stats.callSecondsTotal +. startTimerRef->Performance.secondsSince
}

let queueEnqueued = (stats: effectStats, ~count) => stats.queueCount = stats.queueCount + count

let queueDequeued = (stats: effectStats, ~count) => stats.queueCount = stats.queueCount - count

let addQueueWaitSeconds = (stats: effectStats, ~seconds) =>
  stats.queueWaitSeconds = stats.queueWaitSeconds +. seconds

// Bumps both the per-write invalidation count (consumed by the cache
// persistence math) and the monotonic metric counter.
let recordInvalidation = (inMemTable: effectCacheInMemTable) => {
  inMemTable.invalidationsCount = inMemTable.invalidationsCount + 1
  inMemTable.stats.invalidationsCount = inMemTable.stats.invalidationsCount +. 1.
}

let commitCacheCount = (inMemTable: effectCacheInMemTable, ~count) => {
  inMemTable.stats.cacheCount = count
  inMemTable.stats.hasCache = true
}

let statsToMetrics = (stats: effectStats): Metrics.effectMetrics => {
  Metrics.effect: stats.effectName,
  scope: stats.scope->Internal.EffectCache.scopeToString,
  callSeconds: stats.callSeconds,
  callSecondsTotal: stats.callSecondsTotal,
  callCount: stats.callCount,
  activeCallsCount: stats.activeCallsCount,
  queueCount: stats.queueCount,
  queueWaitSeconds: stats.queueWaitSeconds,
  invalidationsCount: stats.invalidationsCount,
  cacheCount: stats.hasCache ? Some(stats.cacheCount) : None,
}

// Full per-effect metrics for every live table, plus a cache-only entry for
// each effect that hasn't run this session (envio_effect_cache only). Such an
// entry is removed once its table is created, so the two never double-count the
// same effect.
let toMetrics = (self: t): array<Metrics.effectMetrics> => {
  let metrics = self.tables->Utils.Dict.mapValuesToArray(t => t.stats->statsToMetrics)
  self.unregisteredCacheCounts->Utils.Dict.forEach(({effectName, scope, count}) => {
    metrics
    ->Array.push({
      Metrics.effect: effectName,
      scope: scope->Internal.EffectCache.scopeToString,
      callSeconds: 0.,
      callSecondsTotal: 0.,
      callCount: 0.,
      activeCallsCount: 0,
      queueCount: 0,
      queueWaitSeconds: 0.,
      invalidationsCount: 0.,
      cacheCount: Some(count),
    })
    ->ignore
  })
  metrics
}

// Get, or lazily create, the in-mem table for an (effect, scope). On first
// creation the rate-limit window is built from the effect config and any
// matching unregistered cache count is consumed. A table recreated after a
// rollback keeps its surviving stats and rate-limit window because the table
// object itself survives — only its cache is cleared.
let getTable = (self: t, ~effect: Internal.effect, ~scope: Internal.chainScope) => {
  let tableName = Internal.EffectCache.toTableName(~effectName=effect.name, ~scope)
  switch self.tables->Utils.Dict.dangerouslyGetNonOption(tableName) {
  | Some(inMemTable) => inMemTable
  | None =>
    let stats: effectStats = {
      effectName: effect.name,
      scope,
      callSeconds: 0.,
      callSecondsTotal: 0.,
      callCount: 0.,
      activeCallsCount: 0,
      prevCallStartTimerRef: %raw(`null`),
      queueCount: 0,
      queueWaitSeconds: 0.,
      invalidationsCount: 0.,
      cacheCount: 0,
      hasCache: false,
    }
    switch self.unregisteredCacheCounts->Utils.Dict.dangerouslyGetNonOption(tableName) {
    | Some({count}) =>
      stats.cacheCount = count
      stats.hasCache = true
      self.unregisteredCacheCounts->Utils.Dict.deleteInPlace(tableName)
    | None => ()
    }
    let rateLimitState = switch effect.rateLimit {
    | None => None
    | Some({callsPerDuration, durationMs}) =>
      Some({
        callsPerDuration,
        durationMs,
        availableCalls: callsPerDuration,
        windowStartTime: Date.now(),
        nextWindowPromise: None,
      })
    }
    let inMemTable: effectCacheInMemTable = {
      idsToStore: [],
      dict: Dict.make(),
      changesCount: 0.,
      invalidationsCount: 0,
      effect,
      scope,
      table: Internal.makeCacheTable(~effectName=effect.name, ~scope),
      rateLimitState,
      stats,
    }
    self.tables->Dict.set(tableName, inMemTable)
    inMemTable
  }
}

let forEach = (self: t, fn) => self.tables->Utils.Dict.forEach(fn)

// Clear the cache-derived fields on every table in place. The cache is
// re-derivable from the db, but stats and the rate-limit window must survive a
// reorg — so the table object (their owner) is kept and only its cache reset.
let resetForRollback = (self: t) =>
  self.tables->Utils.Dict.forEach(t => {
    t.dict = Dict.make()
    t.idsToStore = []
    t.changesCount = 0.
    t.invalidationsCount = 0
  })
