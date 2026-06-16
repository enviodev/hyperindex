// Stage the per-chain metadata into the in-memory store. It's staged, not
// written: the next batch write folds the staged diff in.
let stage = (state: IndexerState.t) => {
  let chainsData: dict<InternalTable.Chains.metaFields> = Dict.make()

  state.chainManager.chainFetchers
  ->ChainMap.values
  ->Array.forEach(cf => {
    chainsData->Dict.set(
      cf.chainConfig.id->Int.toString,
      {
        firstEventBlockNumber: cf.fetchState.firstEventBlock->Null.fromOption,
        isHyperSync: (cf.sourceManager->SourceManager.getActiveSource).poweredByHyperSync,
        latestFetchedBlockNumber: cf.fetchState->FetchState.bufferBlockNumber,
        timestampCaughtUpToHeadOrEndblock: cf.timestampCaughtUpToHeadOrEndblock->Null.fromOption,
      },
    )
  })

  state.inMemoryStore->InMemoryStore.setChainMeta(chainsData)
}
