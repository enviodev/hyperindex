@@warnings("+27")

type sourceWorker = Config.source<HyperSyncWorker.t, RpcWorker.t>

let fetchArbitraryEvents = (
  _worker: sourceWorker,
  ~fromBlock as _fromBlock,
  ~fromLogIndex as _fromLogIndex,
  ~toBlock as _toBlock,
  ~logger as _logger,
  ~dynamicContracts as _dynamicContracts,
) => {
  Js.Exn.raiseError("Unhandled fetching arb events from hypersync ")
}

let getBlockHashes = (worker: sourceWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  switch worker {
  | Rpc(w) => w->RpcWorker.getBlockHashes
  | HyperSync(w) => w->HyperSyncWorker.getBlockHashes
  }
}
