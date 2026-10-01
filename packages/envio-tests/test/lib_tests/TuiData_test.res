open Vitest

open TestChainMetrics

describe("TuiData.fromChainMetrics", () => {
  it("Derives every progress state from chain metrics alone", t => {
    let progressOf = (m: Metrics.chainMetrics) =>
      (m->TuiData.fromChainMetrics(~blockUnit="Block")).progress

    t.expect([
      make(
        ~endBlock=Some(500),
        ~progressBlockNumber=500,
        ~firstEventBlockNumber=None,
        ~timestampCaughtUpToHeadOrEndblock=Some(caughtUpAt),
      )->progressOf,
      make(
        ~progressBlockNumber=400,
        ~firstEventBlockNumber=Some(150),
        ~timestampCaughtUpToHeadOrEndblock=Some(caughtUpAt),
      )->progressOf,
      make(~progressBlockNumber=400, ~firstEventBlockNumber=Some(150))->progressOf,
      make(~progressBlockNumber=400, ~firstEventBlockNumber=None)->progressOf,
    ]).toStrictEqual([
      Synced({
        firstEventBlockNumber: 0,
        latestProcessedBlock: 500,
        timestampCaughtUpToHeadOrEndblock: caughtUpAt,
        numEventsProcessed: 7.,
      }),
      Synced({
        firstEventBlockNumber: 150,
        latestProcessedBlock: 400,
        timestampCaughtUpToHeadOrEndblock: caughtUpAt,
        numEventsProcessed: 7.,
      }),
      Syncing({firstEventBlockNumber: 150, latestProcessedBlock: 400, numEventsProcessed: 7.}),
      SearchingForEvents,
    ])
  })

  // The source height is unknown until the first height fetch lands, so a
  // resumed chain would otherwise render progress beyond the block it counts up to.
  it("Keeps the rendered blocks inside the range the bar counts up to", t => {
    let chain =
      make(
        ~progressBlockNumber=400,
        ~firstEventBlockNumber=Some(150),
        ~sourceBlockNumber=0,
      )->TuiData.fromChainMetrics(~blockUnit="Block")

    t.expect((chain.progressBlock, chain.bufferBlock, chain.toBlock)).toStrictEqual((100, 100, 100))
  })

  it("Clamps the displayed progress block to the chain's start block", t => {
    t.expect(
      make(~progressBlockNumber=-1, ~firstEventBlockNumber=None)->TuiData.fromChainMetrics(
        ~blockUnit="Slot",
      ),
    ).toStrictEqual({
      TuiData.chainId: "1",
      eventsProcessed: 7.,
      progressBlock: 100,
      bufferBlock: 1000,
      toBlock: 1000,
      startBlock: 100,
      endBlock: None,
      poweredByHyperSync: false,
      progress: SearchingForEvents,
      latestFetchedBlockNumber: 1000,
      knownHeight: 1000,
      blockUnit: "Slot",
      rateLimitTimeMs: 0.,
      rateLimitResetInMs: None,
    })
  })
})
