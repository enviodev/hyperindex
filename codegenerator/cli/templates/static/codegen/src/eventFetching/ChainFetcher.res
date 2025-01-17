open Belt

//A filter should return true if the event should be kept and isValid should return
//false when the filter should be removed/cleaned up
type processingFilter = {
  filter: Internal.eventItem => bool,
  isValid: (~fetchState: FetchState.t) => bool,
}

type addressToDynContractLookup = dict<TablesStatic.DynamicContractRegistry.t>
type t = {
  logger: Pino.t,
  fetchState: FetchState.t,
  sourceManager: SourceManager.t,
  chainConfig: Config.chainConfig,
  startBlock: int,
  //The latest known block of the chain
  currentBlockHeight: int,
  timestampCaughtUpToHeadOrEndblock: option<Js.Date.t>,
  dbFirstEventBlockNumber: option<int>,
  latestProcessedBlock: option<int>,
  numEventsProcessed: int,
  numBatchesFetched: int,
  lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.t,
  //An optional list of filters to apply on event queries
  //Used for reorgs and restarts
  processingFilters: option<array<processingFilter>>,
  //Currently this state applies to all chains simultaneously but it may be possible to,
  //in the future, have a per chain state and allow individual chains to start indexing as
  //soon as the pre registration is done
  dynamicContractPreRegistration: option<addressToDynContractLookup>,
}

//CONSTRUCTION
let make = (
  ~chainConfig: Config.chainConfig,
  ~lastBlockScannedHashes,
  ~dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>,
  ~startBlock,
  ~endBlock,
  ~dbFirstEventBlockNumber,
  ~latestProcessedBlock,
  ~logger,
  ~timestampCaughtUpToHeadOrEndblock,
  ~numEventsProcessed,
  ~numBatchesFetched,
  ~processingFilters,
  ~maxAddrInPartition,
  ~dynamicContractPreRegistration,
): t => {
  let module(ChainWorker) = chainConfig.chainWorker
  logger->Logging.childInfo("Initializing ChainFetcher with " ++ ChainWorker.name ++ " worker")

  let isPreRegisteringDynamicContracts = dynamicContractPreRegistration->Option.isSome

  let staticContracts = Js.Dict.empty()
  let eventConfigs: array<FetchState.eventConfig> = []
  chainConfig.contracts->Array.forEach(contract => {
    let contractName = contract.name

    contract.events->Array.forEach(event => {
      let module(Event) = event

      let {isWildcard, preRegisterDynamicContracts} =
        Event.handlerRegister->Types.HandlerTypes.Register.getEventOptions

      // Filter out non-preRegistration events on preRegistration phase
      // so we don't care about it in fetch state and workers anymore
      if isPreRegisteringDynamicContracts ? preRegisterDynamicContracts : true {
        eventConfigs->Array.push({
          contractName,
          eventId: Event.id,
          isWildcard,
        })
      }
    })

    staticContracts->Js.Dict.set(contractName, contract.addresses)
  })

  let fetchState = FetchState.make(
    ~maxAddrInPartition,
    ~staticContracts,
    ~dynamicContracts,
    ~startBlock,
    ~endBlock,
    ~eventConfigs,
  )

  {
    logger,
    chainConfig,
    startBlock,
    sourceManager: SourceManager.make(
      ~maxPartitionConcurrency=Env.maxPartitionConcurrency,
      ~logger,
    ),
    lastBlockScannedHashes,
    currentBlockHeight: 0,
    fetchState,
    dbFirstEventBlockNumber,
    latestProcessedBlock,
    timestampCaughtUpToHeadOrEndblock,
    numEventsProcessed,
    numBatchesFetched,
    processingFilters,
    dynamicContractPreRegistration,
  }
}

let makeFromConfig = (chainConfig: Config.chainConfig, ~maxAddrInPartition) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chain->ChainMap.Chain.toChainId})
  let lastBlockScannedHashes = ReorgDetection.LastBlockScannedHashes.empty(
    ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
  )

  let dynamicContractPreRegistration =
    chainConfig->Config.shouldPreRegisterDynamicContracts ? Some(Js.Dict.empty()) : None

  make(
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
    ~processingFilters=None,
    ~dynamicContracts=[],
    ~maxAddrInPartition,
    ~dynamicContractPreRegistration,
  )
}

