type effectRateLimitState = {
  callsPerDuration: int,
  durationMs: int,
  mutable availableCalls: int,
  mutable windowStartTime: float,
  mutable nextWindowPromise: option<promise<unit>>,
}

// Per-(effect, scope) metric counters. Survive rollback so they stay monotonic.
// Opaque: mutation goes through the metric operations below, reads through
// toMetrics.
type effectStats

type effectCacheInMemTable = {
  mutable idsToStore: array<string>,
  mutable invalidationsCount: int,
  mutable dict: dict<Change.t<Internal.effectOutput>>,
  mutable changesCount: float,
  effect: Internal.effect,
  scope: Internal.chainScope,
  table: Table.table,
  rateLimitState: option<effectRateLimitState>,
  stats: effectStats,
}

// Opaque store of all per-(effect, scope) runtime state.
type t

let make: unit => t
// Get, or lazily create, the in-mem table for an (effect, scope). Reuses the
// surviving rate-limit window when the table is recreated after a rollback.
let getTable: (t, ~effect: Internal.effect, ~scope: Internal.chainScope) => effectCacheInMemTable
let forEach: (t, effectCacheInMemTable => unit) => unit
// Drop the cache tables but keep the rate-limit windows across a rollback.
let resetForRollback: t => unit

let startCall: (effectStats, ~timerRef: Performance.timeRef) => unit
let endCall: (effectStats, ~startTimerRef: Performance.timeRef) => unit
let queueEnqueued: (effectStats, ~count: int) => unit
let queueDequeued: (effectStats, ~count: int) => unit
let addQueueWaitSeconds: (effectStats, ~seconds: float) => unit
// Bumps both the per-write invalidation count (consumed by the cache
// persistence math) and the monotonic metric counter.
let recordInvalidation: effectCacheInMemTable => unit
let commitCacheCount: (effectCacheInMemTable, ~count: int) => unit
// Record the db cache-row count for an effect not yet created in memory this
// session (loaded on restart). Consumed when the effect's table is created.
let setUnregisteredCacheCount: (
  t,
  ~effectName: string,
  ~scope: Internal.chainScope,
  ~count: int,
) => unit

let toMetrics: t => array<Metrics.effectMetrics>
