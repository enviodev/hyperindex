// The FinalizingIndexes phase. Reached from the processing loop when the chains
// this process drives have caught up: processing is already paused (the loop
// awaits this), pending writes are flushed, then storage builds every index the
// schema promises for those chains and, once they all verify, commits their
// `ready_at`. A failure part-way leaves the indexes built so far in place and
// reaches the processing loop's error boundary; the retry only owes what's left.
// Either way a chain never reports ready with an index the schema promised for
// it still missing.
//
// A chain's rows live in a partition of its own, so this touches nothing another
// `envio start --chain` process is indexing and never waits on one.

let runOnce = async (state: IndexerState.t) => {
  // Said by the process rather than by each of its chains: the indexes are one
  // build over the tables, and the pause is the whole process's. A chain has
  // already said it caught up, and says it is ready once this commits. The
  // chains are named because the pause is theirs, and a split run has a process
  // saying this for each part of it.
  Logging.info({
    "msg": "Backfill finished. Flushing pending writes, then building the indexes the schema promises. Indexing is paused until they are built, which on a large database can take a while.",
    "chainIds": state->IndexerState.crossChainState->CrossChainState.chainIds,
  })

  await Writing.flush(state)

  // A failed write already surfaced through onError; committing ready_at on top
  // of an incomplete write would claim progress that isn't durable.
  if !(state->IndexerState.hasFailedWrite) {
    let persistence = state->IndexerState.persistence
    let storage = persistence->Persistence.getInitializedStorageOrThrow
    let readyAt = Date.make()

    await storage.finalizeBackfill(
      ~entities=persistence.allEntities,
      ~chainIds=state->IndexerState.crossChainState->CrossChainState.chainIds,
      ~readyAt,
    )

    // Only after the commit: in-memory readiness must never run ahead of the
    // `ready_at` a restart would read back.
    // Says so per chain, which is the grain `ready_at` is committed at.
    state->IndexerState.markReady(~readyAt)
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
  storage.ensureSchemaIndexes(
    ~entities=persistence.allEntities,
    ~chainIds=state->IndexerState.crossChainState->CrossChainState.chainIds,
  )
}