/**
 * This function allows a chain fetcher to be created from metadata, in particular this is useful for restarting an indexer and making sure it fetches blocks from the same place.
 */
let makeFromDbState = async (chainConfig: Config.chainConfig, ~maxAddrInPartition, ~sql=Db.sql) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chain->ChainMap.Chain.toChainId})
  let chainId = chainConfig.chain->ChainMap.Chain.toChainId
  let latestProcessedEvent = await sql->DbFunctions.EventSyncState.getLatestProcessedEvent(~chainId)

  let chainMetadata = await sql->DbFunctions.ChainMetadata.getLatestChainMetadataState(~chainId)

  let preRegisterDynamicContracts = chainConfig->Config.shouldPreRegisterDynamicContracts

  let (
    restartBlockNumber: int,
    restartLogIndex: int,
    isPreRegisteringDynamicContracts: bool,
    processingFilters: option<array<processingFilter>>,
  ) = switch latestProcessedEvent {
  | Some(event) =>
    // Start from the same block but filter out any events already processed
    let processingFilters = [
      {
        filter: qItem => {
          //Only keep events greater than the last processed event
          (qItem.chain->ChainMap.Chain.toChainId, qItem.blockNumber, qItem.logIndex) >
          (event.chainId, event.blockNumber, event.logIndex)
        },
        isValid: (~fetchState) => {
          //the filter can be cleaned up as soon as the fetch state block is ahead of the latestProcessedEvent blockNumber
          FetchState.getLatestFullyFetchedBlock(fetchState).blockNumber <= event.blockNumber
        },
      },
    ]

    (
      event.blockNumber,
      event.logIndex,
      event.isPreRegisteringDynamicContracts,
      Some(processingFilters),
    )
  | None => (chainConfig.startBlock, 0, preRegisterDynamicContracts, None)
  }

  let _ = await Promise.all([
    sql->DbFunctions.DynamicContractRegistry.deleteInvalidDynamicContractsOnRestart(
      ~chainId,
      ~restartBlockNumber,
      ~restartLogIndex,
    ),
    sql->DbFunctions.DynamicContractRegistry.deleteInvalidDynamicContractsHistoryOnRestart(
      ~chainId,
      ~restartBlockNumber,
      ~restartLogIndex,
    ),
  ])

  // Since we deleted all contracts after the restart point,
  // besides the preRegistered ones,
  // we can simply query all dcs we have in db
  let dbRecoveredDynamicContracts =
    await sql->DbFunctions.DynamicContractRegistry.readAllDynamicContracts(~chainId)

  let (
    dynamicContractPreRegistration: option<addressToDynContractLookup>,
    dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>,
  ) = if isPreRegisteringDynamicContracts {
    let dynamicContractPreRegistration: addressToDynContractLookup = Js.Dict.empty()
    dbRecoveredDynamicContracts->Array.forEach(contract => {
      dynamicContractPreRegistration->Js.Dict.set(
        contract.contractAddress->Address.toString,
        contract,
      )
    })
    (Some(dynamicContractPreRegistration), [])
  } else {
    (None, dbRecoveredDynamicContracts)
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
    }) => {
      // on restart, reset the events_processed gauge to the previous state
      switch numEventsProcessed {
      | Some(numEventsProcessed) =>
        Prometheus.incrementEventsProcessedCounter(~number=numEventsProcessed)
      | None => () // do nothing if no events have been processed yet for this chain
      }
      (
        firstEventBlockNumber,
        latestProcessedBlock,
        numEventsProcessed,
        Env.updateSyncTimeOnRestart
          ? None
          : timestampCaughtUpToHeadOrEndblock->Js.Nullable.toOption,
      )
    }
  | None => (None, None, None, None)
  }

  let endOfBlockRangeScannedData =
    await sql->DbFunctions.EndOfBlockRangeScannedData.readEndOfBlockRangeScannedDataForChain(
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
    ~dynamicContracts,
    ~chainConfig,
    ~startBlock=restartBlockNumber,
    ~endBlock=chainConfig.endBlock,
    ~lastBlockScannedHashes,
    ~dbFirstEventBlockNumber=firstEventBlockNumber,
    ~latestProcessedBlock=latestProcessedBlockChainMetadata,
    ~timestampCaughtUpToHeadOrEndblock,
    ~numEventsProcessed=numEventsProcessed->Option.getWithDefault(0),
    ~numBatchesFetched=0,
    ~logger,
    ~processingFilters,
    ~maxAddrInPartition,
    ~dynamicContractPreRegistration,
  )
}

