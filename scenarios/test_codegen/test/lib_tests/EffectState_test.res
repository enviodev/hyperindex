open Vitest

let makeEffect = (~name, ~rateLimit=Envio.Disable): Internal.effect =>
  Envio.createEffect(
    {name, input: S.string, output: S.string, rateLimit},
    async ({input}) => input,
  )->(Utils.magic: Envio.effect<string, string> => Internal.effect)

describe("EffectState rollback", () => {
  it("clears the cache in place but keeps stats and the rate-limit window", t => {
    let self = EffectState.make()
    let effect = makeEffect(
      ~name="withRateLimit",
      ~rateLimit=Enable({calls: 5, per: Milliseconds(1000)}),
    )
    let table = self->EffectState.getTable(~effect, ~scope=CrossChain)

    // Survivors: monotonic metric counters and the consumed rate-limit budget.
    table.stats->EffectState.queueEnqueued(~count=4)
    table->EffectState.recordInvalidation
    table->EffectState.commitCacheCount(~count=3)
    (table.rateLimitState->Option.getOrThrow).availableCalls = 2

    // Cache-derived fields, all expected to reset.
    table.idsToStore = ["a"]
    table.changesCount = 5.
    table.dict->Dict.set("a", Set({entityId: "a"->EntityId.unsafeOfString, entity: "out"->Obj.magic, checkpointId: 0n}))

    self->EffectState.resetForRollback

    let sameTable = self->EffectState.getTable(~effect, ~scope=CrossChain)
    t.expect((
      sameTable === table,
      sameTable.idsToStore,
      sameTable.changesCount,
      sameTable.invalidationsCount,
      sameTable.dict->Dict.keysToArray,
      (sameTable.rateLimitState->Option.getOrThrow).availableCalls,
      self->EffectState.toMetrics,
    )).toEqual((
      true,
      [],
      0.,
      0,
      [],
      2,
      [
        {
          Metrics.effect: "withRateLimit",
          scope: "crossChain",
          callSeconds: 0.,
          callSecondsTotal: 0.,
          callCount: 0.,
          activeCallsCount: 0,
          queueCount: 4,
          queueWaitSeconds: 0.,
          invalidationsCount: 1.,
          cacheCount: Some(3),
        },
      ],
    ))
  })
})

describe("EffectState unregistered cache count", () => {
  let cacheOnlyMetric = (~effect, ~count): Metrics.effectMetrics => {
    effect,
    scope: "crossChain",
    callSeconds: 0.,
    callSecondsTotal: 0.,
    callCount: 0.,
    activeCallsCount: 0,
    queueCount: 0,
    queueWaitSeconds: 0.,
    invalidationsCount: 0.,
    cacheCount: Some(count),
  }

  it("renders a cache-only metric until the effect's table takes over", t => {
    let self = EffectState.make()
    self->EffectState.setUnregisteredCacheCount(~effectName="a", ~scope=CrossChain, ~count=7)

    let beforeCreate = self->EffectState.toMetrics

    let table = self->EffectState.getTable(~effect=makeEffect(~name="a"), ~scope=CrossChain)
    let afterCreate = self->EffectState.toMetrics

    table->EffectState.commitCacheCount(~count=9)
    let afterCommit = self->EffectState.toMetrics

    t.expect((beforeCreate, afterCreate, afterCommit)).toEqual((
      [cacheOnlyMetric(~effect="a", ~count=7)],
      [cacheOnlyMetric(~effect="a", ~count=7)],
      [cacheOnlyMetric(~effect="a", ~count=9)],
    ))
  })

  it("never double-counts: a registered effect drops its unregistered count", t => {
    let self = EffectState.make()
    self->EffectState.setUnregisteredCacheCount(~effectName="registered", ~scope=CrossChain, ~count=1)
    self->EffectState.setUnregisteredCacheCount(~effectName="pending", ~scope=CrossChain, ~count=2)

    // Registering "registered" consumes its unregistered count; "pending" stays.
    self->EffectState.getTable(~effect=makeEffect(~name="registered"), ~scope=CrossChain)->ignore

    t.expect(
      (self->EffectState.toMetrics)
      ->Array.toSorted((a, b) => String.compare(a.effect, b.effect)),
      ~message="one series per effect — the registered effect's table replaces its seed",
    ).toEqual([
      cacheOnlyMetric(~effect="pending", ~count=2),
      cacheOnlyMetric(~effect="registered", ~count=1),
    ])
  })
})
