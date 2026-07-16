type effectRateLimitState = {
  callsPerDuration: int,
  durationMs: int,
  mutable availableCalls: int,
  mutable windowStartTime: float,
  mutable queueCount: int,
  mutable nextWindowPromise: option<promise<unit>>,
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
  mutable activeCallsCount: int,
  mutable prevCallStartTimerRef: Performance.timeRef,
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