/**
Adds an event filter that will be passed to worker on query
isValid is a function that determines when the filter
should be cleaned up
*/
let addProcessingFilter = (self: t, ~filter, ~isValid) => {
  let processingFilter: processingFilter = {filter, isValid}
  {
    ...self,
    processingFilters: switch self.processingFilters {
    | Some(processingFilters) => Some(processingFilters->Array.concat([processingFilter]))
    | None => Some([processingFilter])
    },
  }
}

let applyProcessingFilters = (
  items: array<Internal.eventItem>,
  ~processingFilters: array<processingFilter>,
) =>
  items->Array.keep(item => {
    processingFilters->Js.Array2.every(processingFilter => processingFilter.filter(item))
  })

//Run the clean up condition "isNoLongerValid" against fetchState on each eventFilter and remove
//any that meet the cleanup condition
let cleanUpProcessingFilters = (
  processingFilters: array<processingFilter>,
  ~fetchState: FetchState.t,
) => {
  switch processingFilters->Array.keep(processingFilter => processingFilter.isValid(~fetchState)) {
  | [] => None
  | filters => Some(filters)
  }
}

/**
Updates of fetchState and cleans up event filters. Should be used whenever updating fetchState
to ensure processingFilters are always valid.
Returns Error if the node with given id cannot be found (unexpected)
*/
let setQueryResponse = (
  self: t,
  ~query: FetchState.query,
  ~latestFetchedBlockTimestamp,
  ~latestFetchedBlockNumber,
  ~fetchedEvents,
  ~currentBlockHeight,
) => {
  let newItems = switch self.processingFilters {
  | None => fetchedEvents
  | Some(processingFilters) => fetchedEvents->applyProcessingFilters(~processingFilters)
  }

  self.fetchState
  ->FetchState.setQueryResponse(
    ~query,
    ~latestFetchedBlock={
      blockNumber: latestFetchedBlockNumber,
      blockTimestamp: latestFetchedBlockTimestamp,
    },
    ~newItems,
    ~currentBlockHeight,
  )
  ->Result.map(fetchState => {
    {
      ...self,
      fetchState,
      processingFilters: switch self.processingFilters {
      | Some(processingFilters) => processingFilters->cleanUpProcessingFilters(~fetchState)
      | None => None
      },
    }
  })
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
  !hasArbQueueEvents && self.fetchState->FetchState.queueSize === 0
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

let isFetchingAtHead = (chainFetcher: t) => chainFetcher.fetchState.isFetchingAtHead

let isActivelyIndexing = (chainFetcher: t) => chainFetcher.fetchState->FetchState.isActivelyIndexing

let getFirstEventBlockNumber = (chainFetcher: t) =>
  Utils.Math.minOptInt(
    chainFetcher.dbFirstEventBlockNumber,
    chainFetcher.fetchState.firstEventBlockNumber,
  )

let isPreRegisteringDynamicContracts = (chainFetcher: t) =>
  chainFetcher.dynamicContractPreRegistration->Option.isSome

let getHeighestBlockBelowThreshold = (cf: t): int => {
  let highestBlockBelowThreshold = cf.currentBlockHeight - cf.chainConfig.confirmedBlockThreshold
  highestBlockBelowThreshold < 0 ? 0 : highestBlockBelowThreshold
}
