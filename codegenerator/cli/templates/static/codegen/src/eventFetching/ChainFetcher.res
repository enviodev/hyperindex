type t = {
  logger: Pino.t,
  fetcher: DynamicContractFetcher.t,
  chainConfig: Config.chainConfig,
  chainWorker: ChainWorkerTypes.chainWorker,
  //The latest known block of the chain
  currentBlockHeight: int,
  isFetchingBatch: bool,
  mutable lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.t,
}

//CONSTRUCTION
let make = (~chainConfig: Config.chainConfig, ~lastBlockScannedHashes): t => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chain})

  let contractAddressMapping = {
    let m = ContractAddressingMap.make()
    //Add all contracts and addresses from config
    //Dynamic contracts are checked in DB on start
    m->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)
    m
  }

  let chainWorker = switch chainConfig.syncSource {
  | HyperSync(serverUrl) => chainConfig->HyperSyncWorker.make(~serverUrl)->Config.HyperSync
  | Rpc(rpcConfig) => chainConfig->RpcWorker.make(~rpcConfig)->Rpc
  }

  {
    logger,
    chainConfig,
    chainWorker,
    lastBlockScannedHashes,
    currentBlockHeight: 0,
    isFetchingBatch: false,
    fetcher: DynamicContractFetcher.makeRoot(~contractAddressMapping),
  }
}

/**
Gets the latest item on the front of the queue and returns updated fetcher
*/
let getLatestItem = (self: t) => {
  self.fetcher->DynamicContractFetcher.getEarliestEvent
}

type latestFetchedBlockTimestamp = int
type queueFront =
  | NoItem(latestFetchedBlockTimestamp, ChainMap.Chain.t)
  | Item(Types.eventBatchQueueItem)
