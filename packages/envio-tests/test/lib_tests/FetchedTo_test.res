open Vitest

open TestChainMetrics

// What a chain has actually fetched up to, which is what the line reporting it
// has to say. Below the reorg threshold a chain may only fetch the finalized
// range, so reaching the end of that is not reaching the head.
describe("ChainState.fetchedTo", () => {
  it("Names the block a chain has fetched to, not the one it hasn't", t => {
    t.expect([
      makeChainState(~progressBlockNumber=500, ~firstEventBlockNumber=None)->ChainState.fetchedTo,
      makeChainState(
        ~progressBlockNumber=500,
        ~firstEventBlockNumber=None,
        ~isInReorgThreshold=true,
      )->ChainState.fetchedTo,
      makeChainState(
        ~progressBlockNumber=500,
        ~firstEventBlockNumber=None,
        ~endBlock=Some(600),
      )->ChainState.fetchedTo,
    ]).toStrictEqual([("the safe block", 800), ("the chain head", 1000), ("the end block", 600)])
  })
})
