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

// `makeChainState` puts the head at 1000 with a reorg depth of 200 and no
// block lag, so a chain fetches no further than block 800 until the indexer
// crosses into the blocks above it.
describe("ChainState.reorgThresholdLiftsCeiling", () => {
  it("Is true only where the lag was holding the chain back", t => {
    let chain = (~endBlock=None, ~maxReorgDepth=200, ~config=TestConfig.default) =>
      makeChainState(
        ~progressBlockNumber=500,
        ~firstEventBlockNumber=None,
        ~endBlock,
        ~maxReorgDepth,
        ~config,
      )->ChainState.reorgThresholdLiftsCeiling

    t.expect([
      // Runs to the head, so crossing is what lets it get there.
      chain(),
      // An end block above the held frontier: crossing opens up the rest of it.
      chain(~endBlock=Some(900)),
      // An end block below it was never held back by the lag.
      chain(~endBlock=Some(600)),
      // No reorg depth to be held back by, so crossing changes nothing. This is
      // also every configuration that keeps no history, which is why the line
      // has no form that leaves the history out.
      chain(~maxReorgDepth=0),
      // Nothing is rolled back, so the chain already fetches to the head.
      chain(~config={...TestConfig.default, shouldRollbackOnReorg: false}),
    ]).toStrictEqual([true, true, false, false, false])
  })
})

describe("ChainState.reorgThresholdEntryMessage", () => {
  // Crossing lifts the lag that held the chain short of the head and starts the
  // history a rollback replays. A reader watching the writes grow wants the
  // second half of that.
  it("Says what crossing changed, and what it starts writing", t => {
    t.expect(ChainState.reorgThresholdEntryMessage).toBe(
      "Indexing the latest blocks now. These can be reorged, so the indexer starts storing a history of every change to roll back with.",
    )
  })
})
