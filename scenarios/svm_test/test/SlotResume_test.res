open Vitest

// Regression: an onSlot-only indexer (no contracts, no event partitions) used
// to get stuck after resuming from a checkpoint. On resume the buffer started
// empty and nothing repopulated it, so getNextQuery never produced work and the
// indexer never advanced past the resumed progress block.
Async.it("onSlot-only indexer keeps progressing after a resume", async t => {
  let indexer = Indexer.createTestIndexer()

  // Initial run up to slot 9.
  let _ = await indexer.process({
    chains: {
      \"0": {startBlock: 0, endBlock: Some(9)},
    },
  })

  // Resume from slot 10 up to slot 19. Before the fix this run got stuck and
  // produced no new SlotPing entities.
  let _ = await indexer.process({
    chains: {
      \"0": {startBlock: 10, endBlock: Some(19)},
    },
  })

  let slots =
    (await indexer.\"SlotPing".getAll())
    ->Array.map(ping => ping.slot)
    ->Belt.SortArray.Int.stableSort

  t.expect(slots).toEqual([0, 5, 10, 15])
})
