open Vitest

describe("IndexerState fetch stall accounting", () => {
  let stalledOnFetchSeconds = (state: IndexerState.t) =>
    (state->IndexerState.toMetrics).processingStalledOnFetchSeconds

  Async.it("Accrues an open stall interval from the first mark, not the last", async t => {
    let state = MockIndexer.InMemoryStore.make()

    state->IndexerState.markProcessingStalledOnFetch
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=50)
    // A second mark while one is open must not restart the interval, or a loop
    // that idles across several fetch kicks would under-report.
    state->IndexerState.markProcessingStalledOnFetch
    state->IndexerState.beginProcessing

    t.expect(state->stalledOnFetchSeconds).toBeGreaterThanOrEqual(0.04)
  })

  Async.it(
    "Settles the stall on reorg so the rollback isn't counted as fetch starvation",
    async t => {
      let state = MockIndexer.InMemoryStore.make()

      state->IndexerState.markProcessingStalledOnFetch
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=50)
      state->IndexerState.beginReorg(
        ~chainId=1->ChainId.fromInt,
        ~blockNumber=100,
      )
      // Settled, not discarded: the wait before the reorg still has to land in
      // the counter.
      let settledOnReorg = state->stalledOnFetchSeconds
      t.expect(settledOnReorg).toBeGreaterThanOrEqual(0.04)

      // Stands in for the rollback. Without the settle in beginReorg this span
      // would fold into the stall on the next beginProcessing, double-counting
      // time envio_rollback_seconds already owns.
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=50)
      state->IndexerState.beginProcessing

      t.expect(state->stalledOnFetchSeconds).toBe(settledOnReorg)
    },
  )
})
