open Vitest

// IndexerState.t is opaque and a full one needs a config/persistence/storage
// stack. The fetch-stall transitions read only these three fields, so a minimal
// state drives the real functions; fields they assign but never read
// (isProcessing, rollbackState) are created by the assignment itself.
type stallFields = {
  mutable processingStalledOnFetchSeconds: float,
  mutable processingStalledOnFetchSince: option<Performance.timeRef>,
  mutable epoch: int,
}

let makeStallFields = (): stallFields => {
  processingStalledOnFetchSeconds: 0.,
  processingStalledOnFetchSince: None,
  epoch: 0,
}

let asIndexerState = (fields: stallFields) =>
  fields->(Utils.magic: stallFields => IndexerState.t)

describe("IndexerState fetch stall accounting", () => {
  Async.it("Accrues an open stall interval from the first mark, not the last", async t => {
    let fields = makeStallFields()
    let state = fields->asIndexerState

    state->IndexerState.markProcessingStalledOnFetch
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=50)
    // A second mark while one is open must not restart the interval, or a loop
    // that idles across several kicks would under-report.
    state->IndexerState.markProcessingStalledOnFetch
    state->IndexerState.beginProcessing

    t.expect(fields.processingStalledOnFetchSeconds).toBeGreaterThanOrEqual(0.04)
  })

  Async.it("Settles the stall on reorg so the rollback isn't counted as fetch starvation", async t => {
    let fields = makeStallFields()
    let state = fields->asIndexerState

    state->IndexerState.markProcessingStalledOnFetch
    state->IndexerState.beginReorg(
      ~chain=ChainMap.Chain.makeUnsafe(~chainId=1),
      ~blockNumber=100,
    )
    let settledOnReorg = fields.processingStalledOnFetchSeconds

    // Stands in for the rollback. Without the settle in beginReorg this span
    // would fold into the stall on the next beginProcessing, double-counting
    // time envio_rollback_seconds already owns.
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=50)
    state->IndexerState.beginProcessing

    t.expect(fields.processingStalledOnFetchSeconds).toBe(settledOnReorg)
  })
})
