// Stage the per-chain metadata into the in-memory store. It's staged, not
// written: the next batch write folds the staged diff in.
let stage = (state: IndexerState.t) => {
  let chainsData: dict<InternalTable.Chains.metaFields> = Dict.make()

  state
  ->IndexerState.chainStates
  ->Dict.valuesToArray
  ->Array.forEach(cs => {
    let fetchState = cs->ChainState.fetchState
    chainsData->Dict.set(
      (cs->ChainState.chainConfig).id->Int.toString,
      {
        firstEventBlockNumber: fetchState.firstEventBlock->Null.fromOption,
        isHyperSync: (
          cs->ChainState.sourceManager->SourceManager.getActiveSource
        ).poweredByHyperSync,
        latestFetchedBlockNumber: fetchState->FetchState.bufferBlockNumber,
        timestampCaughtUpToHeadOrEndblock: cs
        ->ChainState.timestampCaughtUpToHeadOrEndblock
        ->Null.fromOption,
      },
    )
  })

  state->Writing.setChainMeta(chainsData)
}
