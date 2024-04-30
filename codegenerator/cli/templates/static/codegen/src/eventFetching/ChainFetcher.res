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
  //An optional list of filters to apply on event queries
  //Used for reorgs and restarts
  eventFilters: option<FetchState.eventFilters>,
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
  ~eventFilters,
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
    eventFilters,
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
    ~eventFilters=None,
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

  //TODO create filter to only accept events with blockNumber AND logIndex
  //higher than stored in chain metadata
  let eventFilters = None

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
    ~eventFilters,
  )
}

/**
Adds an event filter that will be passed to worker on query
cleanUpCondition is a function that determines when the filter
is no longer valid and can be cleaned
*/
let addEventFilter = (self: t, ~filter, ~cleanUpCondition) => {
  let eventFilters =
    self.eventFilters
    ->Option.getWithDefault(list{})
    ->List.add({filter, isNoLongerValid: cleanUpCondition})
    ->Some
  {...self, eventFilters}
}

let cleanUpEventFilters = (self: t) => {
  switch self.eventFilters {
  //Only spread if there are eventFilters
  | None => self

  //Run the clean up condition "isNoLongerValid" against fetchState on each eventFilter and remove
  //any that meet the cleanup condition
  | Some(eventFilters) => {
      ...self,
      eventFilters: switch eventFilters->List.keep(eventFilter =>
        !eventFilter.isNoLongerValid(self.fetchState)
      ) {
      | list{} => None
      | eventFilters => eventFilters->Some
      },
    }
  }
}

/**
Updates of fetchState and cleans up event filters. Should be used whenever updating fetchState
to ensure eventFilters are always valid.
Returns Error if the node with given id cannot be found (unexpected)
*/
let updateFetchState = (
  self: t,
  ~id,
  ~latestFetchedBlockTimestamp,
  ~latestFetchedBlockNumber,
  ~fetchedEvents,
) => {
  self.fetchState
  ->FetchState.update(
    ~id,
    ~latestFetchedBlock={
      blockNumber: latestFetchedBlockNumber,
      blockTimestamp: latestFetchedBlockTimestamp,
    },
    ~fetchedEvents,
  )
  ->Result.map(fetchState => {
    {...self, fetchState}->cleanUpEventFilters
  })
}

/**
Gets the next query either with a to block of the current height if it is the root node.
Or with a toBlock of the nextRegistered latestBlockNumber to catch up and merge with the next regisetered.

Applies any event filters found in the chain fetcher

Errors if nextRegistered dynamic contract has a lower latestFetchedBlock than the current as this would be
an invalid state.
*/
let getNextQuery = (self: t) => {
  //Chain Fetcher should have already cleaned up stale event filters by the time this
  //is called but just ensure its cleaned before getting the next query
  let cleanedChainFetcher = self->cleanUpEventFilters

  cleanedChainFetcher.fetchState->FetchState.getNextQuery(
    ~eventFilters=?cleanedChainFetcher.eventFilters,
    ~currentBlockHeight=cleanedChainFetcher.currentBlockHeight,
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
    ->Promise.thenResolve(res =>
      switch res {
      | Ok(v) => v
      | Error(exn) =>
        exn->ErrorHandling.logAndRaise(
          ~msg="Failed to fetch blockHashes for given blockNumbers during rollback",
        )
      }
    )

  chainFetcher.lastBlockScannedHashes
  ->ReorgDetection.LastBlockScannedHashes.rollBackToValidHash(~blockNumbersAndHashes)
  ->Utils.unwrapResultExn
}

let getLastScannedBlockData = lastBlockData => {
  lastBlockData
  ->ReorgDetection.LastBlockScannedHashes.getLatestLastBlockData
  ->Option.mapWithDefault({FetchState.blockNumber: 0, blockTimestamp: 0}, ({
    blockNumber,
    blockTimestamp,
  }) => {
    blockNumber,
    blockTimestamp,
  })
}

let rollbackToLastBlockHashes = (chainFetcher: t, ~rolledBackLastBlockData) => {
  let lastKnownValidBlock = rolledBackLastBlockData->getLastScannedBlockData
  {
    ...chainFetcher,
    lastBlockScannedHashes: rolledBackLastBlockData,
    fetchState: chainFetcher.fetchState->FetchState.rollback(~lastKnownValidBlock),
  }
}
