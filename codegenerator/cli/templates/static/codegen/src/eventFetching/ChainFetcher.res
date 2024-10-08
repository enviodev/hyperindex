open Belt

type addressToDynContractLookup = dict<TablesStatic.DynamicContractRegistry.t>
type t = {
  logger: Pino.t,
  fetchState: PartitionedFetchState.t,
  chainConfig: Config.chainConfig,
  //The latest known block of the chain
  currentBlockHeight: int,
  partitionsCurrentlyFetching: PartitionedFetchState.partitionIndexSet,
  timestampCaughtUpToHeadOrEndblock: option<Js.Date.t>,
  dbFirstEventBlockNumber: option<int>,
  latestProcessedBlock: option<int>,
  numEventsProcessed: int,
  numBatchesFetched: int,
  lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.t,
  //An optional list of filters to apply on event queries
  //Used for reorgs and restarts
  eventFilters: option<FetchState.eventFilters>,
  //Currently this state applies to all chains simultaneously but it may be possible to,
  //in the future, have a per chain state and allow individual chains to start indexing as
  //soon as the pre registration is done
  dynamicContractPreRegistration: option<addressToDynContractLookup>,
}

//CONSTRUCTION
let make = (
  ~chainConfig: Config.chainConfig,
  ~lastBlockScannedHashes,
  ~staticContracts,
  ~dynamicContractRegistrations,
  ~startBlock,
  ~endBlock,
  ~dbFirstEventBlockNumber,
  ~latestProcessedBlock,
  ~logger,
  ~timestampCaughtUpToHeadOrEndblock,
  ~numEventsProcessed,
  ~numBatchesFetched,
  ~eventFilters,
  ~maxAddrInPartition,
  ~dynamicContractPreRegistration,
): t => {
  let module(ChainWorker) = chainConfig.chainWorker
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
    lastBlockScannedHashes,
    currentBlockHeight: 0,
    fetchState,
    dbFirstEventBlockNumber,
    latestProcessedBlock,
    timestampCaughtUpToHeadOrEndblock,
    numEventsProcessed,
    numBatchesFetched,
    eventFilters,
    partitionsCurrentlyFetching: Belt.Set.Int.empty,
    dynamicContractPreRegistration,
  }
}

let getStaticContracts = (chainConfig: Config.chainConfig) => {
  chainConfig.contracts->Belt.Array.flatMap(contract => {
    contract.addresses->Belt.Array.map(address => {
      (contract.name, address)
    })
  })
}

module Stub = {
  let getShouldPreRegisterDynamicContracts = (
    handlerRegister: Types.HandlerTypes.Register.t<'eventArgs>,
  ) => {
    handlerRegister->Types.HandlerTypes.Register.getContractRegister->Option.isSome
  }
}

let makeFromConfig = (chainConfig: Config.chainConfig, ~maxAddrInPartition) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chain->ChainMap.Chain.toChainId})
  let staticContracts = chainConfig->getStaticContracts
  let lastBlockScannedHashes = ReorgDetection.LastBlockScannedHashes.empty(
    ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
  )

  let dynamicContractPreRegistration =
    chainConfig->Config.shouldPreRegisterDynamicContracts ? Some(Js.Dict.empty()) : None

  make(
    ~staticContracts,
    ~chainConfig,
    ~startBlock=chainConfig.startBlock,
    ~endBlock=chainConfig.endBlock,
    ~lastBlockScannedHashes,
    ~dbFirstEventBlockNumber=None,
    ~latestProcessedBlock=None,
    ~timestampCaughtUpToHeadOrEndblock=None,
    ~numEventsProcessed=0,
    ~numBatchesFetched=0,
    ~logger,
    ~eventFilters=None,
    ~dynamicContractRegistrations=[],
    ~maxAddrInPartition,
    ~dynamicContractPreRegistration,
  )
}

/**
 * This function allows a chain fetcher to be created from metadata, in particular this is useful for restarting an indexer and making sure it fetches blocks from the same place.
 */
