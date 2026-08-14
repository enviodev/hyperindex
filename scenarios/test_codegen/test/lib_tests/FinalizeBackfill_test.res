open Vitest

// The phase is reached from more than one place in the processing loop, and a
// build can take minutes. Anything arriving while one is in flight has to join
// it: a second pass would replay creates against a schema the first one is
// still changing.
describe("Finalizing the backfill", () => {
  Async.it("Runs once when two paths reach the phase together", async t => {
    let gate = MockIndexer.Gate.make()
    let calls = ref(0)
    let base = MockIndexer.Storage.make([])
    let storage = {
      ...base.storage,
      finalizeBackfill: (~entities as _, ~chainIds as _, ~readyAt as _) => {
        calls := calls.contents + 1
        gate.wait()
      },
    }
    let persistence = {
      ...PgStorage.makePersistenceFromConfig(~config=MockIndexer.config, ~storage),
      storageStatus: Persistence.Ready({
        cleanRun: false,
        cache: Dict.make(),
        chains: [],
        reorgCheckpoints: [],
        checkpointId: 0n,
        envioInfo: None,
      }),
    }
    let state = IndexerState.make(
      ~config=MockIndexer.config,
      ~persistence,
      ~chainStates=Dict.make(),
      ~isInReorgThreshold=false,
      ~isRealtime=false,
      ~onError=errHandler => errHandler->ErrorHandling.raiseExn,
    )

    let first = FinalizeBackfill.run(state)
    let second = FinalizeBackfill.run(state)
    while gate.entered.contents === 0 {
      await Utils.delay(0)
    }

    t.expect(
      (calls.contents, state->IndexerState.isRealtime),
      ~message="The second caller joined the in-flight run instead of starting another",
    ).toEqual((1, false))

    gate.release()
    await first
    await second

    t.expect(
      (
        calls.contents,
        state->IndexerState.isRealtime,
        state->IndexerState.finalizeFiber->Option.isSome,
      ),
      ~message="Both callers see the same finalization through, and it stops being in flight",
    ).toEqual((1, true, false))
  })
})
