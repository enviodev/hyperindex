open Vitest

open TestChainMetrics

// What a chain reports reaching, and how often. Below the reorg threshold a
// chain may only fetch the finalized range, so reaching the end of that is not
// reaching the head — and since the head moves, it reaches whatever it is
// fetching to over and over.
describe("ChainState.takeFetchedTo", () => {
  it("Names the block a chain has fetched to, not the one it hasn't", t => {
    let takeFrom = cs => cs->ChainState.takeFetchedTo

    t.expect([
      makeChainState(~progressBlockNumber=500, ~firstEventBlockNumber=None)->takeFrom,
      makeChainState(
        ~progressBlockNumber=500,
        ~firstEventBlockNumber=None,
        ~isInReorgThreshold=true,
      )->takeFrom,
      makeChainState(
        ~progressBlockNumber=500,
        ~firstEventBlockNumber=None,
        ~endBlock=Some(600),
      )->takeFrom,
    ]).toStrictEqual([
      Some(("the safe block", 800)),
      Some(("the chain head", 1000)),
      Some(("the end block", 600)),
    ])
  })

  it("Reports a milestone once, however many times the chain reaches it", t => {
    let chainState = makeChainState(~progressBlockNumber=500, ~firstEventBlockNumber=None)

    t.expect((
      chainState->ChainState.takeFetchedTo,
      chainState->ChainState.takeFetchedTo,
    )).toStrictEqual((Some(("the safe block", 800)), None))
  })
})
