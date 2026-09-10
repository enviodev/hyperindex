// The FinalizingIndexes phase. Reached from the processing loop when this
// process's chains have caught up: processing is already paused (the loop awaits
// this), pending writes are flushed, the chains are marked caught up, and then
// — only if no chain in the schema is still backfilling — storage builds every
// missing schema-defined index and, once they all verify, commits `ready_at`.
// A failure part-way leaves the indexes built so far in place and reaches the
// processing loop's error boundary; the retry only owes what's left. Either way
// no chain carries `ready_at` while an index the schema promised is missing.

// The barrier `envio start --chain` turns on: the schema's indexes are global
// objects on shared tables, so the process that finds no chain left backfilling
// is the one that builds them.
//
// Every caller reads the count strictly after committing its own chains'
// stamps, never before. Two processes finishing together would otherwise each
// see the other still pending and neither would build; reading after its own
// commit means at least one of them sees a fully stamped table, and that one is
// still running at the moment it reads.
%%private(
  let buildSchemaIndexesIfLast = async (persistence: Persistence.t, ~readyAt) => {
    let storage = persistence->Persistence.getInitializedStorageOrThrow
    switch await storage.countChainsNotCaughtUp() {
    | 0 => await storage.finalizeBackfill(~entities=persistence.allEntities, ~readyAt)
    | pending =>
      Logging.info({
        "msg": `Leaving the schema's indexes to whichever chain finishes last: ${pending->Int.toString} of this schema's chains are still backfilling in other processes.`,
        "pendingChains": pending,
      })
    }
  }
)

let runOnce = async (state: IndexerState.t) => {
  Logging.info(
    "This indexer's chains are caught up. Finalizing before switching to realtime: flushing pending writes, then creating the indexes the schema promises.",
  )

  await Writing.flush(state)

  // A failed write already surfaced through onError; committing ready_at on top
  // of an incomplete write would claim progress that isn't durable.
  if !(state->IndexerState.hasFailedWrite) {
    let persistence = state->IndexerState.persistence
    let storage = persistence->Persistence.getInitializedStorageOrThrow
    let readyAt = Date.make()

    await storage.markChainsCaughtUp(
      ~chainIds=state
      ->IndexerState.chainStates
      ->Dict.valuesToArray
      ->Array.map(cs => (cs->ChainState.chainConfig).id),
      ~caughtUpAt=readyAt,
    )

    await persistence->buildSchemaIndexesIfLast(~readyAt)

    // Only after the build: in-memory readiness must never claim indexes the
    // database doesn't hold. With chains left backfilling elsewhere there is no
    // build to wait for, and this process is genuinely realtime without one.
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

// An indexer that resumes with its chains already caught up never reaches `run`,
// so this is the only pass that can build an index the schema promises —
// `ensureQueryIndexes` only covers what a getWhere actually asks for. Three
// cases reach it: an index the database lost while the indexer was down, a
// finalize that died between marking the chains caught up and committing the
// indexes, and an `envio start --chain` process that resumes after the sibling
// holding up the barrier has since finished.
//
// Best-effort and not awaited by the loop: indexing is already live and correct
// without the indexes, just slower, and a failure here must not take the indexer
// down. Whatever it fails to build, the next restart owes again.
let repairSchemaIndexes = async (state: IndexerState.t) => {
  let persistence = state->IndexerState.persistence
  // Nothing awaits this, so a rejection escaping here would reach the process's
  // unhandled-rejection handler and take the indexer down. The whole body is
  // guarded, the barrier's own query included.
  try {
    await persistence->buildSchemaIndexesIfLast(~readyAt=Date.make())
  } catch {
  | exn =>
    Logging.warn({
      "msg": "Failed to restore the indexes the schema promises. Queries relying on them run unindexed until the next restart.",
      "err": exn->Utils.prettifyExn,
    })
  }
}
