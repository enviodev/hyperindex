open Vitest

open TestChainMetrics

// The milestones a chain reports for itself. Each is the chain's own to say:
// what it indexed to, what changed when it crossed the reorg threshold, and
// when it became ready. A run split across processes has no process that can
// speak for chains it doesn't drive, and an unsplit run says exactly the same
// things about exactly the same chains.

describe("ChainState.takeFinished", () => {
  it("Names where a chain finished indexing, once, and only once it has", t => {
    let stillWorking = makeChainState(
      ~progressBlockNumber=500,
      ~firstEventBlockNumber=None,
      ~endBlock=Some(600),
    )
    let atEndBlock = makeChainState(
      ~progressBlockNumber=600,
      ~firstEventBlockNumber=None,
      ~endBlock=Some(600),
    )

    t.expect((
      stillWorking->ChainState.takeFinished,
      atEndBlock->ChainState.takeFinished,
      // Being finished stays true, and every later pass would say so again.
      atEndBlock->ChainState.takeFinished,
    )).toStrictEqual((None, Some(ChainState.EndBlock(600)), None))
  })
})

// `makeChainState` puts the head at 1000 with a reorg depth of 200, so a chain
// is held at block 800 until the indexer crosses into the blocks above it.
describe("ChainState.reorgThresholdLiftsCeiling", () => {
  it("Is nothing to a chain whose end block sits below the blocks it opens up", t => {
    t.expect([
      // Runs to the head, so crossing is what lets it get there.
      makeChainState(~progressBlockNumber=500, ~firstEventBlockNumber=None),
      // An end block above the held frontier: crossing lets it reach the rest.
      makeChainState(
        ~progressBlockNumber=500,
        ~firstEventBlockNumber=None,
        ~endBlock=Some(900),
      ),
      // An end block below it was never held back, whether or not the chain
      // has got there yet.
      makeChainState(
        ~progressBlockNumber=500,
        ~firstEventBlockNumber=None,
        ~endBlock=Some(600),
      ),
      makeChainState(
        ~progressBlockNumber=600,
        ~firstEventBlockNumber=None,
        ~endBlock=Some(600),
      ),
    ]->Array.map(ChainState.reorgThresholdLiftsCeiling)).toStrictEqual([
      true,
      true,
      false,
      false,
    ])
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
      "Indexing the latest blocks now.",
      "Indexing the latest blocks now. They can still be reorged, so changes are saved in a way that can be rolled back.",
    ))
  })
})
