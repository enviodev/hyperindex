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
    // Simulate runs collect non-wildcard items the address filter dropped. If one
    // never reached its handler, fail loudly instead of exiting clean — a simulate
    // input that runs nothing is dead test code. Always empty off the simulate path.
    switch state
    ->IndexerState.chainStates
    ->Dict.valuesToArray
    ->Array.flatMap(cs => cs->ChainState.skippedSimulateItems) {
    | [] =>
      Logging.info("Exiting with success")
      NodeJs.process->NodeJs.exitWithCode(Success)
    | skipped =>
      state->IndexerState.errorExit(
        ErrorHandling.make(
          Utils.Error.make(
            `simulate: ${skipped
              ->Array.length
              ->Int.toString} event(s) were never routed to a handler — their srcAddress isn't indexed for the contract on this chain (after config addresses, earlier process() calls, and registrations in this run). Register the contract before the event, pass a configured or registered srcAddress, or use a wildcard event. Skipped: ${skipped
              ->Array.map(describeSkippedItem)
              ->Array.join("; ")}`,
          ),
        ),
      )
    }
  }
}
