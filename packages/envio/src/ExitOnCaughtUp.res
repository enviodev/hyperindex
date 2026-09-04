// Flush, then exit unless a reorg landed during the flush (which parks a
// rollback to recover instead).
let run = async (state: IndexerState.t) => {
  ChainMetadata.stage(state)
  await state->Writing.flush
  if !(state->IndexerState.isStopped) && !(state->IndexerState.isResolvingReorg) {
    // A simulate run fails here when a provided item never reached a handler —
    // dead test code. The tracker is None (a no-op) off the simulate path.
    switch state
    ->IndexerState.simulateDeadInputTracker
    ->Option.flatMap(SimulateDeadInputTracker.failureMessage) {
    | None =>
      switch state->IndexerState.onExit {
      | Some(onExit) => onExit()
      | None =>
        Logging.info("Exiting with success")
        NodeJs.process->NodeJs.exitWithCode(Success)
      }
    | Some(message) => state->IndexerState.errorExit(ErrorHandling.make(Utils.Error.make(message)))
    }
  }
}
