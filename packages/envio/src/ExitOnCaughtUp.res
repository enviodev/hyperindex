// Flush, then exit unless a reorg landed during the flush (which parks a
// rollback to recover instead).
let run = async (state: IndexerState.t) => {
  ChainMetadata.stage(state)
  await state.ctx.inMemoryStore->InMemoryStore.flush
  if !state.isStopped && !(state->IndexerState.isResolvingReorg) {
    Logging.info("Exiting with success")
    NodeJs.process->NodeJs.exitWithCode(Success)
  }
}
