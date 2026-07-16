// Owns all per-(effect, scope) runtime state and its lifecycle. The two maps
// have different rollback semantics, so keeping them together behind an explicit
// `resetForRollback` makes the invariant enforced rather than remembered.

// Per-scope rate-limit window and queue. A chain-scoped effect gets one of
// these per chain, so each chain's throughput is independent.
type effectRateLimitState = {
  callsPerDuration: int,
  durationMs: int,
  mutable availableCalls: int,
  mutable windowStartTime: float,
  mutable nextWindowPromise: option<promise<unit>>,
}

// Per-(effect, scope) counters rendered into the envio_effect_* metrics.
// Keyed by cache table name and kept outside the cache tables so a rollback
// (which drops the tables) never rewinds the monotonic counters.
type effectStats = {
  effectName: string,
  scope: Internal.chainScope,
  // Wall-clock time with at least one call in flight.
  mutable callSeconds: float,
  // Cumulative per-call time; exceeds callSeconds under parallel execution.
  mutable callSecondsTotal: float,
  mutable callCount: int,
  mutable activeCallsCount: int,
  mutable prevCallStartTimerRef: Performance.timeRef,
  mutable queueCount: int,
  mutable queueWaitSeconds: float,
  mutable invalidationsCount: int,
  // Number of persisted cache rows; seeded from the db on restart.
  mutable cacheCount: int,
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

type t = {
  // Cache tables keyed by cache table name. Dropped on rollback — the cache
  // is re-derivable from the db.
  mutable tables: dict<effectCacheInMemTable>,
  // Rate-limit windows keyed by the same name. Survive rollback: rate limiting
  // reflects real API throughput, not indexing progress, so a reorg must not
  // refill an effect's budget.
  rateLimits: dict<effectRateLimitState>,
  // Metric counters keyed by the same name. Survive rollback: prometheus
  // counters must stay monotonic.
  stats: dict<effectStats>,
}

let make = (): t => {tables: Dict.make(), rateLimits: Dict.make(), stats: Dict.make()}

let getStats = (self: t, ~tableName, ~effectName, ~scope) =>
  switch self.stats->Utils.Dict.dangerouslyGetNonOption(tableName) {
  | Some(existing) => existing
  | None =>
    let created: effectStats = {
      effectName,
      scope,
      callSeconds: 0.,
      callSecondsTotal: 0.,
      callCount: 0,
      activeCallsCount: 0,
      prevCallStartTimerRef: %raw(`null`),
      queueCount: 0,
      queueWaitSeconds: 0.,
      invalidationsCount: 0,
      cacheCount: 0,
    }
    self.stats->Dict.set(tableName, created)
    created
  }

let stats = (self: t) => self.stats

// Seed the persisted-rows count from the db on restart, before any cache table
// is lazily created.
let setCacheCount = (self: t, ~effectName, ~scope, ~count) => {
  let tableName = Internal.EffectCache.toTableName(~effectName, ~scope)
  (self->getStats(~tableName, ~effectName, ~scope)).cacheCount = count
}

let getRateLimitState = (self: t, ~tableName, ~effect: Internal.effect) =>
  switch effect.rateLimit {
  | None => None
  | Some({callsPerDuration, durationMs}) =>
    Some(
      switch self.rateLimits->Utils.Dict.dangerouslyGetNonOption(tableName) {
      | Some(existing) => existing
      | None =>
        let created: effectRateLimitState = {
          callsPerDuration,
          durationMs,
          availableCalls: callsPerDuration,
          windowStartTime: Date.now(),
          nextWindowPromise: None,
        }
        self.rateLimits->Dict.set(tableName, created)
        created
      },
    )
  }

// Get, or lazily create, the in-mem table for an (effect, scope). A recreated
// table (e.g. after a rollback) reuses the surviving rate-limit window.
let getTable = (self: t, ~effect: Internal.effect, ~scope: Internal.chainScope) => {
  let tableName = Internal.EffectCache.toTableName(~effectName=effect.name, ~scope)
  switch self.tables->Utils.Dict.dangerouslyGetNonOption(tableName) {
  | Some(inMemTable) => inMemTable
  | None =>
    let inMemTable: effectCacheInMemTable = {
      idsToStore: [],
      dict: Dict.make(),
      changesCount: 0.,
      invalidationsCount: 0,
      effect,
      scope,
      table: Internal.makeCacheTable(~effectName=effect.name, ~scope),
      rateLimitState: self->getRateLimitState(~tableName, ~effect),
      stats: self->getStats(~tableName, ~effectName=effect.name, ~scope),
    }
    self.tables->Dict.set(tableName, inMemTable)
    inMemTable
  }
}

let forEach = (self: t, fn) => self.tables->Utils.Dict.forEach(fn)

// Drop the cache tables (re-derivable from the db) but keep the rate-limit
// windows so a reorg doesn't hand an effect a fresh budget.
let resetForRollback = (self: t) => self.tables = Dict.make()