let makeFromDbState = async (chainConfig: Config.chainConfig, ~maxAddrInPartition) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chain->ChainMap.Chain.toChainId})
  let staticContracts = chainConfig->getStaticContracts
  let chainId = chainConfig.chain->ChainMap.Chain.toChainId
  let latestProcessedEvent = await DbFunctions.EventSyncState.getLatestProcessedEvent(~chainId)

  let chainMetadata = await DbFunctions.ChainMetadata.getLatestChainMetadataState(~chainId)

  let (
    startBlock: int,
    isPreRegisteringDynamicContracts: bool,
    eventFilters: option<FetchState.eventFilters>,
  ) = switch latestProcessedEvent {
  | Some(event) =>
    //start from the same block but filter out any events already processed
    let eventFilters = list{
      {
        FetchState.filter: qItem => {
          //Only keep events greater than the last processed event
          (qItem.chain->ChainMap.Chain.toChainId, qItem.blockNumber, qItem.logIndex) >
          (event.chainId, event.blockNumber, event.logIndex)
        },
        isValid: (~fetchState, ~chain as _) => {
          //the filter can be cleaned up as soon as the fetch state block is ahead of the latestProcessedEvent blockNumber
          FetchState.getLatestFullyFetchedBlock(fetchState).blockNumber <= event.blockNumber
        },
      },
    }

    (event.blockNumber, event.isPreRegisteringDynamicContracts, Some(eventFilters))
  | None => (chainConfig.startBlock, chainConfig->Config.shouldPreRegisterDynamicContracts, None)
  }

  //Get all dynamic contracts already registered on the chain
  let dbDynamicContractRegistrations =
    await DbFunctions.sql->DbFunctions.DynamicContractRegistry.readDynamicContractsOnChainIdAtOrBeforeBlock(
      ~chainId,
      ~startBlock,
    )

  let (
    dynamicContractPreRegistration: option<addressToDynContractLookup>,
    dynamicContractRegistrations: array<TablesStatic.DynamicContractRegistry.t>,
  ) = if isPreRegisteringDynamicContracts {
    let dynamicContractPreRegistration: addressToDynContractLookup = Js.Dict.empty()
    dbDynamicContractRegistrations->Array.forEach(contract => {
      dynamicContractPreRegistration->Js.Dict.set(
        contract.contractAddress->Address.toString,
        contract,
      )
    })
    (Some(dynamicContractPreRegistration), [])
  } else {
    (None, dbDynamicContractRegistrations)
  }

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

  make(
    ~staticContracts,
    ~dynamicContractRegistrations,
    ~chainConfig,
    ~startBlock,
    ~endBlock=chainConfig.endBlock,
    ~lastBlockScannedHashes,
    ~dbFirstEventBlockNumber=firstEventBlockNumber,
    ~latestProcessedBlock=latestProcessedBlockChainMetadata,
    ~timestampCaughtUpToHeadOrEndblock,
    ~numEventsProcessed=numEventsProcessed->Option.getWithDefault(0),
    ~numBatchesFetched=0,
    ~logger,
    ~eventFilters,
    ~maxAddrInPartition,
    ~dynamicContractPreRegistration,
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
let getNextQuery = (self: t, ~maxPerChainQueueSize) => {
  //Chain Fetcher should have already cleaned up stale event filters by the time this
  //is called but just ensure its cleaned before getting the next query
  let cleanedChainFetcher = self->cleanUpEventFilters

  cleanedChainFetcher.fetchState->PartitionedFetchState.getNextQueriesOrThrow(
    ~eventFilters=?cleanedChainFetcher.eventFilters,
    ~currentBlockHeight=cleanedChainFetcher.currentBlockHeight,
    ~maxPerChainQueueSize,
    ~partitionsCurrentlyFetching=self.partitionsCurrentlyFetching,
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

let hasNoMoreEventsToProcess = (self: t, ~hasArbQueueEvents) => {
  !hasArbQueueEvents && self.fetchState->PartitionedFetchState.queueSize === 0
}

/**
Finds the last known block where hashes are valid and returns
the updated lastBlockScannedHashes rolled back where this occurs
*/
let rollbackLastBlockHashesToReorgLocation = async (
  chainFetcher: t,
  //Parameter used for dependency injecting in tests
  ~getBlockHashes as getBlockHashesMock=?,
) => {
  // FIXME: Mock chainWorker instead

  //get a list of block hashes via the chainworker
  let blockNumbers =
    chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.getAllBlockNumbers

  let module(ChainWorker) = chainFetcher.chainConfig.chainWorker

  let getBlockHashes = switch getBlockHashesMock {
  | Some(getBlockHashes) => getBlockHashes
  | None => ChainWorker.getBlockHashes
  }

  let blockNumbersAndHashes = await getBlockHashes(
    ~blockNumbers,
    ~logger=chainFetcher.logger,
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

let getFirstEventBlockNumber = (chainFetcher: t) =>
  Utils.Math.minOptInt(
    chainFetcher.dbFirstEventBlockNumber,
    chainFetcher.fetchState->PartitionedFetchState.getFirstEventBlockNumber,
  )

let isPreRegisteringDynamicContracts = (chainFetcher: t) =>
  chainFetcher.dynamicContractPreRegistration->Option.isSome
