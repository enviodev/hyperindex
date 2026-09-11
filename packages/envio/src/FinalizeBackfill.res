// The FinalizingIndexes phase. Reached from the processing loop when this
// process's chains have caught up: processing is already paused (the loop awaits
// this), pending writes are flushed, and then — only if no chain in the schema
// is still backfilling — storage builds every missing schema-defined index and,
// once they all verify, commits `ready_at`. A failure part-way leaves the
// indexes built so far in place and reaches the processing loop's error
// boundary; the retry only owes what's left. The run stays in this phase until
// the build happens, so neither `ready_at` nor realtime can claim a database
// that is still missing an index the schema promised.

// Whether a chain another process drives still has backfill left, judged from
// what it last committed rather than from a stamp: `progress_block` and
// `source_block` are written as one group by the batch write, so the pair read
// here is always consistent with itself, and it holds still while the head runs
// on — a chain that reached its head keeps reading as caught up, whenever asked.
%%private(
  let isStillBackfilling = (progress: Persistence.chainProgress, ~blockLag) => {
    // Only a batch write ever sets `source_block`, so zero means the chain has
    // not indexed its first block and there is no head to measure it against.
    // It counts as backfilling: nothing here can tell it apart from a chain
    // partway through one, and letting it pass would build the indexes early.
    let atHead =
      progress.sourceBlockNumber > 0 &&
        progress.progressBlockNumber >= Pervasives.max(0, progress.sourceBlockNumber - blockLag)
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
// is the one that builds them. Returns whether it did.
//
// Every caller reads the chains strictly after flushing its own writes, never
// before. Two processes finishing together would otherwise each see the other
// still behind and neither would build; reading after its own commit means at
// least one of them sees every chain caught up, and that one is still running
// at the moment it reads.
%%private(
  let buildSchemaIndexesIfLast = async (state: IndexerState.t, ~readyAt, ~announce): bool => {
    let persistence = state->IndexerState.persistence
    let storage = persistence->Persistence.getInitializedStorageOrThrow
    let config = state->IndexerState.config

    // Only the chains this process doesn't drive. Its own are caught up by
    // definition — that is the condition it is here under — and they are also
    // the ones a row can't speak for: a chain with nothing to index never has a
    // batch to write one, and a chain resumed at a head that has since run on
    // is still caught up as of the progress it committed.
    let isOwnChain = Dict.make()
    state
    ->IndexerState.chainStates
    ->Dict.valuesToArray
    ->Array.forEach(cs => isOwnChain->ChainId.Dict.set((cs->ChainState.chainConfig).id, true))

    let others =
      config.blockLagByChainId
      ->Dict.keysToArray
      ->Array.filter(id => isOwnChain->Dict.get(id)->Option.isNone)

    // A run driving every chain has nobody to wait for, so it never asks.
    let pending = switch others {
    | [] => []
    | _ =>
      (await storage.readChainProgress())
      ->Array.filter(progress =>
        isOwnChain->ChainId.Dict.dangerouslyGetNonOption(progress.id)->Option.isNone &&
          progress->isStillBackfilling(
            ~blockLag=config.blockLagByChainId
            ->ChainId.Dict.dangerouslyGetNonOption(progress.id)
            ->Option.getOr(0),
          )
      )
      ->Array.map(progress => progress.id->ChainId.toString)
    }

    switch pending {
    | [] =>
      if announce {
        Logging.info("Reached the head. Preparing the database before serving queries.")
      }
      await storage.finalizeBackfill(~entities=persistence.allEntities, ~readyAt)
      true
    | _ =>
      // The pass comes back every `finalizeRetryIntervalMillis` while the wait
      // stands, so most of them are quiet. Waiting is the normal case — a big
      // chain's backfill runs for days — so it never escalates past info: once
      // when it starts, then a one-line heartbeat every
      // `finalizeWaitReportIntervalMillis` so the reason stays visible without
      // filling the log or reading as a fault.
      let waitMillis = state->IndexerState.finalizeWaitMillis
      let chains = pending->Array.joinUnsafe(", ")
      let message = {
        "msg": announce
          ? `Reached the head, but waiting for these chains to finish syncing before serving queries: ${chains}.`
          : `Still waiting for these chains to finish syncing: ${chains}. ${(waitMillis /.
              60_000.)->Float.toFixed(~digits=0)} minutes so far.`,
        "waitingFor": pending,
        "waitedSeconds": waitMillis /. 1000.,
      }
      // Evaluated before the `announce` shortcut, so the first pass stamps the
      // heartbeat clock rather than leaving the next pass finding it due.
      let isReportDue = state->IndexerState.isFinalizeWaitReportDue
      if announce || isReportDue {
        Logging.info(message)
      } else {
        Logging.trace(message)
      }
      false
    }
  }
)

let runOnce = async (state: IndexerState.t) => {
  // The phase is re-entered for as long as another chain holds it open, so the
  // user hears about it once and the passes that follow stay at debug. A resumed
  // realtime run is only here to rebuild an index the database lost, which is
  // nothing for the user to read about either.
  let announce = !(state->IndexerState.isRealtime) && !(state->IndexerState.hasAnnouncedFinalize)
  if announce {
    state->IndexerState.markFinalizeAnnounced
  }

  // Every pass, not just the first: the barrier below reads this process's own
  // row along with the rest, and a batch whose write is still queued would have
  // it reading its own stale progress.
  await Writing.flush(state)

  // A failed write already surfaced through onError; committing ready_at on top
  // of an incomplete write would claim progress that isn't durable.
  if !(state->IndexerState.hasFailedWrite) {
    let readyAt = Date.make()

    if await state->buildSchemaIndexesIfLast(~readyAt, ~announce) {
      // Only once the indexes are committed. Realtime is what tells the rest of
      // the process the database is ready to serve, so it must never run ahead
      // of them.
      if !(state->IndexerState.isRealtime) {
        state->IndexerState.markReady(~readyAt)
        Logging.info("Ready. Switching to realtime indexing.")
      }
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
// It is the same pass: a resumed realtime run is already ready, so it skips the
// announcing and the switch to realtime and does only the part that matters
// here — building whatever the schema is still missing.
//
// Only a database that lost an index while the indexer was down reaches it: a
// run that resumes realtime is a run whose `ready_at` is stamped, which only a
// completed build commits.
//
// Best-effort and not awaited by the loop: indexing is already live and correct
// without the indexes, just slower, and a failure here must not take the indexer
// down — nothing awaits this, so a rejection would otherwise reach the process's
// unhandled-rejection handler. Whatever it fails to build, the next restart owes
// again.
let repairSchemaIndexes = (state: IndexerState.t) =>
  run(state)->Promise.catch(async exn =>
    Logging.warn({
      "msg": "Couldn't finish preparing the database. Queries run slower until the next restart.",
      "err": exn->Utils.prettifyExn,
    })
  )
