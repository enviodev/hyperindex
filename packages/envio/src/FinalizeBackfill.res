// The FinalizingIndexes phase. Reached from the processing loop when this
// process's chains have caught up: processing is already paused (the loop awaits
// this), pending writes are flushed, and then — only if no chain in the schema
// is still backfilling — storage builds every missing schema-defined index and,
// once they all verify, commits `ready_at`. A failure part-way leaves the
// indexes built so far in place and reaches the processing loop's error
// boundary; the retry only owes what's left. Either way no chain carries
// `ready_at` while an index the schema promised is missing.

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
// is the one that builds them, and clears the debt once it has.
//
// Every caller reads the chains strictly after flushing its own writes, never
// before. Two processes finishing together would otherwise each see the other
// still behind and neither would build; reading after its own commit means at
// least one of them sees every chain caught up, and that one is still running
// at the moment it reads.
%%private(
  let settleSchemaIndexDebt = async (state: IndexerState.t, ~readyAt, ~announce) => {
    let persistence = state->IndexerState.persistence
    let storage = persistence->Persistence.getInitializedStorageOrThrow
    let blockLagByChainId = (state->IndexerState.config).blockLagByChainId
    let pending =
      (await storage.readChainProgress())
      ->Array.filter(progress =>
        progress->isStillBackfilling(
          ~blockLag=blockLagByChainId
          ->ChainId.Dict.dangerouslyGetNonOption(progress.id)
          ->Option.getOr(0),
        )
      )
      ->Array.map(progress => progress.id->ChainId.toString)

    switch pending {
    | [] =>
      await storage.finalizeBackfill(~entities=persistence.allEntities, ~readyAt)
      state->IndexerState.clearSchemaIndexDebt
    | _ =>
      // The retry comes back every `finalizeRetryIntervalMillis` while the debt
      // stands, so most passes are quiet: info to announce it, debug while the
      // wait is still reasonable. Once it has gone on too long the operator
      // needs telling, because everything else about this process looks healthy
      // while its queries run unindexed.
      let waitMillis = state->IndexerState.schemaIndexWaitMillis
      let hasWaitedTooLong =
        waitMillis >= (state->IndexerState.config).finalizeWaitWarnAfterMillis
      let message = {
        "msg": hasWaitedTooLong
          ? `The indexes the schema declares still aren't built after ${(waitMillis /.
              60_000.)->Float.toFixed(~digits=0)} minutes, because these chains haven't finished backfilling: ${pending->Array.joinUnsafe(
              ", ",
            )}. Queries relying on those indexes run unindexed until they do. If a chain is listed that nothing is indexing, start its process.`
          : `Leaving the schema's indexes to whichever chain finishes last. Still backfilling: ${pending->Array.joinUnsafe(
              ", ",
            )}.`,
        "pendingChains": pending,
        "waitedSeconds": waitMillis /. 1000.,
      }
      if hasWaitedTooLong {
        Logging.warn(message)
      } else if announce {
        Logging.info(message)
      } else {
        Logging.debug(message)
      }
    }
  }
)

let runOnce = async (state: IndexerState.t) => {
  // The phase is re-entered on every batch while the indexes stay owed, so the
  // once-only half — announcing, flushing, and switching to realtime — is gated
  // on this being the first pass.
  let isFirstPass = !(state->IndexerState.isRealtime)

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

    await state->settleSchemaIndexDebt(~readyAt, ~announce=isFirstPass)

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
    state->IndexerState.recordFinalizeCheck
    let fiber = runOnce(state)->Promise.finally(() => state->IndexerState.endFinalizeFiber)
    state->IndexerState.beginFinalizeFiber(fiber)
    fiber
  }

// An indexer that resumes with its chains already caught up never reaches `run`
// from the processing loop, so `IndexerLoop` calls it once at startup instead.
// It is the same pass: `isFirstPass` is false on a resumed realtime run, so it
// skips the announcing and the switch to realtime and does only the part that
// matters here — building whatever the schema is still missing.
//
// Three cases reach it: an index the database lost while the indexer was down, a
// finalize that died before committing them, and an `envio start --chain`
// process that resumes after the sibling holding up the barrier has finished.
//
// Best-effort and not awaited by the loop: indexing is already live and correct
// without the indexes, just slower, and a failure here must not take the indexer
// down — nothing awaits this, so a rejection would otherwise reach the process's
// unhandled-rejection handler. Whatever it fails to build, the next restart owes
// again.
let repairSchemaIndexes = (state: IndexerState.t) =>
  run(state)->Promise.catch(async exn =>
    Logging.warn({
      "msg": "Failed to restore the indexes the schema promises. Queries relying on them run unindexed until the next restart.",
      "err": exn->Utils.prettifyExn,
    })
  )
