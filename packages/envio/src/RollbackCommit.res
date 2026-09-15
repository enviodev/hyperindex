// Temporary, internal-only support for the unstable
// `indexer.~internalAndWillBeRemovedSoon_onRollbackCommit` API. The whole
// feature lives here plus two call sites: registration in `Main.res` and the
// fire on a successful rollback write in `InMemoryStore.res`. Delete those
// together with this module.
type args = {chainId: ChainId.t, rollbackToBlock: int}
type callback = args => promise<unit>

// Lives in the process-wide `EnvioGlobal` record so callbacks registered
// through a duplicate envio module instance still fire.
let callbacks =
  EnvioGlobal.value.rollbackCommitCallbacks->(Utils.magic: array<unknown> => array<callback>)

let register = (callback: callback) => {
  callbacks->Array.push(callback)
  () =>
    switch callbacks->Array.indexOf(callback) {
    | -1 => ()
    | index => callbacks->Array.splice(~start=index, ~remove=1, ~insert=[])
    }
}

// Fired after a rollback diff is durably written, once per affected chain, with
// the last valid block the rollback left that chain at. A throwing callback
// bubbles to the write loop's onError, crashing the indexer like a failed write.
let fire = async (~progressedChains: array<InternalTable.Chains.progressedChain>) => {
  let _ = await progressedChains
  ->Array.flatMap(({chainId, progressBlockNumber}) => {
    let args = {chainId, rollbackToBlock: progressBlockNumber}
    callbacks->Array.map(callback => callback(args))
  })
  ->Promise.all
}
