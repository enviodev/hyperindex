// The FinalizingIndexes phase. Reached from the processing loop when every
// chain has caught up: processing is already paused (the loop awaits this),
// pending writes are flushed, then storage builds every missing schema-defined
// index and, once they all verify, commits `ready_at`. A failure part-way
// leaves the indexes built so far in place and reaches the processing loop's
// error boundary; the retry only owes what's left. Either way the indexer never
// reports ready with an index the schema promised still missing.

let runOnce = async (state: IndexerState.t) => {
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

    // Only after the commit: in-memory readiness must never run ahead of the
    // `ready_at` a restart would read back.
    state->IndexerState.markReady(~readyAt)
    Logging.info("The indexer is ready. Switching to realtime indexing.")
  }
}

// Several paths reach the phase — a processed batch, a tick that progressed
// nothing — and a height update can bring another one round while the first is
// still building. They all join the in-flight run rather than starting a second
// pass over the same indexes.
let run = (state: IndexerState.t) =>
  switch state->IndexerState.finalizeFiber {
  | Some(fiber) => fiber
  | None =>
    let fiber = runOnce(state)->Promise.finally(() => state->IndexerState.endFinalizeFiber)
    state->IndexerState.beginFinalizeFiber(fiber)
    fiber
  }

// An indexer resumed already ready never reaches `run`, so nothing above would
// notice an index the schema promises being dropped or invalidated while it was
// down — `ensureQueryIndexes` only covers what a getWhere actually asks for.
// Best-effort and not awaited by the loop: indexing is already live and correct
// without the index, just slower.
let repairSchemaIndexes = (state: IndexerState.t) => {
  let persistence = state->IndexerState.persistence
  let storage = persistence->Persistence.getInitializedStorageOrThrow
  storage.ensureSchemaIndexes(~entities=persistence.allEntities)
}
