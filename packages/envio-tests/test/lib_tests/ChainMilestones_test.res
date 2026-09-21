open Vitest

open TestChainMetrics

// The milestones a chain reports for itself. Each is the chain's own to say:
// what it indexed to, what changed when it crossed the reorg threshold, and
// when it became ready. A run split across processes has no process that can
// speak for chains it doesn't drive, and an unsplit run says exactly the same
// things about exactly the same chains.

describe("ChainState.takeProcessedToEndBlock", () => {
  it("Names the end block a chain finished, once, and only once it has", t => {
    let unfinished = makeChainState(
      ~progressBlockNumber=500,
      ~firstEventBlockNumber=None,
      ~endBlock=Some(600),
    )
    let finished = makeChainState(
      ~progressBlockNumber=600,
      ~firstEventBlockNumber=None,
      ~endBlock=Some(600),
    )
    // A chain that runs to the head has no end block to finish.
    let endless = makeChainState(~progressBlockNumber=600, ~firstEventBlockNumber=None)

    t.expect((
      unfinished->ChainState.takeProcessedToEndBlock,
      finished->ChainState.takeProcessedToEndBlock,
      // Reaching it stays true, and every later pass would say so again.
      finished->ChainState.takeProcessedToEndBlock,
      endless->ChainState.takeProcessedToEndBlock,
    )).toStrictEqual((None, Some(600), None, None))
  })
})

describe("ChainState.reorgThresholdEntryMessage", () => {
  // Crossing lifts the lag that held the chain short of the head, and starts
  // the history a rollback replays. A reader watching writes grow wants the
  // second half of that.
  it("Says what crossing changed, and mentions history only when it is kept", t => {
    let chainState = makeChainState(~progressBlockNumber=500, ~firstEventBlockNumber=None)
    let beforeCrossing = chainState->ChainState.reorgThresholdEntryMessage
    chainState->ChainState.enterReorgThreshold

    t.expect((beforeCrossing, chainState->ChainState.reorgThresholdEntryMessage)).toStrictEqual((
      "Now indexing up to the latest block.",
      "Now indexing up to the latest block. These can still be reorged, so changes are kept ready to roll back.",
    ))
  })
})
