// The FinalizingIndexes phase. Runs once, from the processing loop, when every
// chain has caught up: processing is already paused (the loop awaits this),
// pending writes are flushed, then storage creates every missing schema-defined
// index and stamps `ready_at` in one transaction. A failure rolls back both and
// reaches the processing loop's error boundary, which stops the indexer — the
// rollback leaves nothing half-done, so a restart picks the work up cleanly.
// Either way the indexer never reports ready with an index the schema promised
// still missing.

let run = async (state: IndexerState.t) => {
  Logging.info(
    "All chains are caught up. Finalizing the indexer before switching to realtime: flushing pending writes, then creating the indexes the schema promises.",
  )

  await Writing.flush(state)

  // A failed write already surfaced through onError; committing ready_at on top
  // of an incomplete write would claim progress that isn't durable.
  if !(state->IndexerState.hasFailedWrite) {
    let persistence = state->IndexerState.persistence
    let storage = persistence->Persistence.getInitializedStorageOrThrow
    let readyAt = Date.make()

    await storage.finalizeBackfill(
      ~entities=persistence.allEntities,
      ~chainIds=state
      ->IndexerState.chainStates
      ->Dict.valuesToArray
      ->Array.map(cs => (cs->ChainState.chainConfig).id),
      ~readyAt,
    )

    state->IndexerState.markReady(~readyAt)
    Logging.info("The indexer is ready. Switching to realtime indexing.")
  }
}
