open Belt
type t = {
  logger: Pino.t,
  fetchState: FetchState.t,
  chainConfig: Config.chainConfig,
  chainWorker: SourceWorker.sourceWorker,
  //The latest known block of the chain
  currentBlockHeight: int,
  isFetchingBatch: bool,
  isFetchingAtHead: bool,
  hasProcessedToEndblock: bool,
  timestampCaughtUpToHeadOrEndblock: option<Js.Date.t>,
  firstEventBlockNumber: option<int>,
  latestProcessedBlock: option<int>,
  numEventsProcessed: int,
  numBatchesFetched: int,
  lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.t,
}

//CONSTRUCTION
let make = (
  ~chainConfig: Config.chainConfig,
  ~lastBlockScannedHashes,
  ~contractAddressMapping,
  ~startBlock,
  ~endBlock,
  ~firstEventBlockNumber,
  ~latestProcessedBlock,
  ~logger,
  ~timestampCaughtUpToHeadOrEndblock,
  ~numEventsProcessed,
  ~numBatchesFetched,
): t => {
  let (endpointDescription, chainWorker) = switch chainConfig.syncSource {
  | HyperSync(serverUrl) => (
      "HyperSync",
      chainConfig->HyperSyncWorker.make(~serverUrl)->Config.HyperSync,
    )
  | Rpc(rpcConfig) => ("RPC", chainConfig->RpcWorker.make(~rpcConfig)->Rpc)
  }
  logger->Logging.childInfo("Initializing ChainFetcher with " ++ endpointDescription)
  let fetchState = FetchState.makeRoot(~contractAddressMapping, ~startBlock, ~endBlock)
  {
    logger,
    chainConfig,
    chainWorker,
    lastBlockScannedHashes,
    currentBlockHeight: 0,
    isFetchingBatch: false,
    isFetchingAtHead: false,
    hasProcessedToEndblock: false,
    fetchState,
    firstEventBlockNumber,
    latestProcessedBlock,
    timestampCaughtUpToHeadOrEndblock,
    numEventsProcessed,
    numBatchesFetched,
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
    ~endBlock=chainConfig.endBlock,
    ~lastBlockScannedHashes,
    ~firstEventBlockNumber=None,
    ~latestProcessedBlock=None,
    ~timestampCaughtUpToHeadOrEndblock=None,
    ~numEventsProcessed=0,
    ~numBatchesFetched=0,
    ~logger,
  )
}

/**
 * This function allows a chain fetcher to be created from metadata, in particular this is useful for restarting an indexer and making sure it fetches blocks from the same place.
 */
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

  let chainMetadata = await DbFunctions.ChainMetadata.getLatestChainMetadataState(~chainId)

  let startBlock =
    latestProcessedBlock->Option.mapWithDefault(chainConfig.startBlock, latestProcessedBlock =>
      latestProcessedBlock + 1
    )

  //Add all dynamic contracts from DB
  let dynamicContracts =
    await DbFunctions.sql->DbFunctions.DynamicContractRegistry.readDynamicContractsOnChainIdAtOrBeforeBlock(
      ~chainId,
      ~startBlock,
    )

  dynamicContracts->Array.forEach(({contractType, contractAddress}) =>
    contractAddressMapping->ContractAddressingMap.addAddress(
      ~name=contractType,
      ~address=contractAddress,
    )
  )
  let (
    firstEventBlockNumber,
    latestProcessedBlockChainMetadata,
    numEventsProcessed,
  ) = switch chainMetadata {
  | Some({firstEventBlockNumber, latestProcessedBlock, numEventsProcessed}) => (
      firstEventBlockNumber,
      latestProcessedBlock,
      numEventsProcessed,
    )
  | None => (None, None, None)
  }

  make(
    ~contractAddressMapping,
    ~chainConfig,
    ~startBlock,
    ~endBlock=chainConfig.endBlock,
    ~lastBlockScannedHashes,
    ~firstEventBlockNumber,
    ~latestProcessedBlock=latestProcessedBlockChainMetadata,
    ~timestampCaughtUpToHeadOrEndblock=None, // recalculate this on startup
    ~numEventsProcessed=numEventsProcessed->Option.getWithDefault(0),
    ~numBatchesFetched=0,
    ~logger,
  )
}

/**
Gets the latest item on the front of the queue and returns updated fetcher
*/
let getLatestItem = (self: t) => {
  self.fetchState->FetchState.getEarliestEvent
}

/**
Finds the last known block where hashes are valid and returns
the updated lastBlockScannedHashes rolled back where this occurs
*/
let rollbackLastBlockHashesToReorgLocation = async (
  //Parameter used for dependency injecting in tests
  ~getBlockHashes=SourceWorker.getBlockHashes,
  chainFetcher: t,
) => {
  //get a list of block hashes via the chainworker
  let blockNumbers =
    chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.getAllBlockNumbers

  let blockNumbersAndHashes =
    await chainFetcher.chainWorker
    ->getBlockHashes(~blockNumbers)
    ->Promise.thenResolve(Result.getExn)

  chainFetcher.lastBlockScannedHashes
  ->ReorgDetection.LastBlockScannedHashes.rollBackToValidHash(~blockNumbersAndHashes)
  ->Utils.unwrapResultExn
}

type lastScannedBlockData = {
  blockNumber: int,
  blockTimestamp: int,
}

let getLastScannedBlockData = lastBlockData => {
  lastBlockData
  ->ReorgDetection.LastBlockScannedHashes.getLatestLastBlockData
  ->Option.mapWithDefault({blockNumber: 0, blockTimestamp: 0}, ({blockNumber, blockTimestamp}) => {
    blockNumber,
    blockTimestamp,
  })
}

let rollbackToLastBlockHashes = (chainFetcher: t, ~rolledBackLastBlockData) => {
  let {blockNumber, blockTimestamp} = rolledBackLastBlockData->getLastScannedBlockData
  {
    ...chainFetcher,
    lastBlockScannedHashes: rolledBackLastBlockData,
    fetchState: chainFetcher.fetchState->FetchState.rollback(~blockNumber, ~blockTimestamp),
  }
}
