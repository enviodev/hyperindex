open Belt
type t = {
  logger: Pino.t,
  fetchState: PartitionedFetchState.t,
  chainConfig: Config.chainConfig,
  chainWorker: module(ChainWorker.Type),
  //The latest known block of the chain
  currentBlockHeight: int,
  isFetchingBatch: bool,
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

let makeChainWorker = (~config, ~chainConfig: Config.chainConfig) => {
  switch chainConfig.syncSource {
  | HyperSync({endpointUrl})
  | HyperFuel({endpointUrl}) =>
    module(
      HyperSyncWorker.Make({
        let config = config
        let chainConfig = chainConfig
        let endpointUrl = endpointUrl
      }): ChainWorker.Type
    )
  | Rpc(rpcConfig) =>
    module(
      RpcWorker.Make({
        let config = config
        let chainConfig = chainConfig
        let rpcConfig = rpcConfig
      }): ChainWorker.Type
    )
  }
}

//CONSTRUCTION
let make = (
  ~config,
  ~chainConfig,
  ~lastBlockScannedHashes,
  ~staticContracts,
  ~dynamicContractRegistrations,
  ~startBlock,
  ~endBlock,
  ~firstEventBlockNumber,
  ~latestProcessedBlock,
  ~logger,
  ~timestampCaughtUpToHeadOrEndblock,
  ~numEventsProcessed,
  ~numBatchesFetched,
  ~eventFilters,
  ~maxAddrInPartition,
): t => {
  let chainWorker = makeChainWorker(~config, ~chainConfig)
  let module(ChainWorker) = chainWorker
  logger->Logging.childInfo("Initializing ChainFetcher with " ++ ChainWorker.name ++ " worker")

  let fetchState = PartitionedFetchState.make(
    ~maxAddrInPartition,
    ~staticContracts,
    ~dynamicContractRegistrations,
    ~startBlock,
    ~endBlock,
    ~logger,
  )

  {
    logger,
    chainConfig,
    chainWorker,
    lastBlockScannedHashes,
    currentBlockHeight: 0,
    isFetchingBatch: false,
    fetchState,
    firstEventBlockNumber,
    latestProcessedBlock,
    timestampCaughtUpToHeadOrEndblock,
    numEventsProcessed,
    numBatchesFetched,
    eventFilters,
  }
}

let getStaticContracts = (chainConfig: Config.chainConfig) => {
  chainConfig.contracts->Belt.Array.flatMap(contract => {
    contract.addresses->Belt.Array.map(address => {
      (contract.name, address)
    })
  })
}

let makeFromConfig = (chainConfig: Config.chainConfig, ~config, ~maxAddrInPartition) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chain->ChainMap.Chain.toChainId})
  let staticContracts = chainConfig->getStaticContracts
  let lastBlockScannedHashes = ReorgDetection.LastBlockScannedHashes.empty(
    ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
  )

  make(
    ~config,
    ~staticContracts,
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
    ~dynamicContractRegistrations=[],
    ~maxAddrInPartition,
  )
}

/**
 * This function allows a chain fetcher to be created from metadata, in particular this is useful for restarting an indexer and making sure it fetches blocks from the same place.
 */
