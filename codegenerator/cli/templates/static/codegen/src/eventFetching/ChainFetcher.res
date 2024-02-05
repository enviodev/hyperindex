type t = {
  logger: Pino.t,
  fetcher: DynamicContractFetcher.t,
  chainConfig: Config.chainConfig,
  chainWorker: SourceWorker.sourceWorker,
  //The latest known block of the chain
  currentBlockHeight: int,
  isFetchingBatch: bool,
  mutable lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.t,
}

//CONSTRUCTION
let make = (
  ~chainConfig: Config.chainConfig,
  ~lastBlockScannedHashes,
  ~contractAddressMapping,
  ~startBlock,
  ~logger,
): t => {
  let chainWorker = switch chainConfig.syncSource {
  | HyperSync(serverUrl) => chainConfig->HyperSyncWorker.make(~serverUrl)->Config.HyperSync
  | Rpc(rpcConfig) => chainConfig->RpcWorker.make(~rpcConfig)->Rpc
  }
  let fetcher = DynamicContractFetcher.makeRoot(~contractAddressMapping, ~startBlock)
  {
    logger,
    chainConfig,
    chainWorker,
    lastBlockScannedHashes,
    currentBlockHeight: 0,
    isFetchingBatch: false,
    fetcher,
  }
}

let makeFromConfig = (chainConfig: Config.chainConfig, ~lastBlockScannedHashes) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chain->ChainMap.Chain.toChainId})
  let contractAddressMapping = {
    let m = ContractAddressingMap.make()
    //Add all contracts and addresses from config
    //Dynamic contracts are checked in DB on start
    m->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)
    m
  }

  make(
    ~contractAddressMapping,
    ~chainConfig,
    ~startBlock=chainConfig.startBlock,
    ~lastBlockScannedHashes,
    ~logger,
  )
}

let makeFromDbState = async (chainConfig: Config.chainConfig, ~lastBlockScannedHashes) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chain->ChainMap.Chain.toChainId})
  let contractAddressMapping = {
    let m = ContractAddressingMap.make()
    //Add all contracts and addresses from config
    //Dynamic contracts are checked in DB on start
    m->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)
    m
  }
  let chainId = chainConfig.chain->ChainMap.Chain.toChainId
  let latestProcessedBlock = await DbFunctions.EventSyncState.getLatestProcessedBlockNumber(
    ~chainId,
  )

  let startBlock =
    latestProcessedBlock->Belt.Option.mapWithDefault(chainConfig.startBlock, latestProcessedBlock =>
      latestProcessedBlock + 1
    )

  //Add all dynamic contracts from DB
  let dynamicContracts =
    await DbFunctions.sql->DbFunctions.DynamicContractRegistry.readDynamicContractsOnChainIdAtOrBeforeBlock(
      ~chainId,
      ~startBlock,
    )

  dynamicContracts->Belt.Array.forEach(({contractType, contractAddress}) =>
    contractAddressMapping->ContractAddressingMap.addAddress(
      ~name=contractType,
      ~address=contractAddress,
    )
  )

  make(~contractAddressMapping, ~chainConfig, ~startBlock, ~lastBlockScannedHashes, ~logger)
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
