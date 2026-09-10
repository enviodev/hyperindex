// The FinalizingIndexes phase. Reached from the processing loop when this
// process's chains have caught up: processing is already paused (the loop awaits
// this), pending writes are flushed, the chains are marked caught up, and then
// — only if no chain in the schema is still backfilling — storage builds every
// missing schema-defined index and, once they all verify, commits `ready_at`.
// A failure part-way leaves the indexes built so far in place and reaches the
// processing loop's error boundary; the retry only owes what's left. Either way
// no chain carries `ready_at` while an index the schema promised is missing.

// Whether a chain still has backfill left, judged from what it last committed
// rather than from a stamp: `progress_block` and `source_block` are written as
// one group by the batch write, so the pair a sibling reads is always consistent
// with itself. This is `ChainState.isDurablyCaughtUp` over persisted rows, and
// it holds still while the head runs on — a chain that reached its head keeps
// reading as caught up, whoever asks and whenever.
%%private(
  let isStillBackfilling = (progress: Persistence.chainProgress, ~blockLag) => {
    // A chain nothing has ever fetched for has no head to be measured against.
    let atHead =
      progress.sourceBlockNumber > 0 &&
        progress.progressBlockNumber >= progress.sourceBlockNumber - blockLag
    // Either one, matching what the indexer itself counts as caught up. An
    // `end_block` above the head is never reached, and testing only for it would
    // leave such a chain owing its indexes for good.
    let atEndBlock = switch progress.endBlock {
    | Some(endBlock) => progress.progressBlockNumber >= endBlock
    | None => false
    }
    !(atHead || atEndBlock)
  }
)

// The barrier `envio start --chain` turns on: the schema's indexes are global
// objects on shared tables, so the process that finds no chain left backfilling
// is the one that builds them.
//
// Every caller reads the chains strictly after flushing its own writes, never
// before. Two processes finishing together would otherwise each see the other
// still behind and neither would build; reading after its own commit means at
// least one of them sees every chain caught up, and that one is still running
// at the moment it reads.
%%private(
  let buildSchemaIndexesIfLast = async (
    persistence: Persistence.t,
    ~config: Config.t,
    ~readyAt,
    ~announce,
  ) => {
    let storage = persistence->Persistence.getInitializedStorageOrThrow
    let blockLagById = Dict.make()
    config.configuredChains->Array.forEach(chain =>
      blockLagById->ChainId.Dict.set(chain.id, chain.blockLag)
    )
    let pending =
      (await storage.readChainProgress())
      ->Array.filter(progress =>
        progress->isStillBackfilling(
          ~blockLag=blockLagById
          ->ChainId.Dict.dangerouslyGetNonOption(progress.id)
          ->Option.getOr(0),
        )
      )
      ->Array.map(progress => progress.id->ChainId.toString)

    switch pending {
    | [] =>
      await storage.finalizeBackfill(~entities=persistence.allEntities, ~readyAt)
      true
    | _ =>
      // At info the first time and at debug on every pass after it: the retry
      // runs on each batch while the debt stands, and a chain can be behind for
      // hours.
      let message = {
        "msg": `Leaving the schema's indexes to whichever chain finishes last. Still backfilling: ${pending->Array.joinUnsafe(", ")}.`,
        "pendingChains": pending,
      }
      announce ? Logging.info(message) : Logging.debug(message)
      false
    }
  }
)

let runOnce = async (state: IndexerState.t) => {
  // The phase is re-entered on every batch while the indexes stay owed, so the
  // once-only half — announcing, flushing, and switching to realtime — is gated
  // on this being the first pass.
  let isFirstPass = !(state->IndexerState.isRealtime)
  state->IndexerState.recordFinalizeCheck

  if isFirstPass {
    Logging.info(
      "This indexer's chains are caught up. Finalizing before switching to realtime: flushing pending writes, then creating the indexes the schema promises.",
    )
  }

  // Every pass, not just the first: the barrier below reads this process's own
  // row along with the rest, and a batch whose write is still queued would have
  // it reading its own stale progress.
  await Writing.flush(state)

  // A failed write already surfaced through onError; committing ready_at on top
  // of an incomplete write would claim progress that isn't durable.
  if !(state->IndexerState.hasFailedWrite) {
    let readyAt = Date.make()

    if (
      await state->IndexerState.persistence->buildSchemaIndexesIfLast(
        ~config=state->IndexerState.config,
        ~readyAt,
        ~announce=isFirstPass,
      )
    ) {
      state->IndexerState.clearSchemaIndexDebt
    }

    if isFirstPass {
      // Only after the build: in-memory readiness must never claim indexes the
      // database doesn't hold. With chains left backfilling elsewhere there is
      // no build to wait for, and this process is genuinely realtime without
      // one — it just keeps the debt until a later pass can settle it.
      state->IndexerState.markReady(~readyAt)
      Logging.info("The indexer is ready. Switching to realtime indexing.")
    }
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
    if (
      await persistence->buildSchemaIndexesIfLast(
        ~config=state->IndexerState.config,
        ~readyAt=Date.make(),
        ~announce=true,
      )
    ) {
      state->IndexerState.clearSchemaIndexDebt
    }
  } catch {
  | exn =>
    Logging.warn({
      "msg": "Failed to restore the indexes the schema promises. Queries relying on them run unindexed until the next restart.",
      "err": exn->Utils.prettifyExn,
    })
  }
}
