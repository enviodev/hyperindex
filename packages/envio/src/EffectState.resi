type effectRateLimitState = {
  callsPerDuration: int,
  durationMs: int,
  mutable availableCalls: int,
  mutable windowStartTime: float,
  mutable nextWindowPromise: option<promise<unit>>,
}

// Per-(effect, scope) metric counters. Survive rollback so they stay monotonic.
type effectStats = {
  effectName: string,
  scope: Internal.chainScope,
  mutable callSeconds: float,
  mutable callSecondsTotal: float,
  mutable callCount: int,
  mutable activeCallsCount: int,
  mutable prevCallStartTimerRef: Performance.timeRef,
  mutable queueCount: int,
  mutable queueWaitSeconds: float,
  mutable invalidationsCount: int,
  mutable cacheCount: int,
}

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
// Metric counters keyed by cache table name.
let stats: t => dict<effectStats>
// Seed the persisted-rows count from the db on restart.
let setCacheCount: (t, ~effectName: string, ~scope: Internal.chainScope, ~count: int) => unit
