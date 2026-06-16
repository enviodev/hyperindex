open Vitest

// Documents how `indexer.onBlock` handlers interact with `createTestIndexer`'s
// process range. A block handler fires on every block in the processed range,
// so a single simulated event replays the handler across [startBlock, event] —
// this is intended; the range is bounded by the process `startBlock` (which
// defaults to the chain's config start_block when omitted). This replay is why
// a far-from-start event floods `result.changes`, and why omitting `startBlock`
// matters.
//
// Chain 137 carries the module-scope handlers from `src/handlers/EventHandlers.ts`
// (two every-block handlers plus `test_onblock_filter`, bounded to blocks
// 100-200). Chain 1 has the same `Noop` contract but no block handler. Block 250
// is past the filter's upper bound (200); a smaller range trips the separate
// "onBlock end block > chain end block" guard in ChainFetcher.res.

type change = {block: int}

let eventAtBlock250 = Indexer.makeSimulateItem(
  OnEvent({event: Noop(EmptyEvent), block: {number: 250}}),
)

// {first, last, length} of the blocks that produced a change — enough to show
// the processed range without a 250-element array.
let processedRange = (result: TestIndexer.processResult) => {
  let bs = result.changes->Array.map(c => (c->(Utils.magic: unknown => change)).block)
  {
    "first": bs->Array.get(0),
    "last": bs->Array.get(bs->Array.length - 1),
    "length": bs->Array.length,
  }
}

Async.it("no block handler: a simulated event touches only its own block", async t => {
  let indexer = Indexer.createTestIndexer()
  let result = await indexer.process({chains: {\"1": {simulate: [eventAtBlock250]}}})
  t.expect(result->processedRange).toEqual({"first": Some(250), "last": Some(250), "length": 1})
})

Async.it("block handler replays every block from the range start to the event", async t => {
  let indexer = Indexer.createTestIndexer()
  let result = await indexer.process({chains: {\"137": {simulate: [eventAtBlock250]}}})
  // No startBlock → range starts at config start_block (1) → handler runs 1..250.
  t.expect(result->processedRange).toEqual({"first": Some(1), "last": Some(250), "length": 250})
})

Async.it("process startBlock bounds the block-handler replay", async t => {
  let indexer = Indexer.createTestIndexer()
  let result = await indexer.process({chains: {\"137": {startBlock: 100, simulate: [eventAtBlock250]}}})
  // startBlock=100 → handler runs 100..250 instead of 1..250.
  t.expect(result->processedRange).toEqual({"first": Some(100), "last": Some(250), "length": 151})
})
