open Vitest

describe("SyncETA.isIndexerFullySynced", () => {
  // The supervisor renders a frame before any worker has reported, and a run
  // with nothing to report is not a run that finished syncing.
  it("Doesn't call an indexer with no reported chains synced", t => {
    t.expect(SyncETA.isIndexerFullySynced([])).toBe(false)
  })
})
