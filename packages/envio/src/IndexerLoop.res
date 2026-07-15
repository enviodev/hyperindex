// The indexer run loop: it owns scheduling and wires the operation modules
// together. Each operation (ChainFetching, BatchProcessing, Rollback) is handed
// the schedule* effects it needs to re-enter the loop; this is the only module
// that knows how they connect. State and its transitions live in IndexerState.

// Fire-and-forget an async step. Every launchable owns a try/catch that routes
// failures to errorExit, so there's no rejection to swallow here.
@inline
let launch = (state: IndexerState.t, work: unit => promise<unit>) =>
  if !(state->IndexerState.isStopped) {
    work()->Promise.ignore
  }

// Kick off the indexer loops. The schedule* effects are mutually recursive
// (fetch kicks process/rollback, which kick fetch again), so they're defined as
// one `let rec` block and threaded into the operations as the only way back in.
let start = (state: IndexerState.t) => {
  let rec scheduleFetch = () =>
    launch(state, () =>
      state
      ->IndexerState.crossChainState
      ->CrossChainState.checkAndFetch(~dispatchChain=(~chain, ~action) =>
        ChainFetching.fetchChain(
          state,
          chain,
          ~action,
          ~stateId=state->IndexerState.epoch,
          ~scheduleFetch,
          ~scheduleProcessing,
          ~scheduleRegistration,
          ~scheduleRollback,
        )
      )
    )
  and scheduleProcessing = () =>
    launch(state, () => BatchProcessing.startProcessing(state, ~scheduleFetch, ~scheduleRollback))
  and scheduleRegistration = () =>
    launch(state, () =>
      ContractRegistration.startRegistering(state, ~scheduleFetch, ~scheduleProcessing)
    )
  and scheduleRollback = () =>
    launch(state, () =>
      Rollback.rollback(
        state,
        ~scheduleFetch,
        ~scheduleProcessing,
        ~scheduleRegistration,
        ~scheduleRollback,
      )
    )

  scheduleFetch()
  scheduleProcessing()
}
