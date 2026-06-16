open Vitest

// Reproduction for the reported `createTestIndexer` issue: when a chain has a
// block handler, `indexer.process(...)` replays that handler for every block
// from the chain's start block up to the processed event's block instead of
// processing just the event. With a real (far-from-start) event this floods
// `result.changes` with one entry per block, which is why the reporter had to
// disable their block handler to get tests passing.
//
// Chain 137 carries the module-scope `indexer.onBlock` handlers from
// `src/handlers/EventHandlers.ts` (`test_onblock_default` fires every block;
// `test_onblock_filter` is bounded to blocks 100-200). Chain 1 has the same
// `Noop` contract but no block handler, so it's a clean baseline. Block 250 is
// past `test_onblock_filter`'s upper bound (200); a smaller block instead trips
// the separate "onBlock end block > chain end block" guard in ChainFetcher.res.

type change = {block: int}

let eventAtBlock250 = Indexer.makeSimulateItem(
  OnEvent({event: Noop(EmptyEvent), block: {number: 250}}),
)

let processedBlocks = (result: TestIndexer.processResult) =>
  result.changes->Array.map(c => (c->(Utils.magic: unknown => change)).block)

Async.it("simulate processes only the event's block when no block handler is registered", async t => {
  let indexer = Indexer.createTestIndexer()
  let result = await indexer.process({chains: {\"1": {simulate: [eventAtBlock250]}}})
  t.expect(result->processedBlocks).toEqual([250])
})

// Expected: a single simulated event yields a single change for its own block,
// same as the chain-1 baseline. Actual: chain 137's every-block handler makes
// the run replay blocks 1..250 (250 changes). `it_fails` keeps CI green while
// the bug exists; once it's fixed this starts failing — drop `_fails` then.
Async.it_fails(
  "block handler makes process replay every block from chain start to the event block",
  async t => {
    let indexer = Indexer.createTestIndexer()
    let result = await indexer.process({chains: {\"137": {simulate: [eventAtBlock250]}}})
    t.expect(result->processedBlocks).toEqual([250])
  },
)
