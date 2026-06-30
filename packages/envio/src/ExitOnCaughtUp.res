let describeSkippedItem = (item: Internal.item): string =>
  switch item {
  | Internal.Event({eventConfig, blockNumber, chain, payload}) =>
    let srcAddress = (
      payload->(Utils.magic: Internal.eventPayload => {"srcAddress": Address.t})
    )["srcAddress"]
    `${eventConfig.contractName}.${eventConfig.name} (srcAddress ${srcAddress->Address.toString}, chain ${chain
      ->ChainMap.Chain.toChainId
      ->Int.toString}, block ${blockNumber->Int.toString})`
  | _ => "unknown item"
  }

// Flush, then exit unless a reorg landed during the flush (which parks a
// rollback to recover instead).
let run = async (state: IndexerState.t) => {
  ChainMetadata.stage(state)
  await state->Writing.flush
  if !(state->IndexerState.isStopped) && !(state->IndexerState.isResolvingReorg) {
    // A simulate run tracks the items a test fed in and drops each as it reaches a
    // handler. Anything left never ran — fail loudly instead of exiting clean, since
    // a simulate input that runs nothing is dead test code. None off the simulate path.
    switch state
    ->IndexerState.simulateDeadInputTracker
    ->Option.mapOr([], SimulateDeadInputTracker.unprocessedItems) {
    | [] =>
      Logging.info("Exiting with success")
      NodeJs.process->NodeJs.exitWithCode(Success)
    | skipped =>
      state->IndexerState.errorExit(
        ErrorHandling.make(
          Utils.Error.make(
            `simulate: ${skipped
              ->Array.length
              ->Int.toString} item(s) provided to simulate never reached a handler (filtered out first — e.g. a non-wildcard srcAddress not indexed for the contract, or a where/block filter that excluded the event). Skipped: ${skipped
              ->Array.map(describeSkippedItem)
              ->Array.join("; ")}`,
          ),
        ),
      )
    }
  }
}
