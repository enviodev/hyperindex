type sourceWorker = Config.source<HyperSyncWorker.t, HyperSyncWorker.t, RpcWorker.t>

let getBlockHashes = (worker: sourceWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  switch worker {
  | Rpc(w) => w->RpcWorker.getBlockHashes
  | HyperSync(w) => w->HyperSyncWorker.getBlockHashes
  | HyperFuel(w) => w->HyperSyncWorker.getBlockHashes
  }
}
