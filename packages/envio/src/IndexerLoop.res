// The indexer run loop: it owns scheduling and wires the operation modules
// together. Each operation (ChainFetching, BatchProcessing, Rollback) is handed
// the schedule* effects it needs to re-enter the loop; this is the only module
// that knows how they connect. State and its transitions live in IndexerState.

// Fire-and-forget an async step, counted as in-flight until it settles. Every
// launchable owns its error boundary, so there's no rejection to swallow here.
@inline
let launch = (state: IndexerState.t, work: unit => promise<unit>) =>
  if !(state->IndexerState.isStopped) {
    state->IndexerState.trackInFlight(work)->Promise.ignore
  }

// Kick off the indexer loops. The schedule* effects are mutually recursive
// (fetch kicks process/rollback, which kick fetch again), so they're defined as
// one `let rec` block and threaded into the operations as the only way back in.
let start = (state: IndexerState.t) => {
  // `checkAndFetch` decides what to fetch and dispatches one per chain, so each
  // chain's fetch is a unit of work in its own right; this frame covers only
  // the decision.
  let rec scheduleFetch = () =>
    launch(state, async () =>
      state
      ->IndexerState.crossChainState
      ->CrossChainState.checkAndFetch(~dispatchChain=(~chainId, ~action) =>
        state->IndexerState.trackInFlight(() =>
          ChainFetching.fetchChain(
            state,
            chainId,
            ~action,
            ~stateId=state->IndexerState.epoch,
            ~scheduleFetch,
            ~scheduleProcessing,
            ~scheduleRollback,
          )
        )
      )
    )
  and scheduleProcessing = () =>
    launch(state, () => BatchProcessing.startProcessing(state, ~scheduleFetch, ~scheduleRollback))
  and scheduleRollback = () =>
    launch(state, () =>
      Rollback.rollback(state, ~scheduleFetch, ~scheduleProcessing, ~scheduleRollback)
    )

  // Resuming already ready means the FinalizingIndexes phase is behind us and
  // won't run again, so this is the only pass that can restore an index the
  // database lost while the indexer was down.
  if state->IndexerState.isRealtime {
    launch(state, () => FinalizeBackfill.repairSchemaIndexes(state))
  }

  scheduleFetch()
  scheduleProcessing()
}
