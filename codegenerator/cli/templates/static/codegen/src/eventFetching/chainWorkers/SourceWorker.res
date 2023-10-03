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

module SkarWorker: S = HyperSyncWorker.Make(HyperSync.SkarHyperSync)
module EthArchiveWorker: S = HyperSyncWorker.Make(HyperSync.EthArchiveHyperSync)

type sourceWorker =
  | Rpc(RpcWorker.t)
  | Skar(SkarWorker.t)
  | EthArchive(EthArchiveWorker.t)

let fetchArbitraryEvents = (worker: sourceWorker) => {
  //See note in description of PolyMorphicChainWorkerFunctions
  switch worker {
  | Rpc(w) => w->RpcWorker.fetchArbitraryEvents
  | Skar(w) => w->SkarWorker.fetchArbitraryEvents
  | EthArchive(w) => w->EthArchiveWorker.fetchArbitraryEvents
  }
}
