@@warnings("+27")

type sourceWorker =
  | Rpc(RpcWorker.t)
  | HyperSync(HyperSyncWorker.t)

let fetchArbitraryEvents = (worker: sourceWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  switch worker {
  | Rpc(w) => w->RpcWorker.fetchArbitraryEvents
  | HyperSync(w) => w->HyperSyncWorker.fetchArbitraryEvents
  }
}

let getBlockHashes = (worker: sourceWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  switch worker {
  | Rpc(w) => w->RpcWorker.getBlockHashes
  | HyperSync(w) => w->HyperSyncWorker.getBlockHashes
  }
}
