// Temporary, internal-only support for the unstable
// `indexer.~internalAndWillBeRemovedSoon_onRollbackCommit` API. The whole
// feature lives here plus three call sites: registration in `Main.res`, the
// per-chain block snapshot in `GlobalState.res`, and the fire on a successful
// rollback write in `InMemoryStore.res`. Delete those together with this module.
type args = {chainId: int, rollbackToBlock: int}
type callback = args => promise<unit>

let callbacks: array<callback> = []

// Last valid block per chain affected by the pending rollback. Set when the
// rollback diff is staged, read by the write that flushes it.
let pendingProgressBlockNumberByChainId: ref<dict<int>> = ref(Dict.make())

let register = (callback: callback) => {
  callbacks->Array.push(callback)
  () =>
    switch callbacks->Array.indexOf(callback) {
    | -1 => ()
    | index => callbacks->Array.splice(~start=index, ~remove=1, ~insert=[])
    }
}

let setPending = (progressBlockNumberByChainId: dict<int>) => {
  pendingProgressBlockNumberByChainId := progressBlockNumberByChainId
}

// Fired after a rollback diff is durably written. A throwing callback bubbles to
// the write loop's onError, crashing the indexer like a failed write.
let fire = async () => {
  let _ = await pendingProgressBlockNumberByChainId.contents
  ->Dict.toArray
  ->Array.flatMap(((chainIdKey, rollbackToBlock)) => {
    let args = {chainId: chainIdKey->Int.fromString->Option.getUnsafe, rollbackToBlock}
    callbacks->Array.map(callback => callback(args))
  })
  ->Promise.all
}