let makeFromDbState = async (chainConfig: Config.chainConfig, ~config, ~maxAddrInPartition) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chain->ChainMap.Chain.toChainId})
  let staticContracts = chainConfig->getStaticContracts
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
  let dynamicContractRegistrations =
    await DbFunctions.sql->DbFunctions.DynamicContractRegistry.readDynamicContractsOnChainIdAtOrBeforeBlock(
      ~chainId,
      ~startBlock,
    )

  let (
    firstEventBlockNumber,
    latestProcessedBlockChainMetadata,
    numEventsProcessed,
    timestampCaughtUpToHeadOrEndblock,
  ) = switch chainMetadata {
  | Some({
      firstEventBlockNumber,
      latestProcessedBlock,
      numEventsProcessed,
      timestampCaughtUpToHeadOrEndblock,
    }) => (
      firstEventBlockNumber,
      latestProcessedBlock,
      numEventsProcessed,
      Env.updateSyncTimeOnRestart ? None : timestampCaughtUpToHeadOrEndblock->Js.Nullable.toOption,
    )
  | None => (None, None, None, None)
  }

  let endOfBlockRangeScannedData =
    await DbFunctions.sql->DbFunctions.EndOfBlockRangeScannedData.readEndOfBlockRangeScannedDataForChain(
      ~chainId,
    )

  let lastBlockScannedHashes =
    endOfBlockRangeScannedData
    ->Array.map(({blockNumber, blockHash, blockTimestamp}) => {
      ReorgDetection.blockNumber,
      blockHash,
      blockTimestamp,
    })
    ->ReorgDetection.LastBlockScannedHashes.makeWithData(
      ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
    )

  //TODO create filter to only accept events with blockNumber AND logIndex
  //higher than stored in chain blockNumber, blockHash, blockTimestamp
  let eventFilters = None

  make(
    ~config,
    ~staticContracts,
    ~dynamicContractRegistrations,
    ~chainConfig,
    ~startBlock,
    ~endBlock=chainConfig.endBlock,
    ~lastBlockScannedHashes,
    ~firstEventBlockNumber,
    ~latestProcessedBlock=latestProcessedBlockChainMetadata,
    ~timestampCaughtUpToHeadOrEndblock,
    ~numEventsProcessed=numEventsProcessed->Option.getWithDefault(0),
    ~numBatchesFetched=0,
    ~logger,
    ~eventFilters,
    ~maxAddrInPartition,
  )
}

/**
Adds an event filter that will be passed to worker on query
isValid is a function that determines when the filter
should be cleaned up
*/
let addEventFilter = (self: t, ~filter, ~isValid) => {
  let eventFilters =
    self.eventFilters
    ->Option.getWithDefault(list{})
    ->List.add({filter, isValid})
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
        self.fetchState->PartitionedFetchState.eventFilterIsValid(
          ~eventFilter,
          ~chain=self.chainConfig.chain,
        )
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
  ~currentBlockHeight,
) => {
  self.fetchState
  ->PartitionedFetchState.update(
    ~id,
    ~latestFetchedBlock={
      blockNumber: latestFetchedBlockNumber,
      blockTimestamp: latestFetchedBlockTimestamp,
    },
    ~fetchedEvents,
    ~currentBlockHeight,
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

  cleanedChainFetcher.fetchState->PartitionedFetchState.getNextQuery(
    ~eventFilters=?cleanedChainFetcher.eventFilters,
    ~currentBlockHeight=cleanedChainFetcher.currentBlockHeight,
  )
}

/**
Gets the latest item on the front of the queue and returns updated fetcher
*/
let hasProcessedToEndblock = (self: t) => {
  let {latestProcessedBlock, chainConfig: {endBlock}} = self
  switch (latestProcessedBlock, endBlock) {
  | (Some(latestProcessedBlock), Some(endBlock)) => latestProcessedBlock >= endBlock
  | _ => false
  }
}

/**
Finds the last known block where hashes are valid and returns
the updated lastBlockScannedHashes rolled back where this occurs
*/
let rollbackLastBlockHashesToReorgLocation = async (
   chainFetcher: t,
  //Parameter used for dependency injecting in tests
  ~getBlockHashes as getBlockHashesMock=? // FIXME: Mock chainWorker instead
) => {
  //get a list of block hashes via the chainworker
  let blockNumbers =
    chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.getAllBlockNumbers

  let module(ChainWorker) = chainFetcher.chainWorker

  let getBlockHashes = switch getBlockHashesMock {
  | Some(getBlockHashes) => getBlockHashes
  | None => ChainWorker.getBlockHashes
  }

  let blockNumbersAndHashes = await getBlockHashes(
    ~blockNumbers,
  )->Promise.thenResolve(res =>
    switch res {
    | Ok(v) => v
    | Error(exn) =>
      exn->ErrorHandling.mkLogAndRaise(
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
    fetchState: chainFetcher.fetchState->PartitionedFetchState.rollback(~lastKnownValidBlock),
  }
}

let isFetchingAtHead = (chainFetcher: t) =>
  chainFetcher.fetchState->PartitionedFetchState.isFetchingAtHead
