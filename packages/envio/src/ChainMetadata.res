// Stage the per-chain metadata into the in-memory store. It's staged, not
// written: the next batch write folds the staged diff in.
let stage = (state: IndexerState.t) => {
  let chainsData: dict<InternalTable.Chains.metaFields> = Dict.make()

  state
  ->IndexerState.chainStates
  ->Dict.valuesToArray
  ->Array.forEach(cs => {
    chainsData->Dict.set(
      (cs->ChainState.chainConfig).id->Int.toString,
      cs->ChainState.toChainMetadata,
    )
  })

  state->Writing.setChainMeta(chainsData)
}
