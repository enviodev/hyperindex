// Flush, then exit unless a reorg landed during the flush (which parks a
// rollback to recover instead).
let run = async (state: IndexerState.t) => {
  ChainMetadata.stage(state)
  await state->Writing.flush
  if !(state->IndexerState.isStopped) && !(state->IndexerState.isResolvingReorg) {
    // A simulate run tracks the items a test fed in and drops each as it reaches a
    // handler. Anything left never ran — fail loudly instead of exiting clean, since
    // a simulate input that runs nothing is dead test code. Empty off the simulate path.
    switch state
    ->IndexerState.simulateDeadInputTracker
    ->Option.mapOr([], SimulateDeadInputTracker.unroutedByChain) {
    | [] =>
      Logging.info("Exiting with success")
      NodeJs.process->NodeJs.exitWithCode(Success)
    | byChain =>
      let count =
        byChain->Array.reduce(0, (acc, (_chainId, indices)) => acc + indices->Array.length)
      let itemWord = count === 1 ? "item" : "items"
      let lines =
        byChain
        ->Array.map(((chainId, indices)) =>
          `  - chain ${chainId->Int.toString}: ${indices
            ->Array.map(index => index->Int.toString)
            ->Array.join(", ")}`
        )
        ->Array.join("\n")
      state->IndexerState.errorExit(
        ErrorHandling.make(
          Utils.Error.make(
            `simulate: ${count->Int.toString} ${itemWord} you passed to simulate never reached a handler, so nothing ran for them. Each was filtered out before the handler — usually a non-wildcard srcAddress that isn't indexed for the contract, or a where/block filter that excluded the event. Unrouted items, by index in each chain's simulate array:\n${lines}`,
          ),
        ),
      )
    }
  }
}
