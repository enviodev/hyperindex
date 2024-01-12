@@warning("-27")
module type S = {
  type t

  let make: (
    ~caughtUpToHeadHook: t => promise<unit>=?,
    ~contractAddressMapping: ContractAddressingMap.mapping=?,
    Config.chainConfig,
  ) => t

  let fetchArbitraryEvents: (
    t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock: int,
    ~fromLogIndex: int,
    ~toBlock: int,
    ~logger: Pino.t,
  ) => promise<array<Types.eventBatchQueueItem>>
}

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
