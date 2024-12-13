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
  fetchState: PartitionedFetchState.t,
  sourceManger: SourceManager.t,
  chainConfig: Config.chainConfig,
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
  ~processingFilters,
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
    sourceManger: SourceManager.make(~maxPartitionConcurrency=Env.maxPartitionConcurrency, ~logger),
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

let getStaticContracts = (chainConfig: Config.chainConfig) => {
  chainConfig.contracts->Belt.Array.flatMap(contract => {
    contract.addresses->Belt.Array.map(address => {
      (contract.name, address)
    })
  })
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
    ~processingFilters=None,
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
  let latestProcessedEvent =
    await Db.sql->DbFunctions.EventSyncState.getLatestProcessedEvent(~chainId)

  let chainMetadata = await Db.sql->DbFunctions.ChainMetadata.getLatestChainMetadataState(~chainId)

  let preRegisterDynamicContracts = chainConfig->Config.shouldPreRegisterDynamicContracts

  let (
    startBlock: int,
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

    (event.blockNumber, event.isPreRegisteringDynamicContracts, Some(processingFilters))
  | None => (chainConfig.startBlock, preRegisterDynamicContracts, None)
  }

  //Get all dynamic contracts already registered on the chain
  let dbDynamicContractRegistrations = if preRegisterDynamicContracts {
    //An array of records containing srcAddress, eventName, contractName for each contract
    //address & event that should be pre registered
    let preRegisteringEvents = chainConfig.contracts->Array.flatMap(contract =>
      contract.events->Array.flatMap(eventMod => {
        let module(Event) = eventMod
        let {preRegisterDynamicContracts} =
          Event.handlerRegister->Types.HandlerTypes.Register.getEventOptions

        if preRegisterDynamicContracts {
          contract.addresses->Belt.Array.map(
            address => {
              {
                DbFunctions.DynamicContractRegistry.registeringEventContractName: contract.name,
                registeringEventName: Event.name,
                registeringEventSrcAddress: address,
              }
            },
          )
        } else {
          []
        }
      })
    )

    //If preregistration is done, but the indexer stops and restarts during indexing. We still get all the dynamic
    //contracts that were registered during preregistration. We need to match on registering event name, contract name and src address
    //to ensure we only get the dynamic contracts that were registered during preregistration
    await Db.sql->DbFunctions.DynamicContractRegistry.readDynamicContractsOnChainIdMatchingEvents(
      ~chainId,
      ~preRegisteringEvents,
    )
  } else {
    //If no preregistration should be done, only get dynamic contracts up to the the block that the indexing starts from
    await Db.sql->DbFunctions.DynamicContractRegistry.readDynamicContractsOnChainIdAtOrBeforeBlock(
      ~chainId,
      ~startBlock,
    )
  }

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
    await Db.sql->DbFunctions.EndOfBlockRangeScannedData.readEndOfBlockRangeScannedDataForChain(
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
  ~fetchState as {partitions}: PartitionedFetchState.t,
) => {
  switch processingFilters->Array.keep(processingFilter =>
    partitions->Array.reduce(false, (accum, partition) => {
      accum || processingFilter.isValid(~fetchState=partition)
    })
  ) {
  | [] => None
  | filters => Some(filters)
  }
}

/**
Updates of fetchState and cleans up event filters. Should be used whenever updating fetchState
to ensure processingFilters are always valid.
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
  let newItems = switch self.processingFilters {
  | None => fetchedEvents
  | Some(processingFilters) => fetchedEvents->applyProcessingFilters(~processingFilters)
  }

  self.fetchState
  ->PartitionedFetchState.update(
    ~id,
    ~latestFetchedBlock={
      blockNumber: latestFetchedBlockNumber,
      blockTimestamp: latestFetchedBlockTimestamp,
    },
    ~newItems,
    ~currentBlockHeight,
    ~chain=self.chainConfig.chain,
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

let isFetchingAtHead = (chainFetcher: t) =>
  chainFetcher.fetchState->PartitionedFetchState.isFetchingAtHead

let getFirstEventBlockNumber = (chainFetcher: t) =>
  Utils.Math.minOptInt(
    chainFetcher.dbFirstEventBlockNumber,
    chainFetcher.fetchState->PartitionedFetchState.getFirstEventBlockNumber,
  )

let isPreRegisteringDynamicContracts = (chainFetcher: t) =>
  chainFetcher.dynamicContractPreRegistration->Option.isSome

let getHeighestBlockBelowThreshold = (cf: t): int => {
  Pervasives.max(cf.currentBlockHeight - cf.chainConfig.confirmedBlockThreshold, 0)
}
