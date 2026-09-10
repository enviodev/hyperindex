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

  it("Clamps the displayed progress block to the chain's start block", t => {
    t.expect(
      make(~progressBlockNumber=-1, ~firstEventBlockNumber=None)->TuiData.fromChainMetrics(
        ~blockUnit="Slot",
      ),
    ).toStrictEqual({
      TuiData.chainId: "1",
      eventsProcessed: 7.,
      progressBlock: 100,
      sourceBlock: 1000,
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
