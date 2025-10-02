open Belt

//A filter should return true if the event should be kept and isValid should return
//false when the filter should be removed/cleaned up
type processingFilter = {
  filter: Internal.item => bool,
  isValid: (~fetchState: FetchState.t) => bool,
}

type t = {
  logger: Pino.t,
  fetchState: FetchState.t,
  sourceManager: SourceManager.t,
  chainConfig: InternalConfig.chain,
  //The latest known block of the chain
  currentBlockHeight: int,
  isProgressAtHead: bool,
  timestampCaughtUpToHeadOrEndblock: option<Js.Date.t>,
  committedProgressBlockNumber: int,
  firstEventBlockNumber: option<int>,
  numEventsProcessed: int,
  numBatchesFetched: int,
  lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.t,
  //An optional list of filters to apply on event queries
  //Used for reorgs and restarts
  processingFilters: option<array<processingFilter>>,
}

//CONSTRUCTION
let make = (
  ~chainConfig: InternalConfig.chain,
  ~lastBlockScannedHashes,
  ~dynamicContracts: array<InternalTable.DynamicContractRegistry.t>,
  ~startBlock,
  ~endBlock,
  ~firstEventBlockNumber,
  ~progressBlockNumber,
  ~config: Config.t,
  ~targetBufferSize,
  ~logger,
  ~timestampCaughtUpToHeadOrEndblock,
  ~numEventsProcessed,
  ~numBatchesFetched,
  ~isInReorgThreshold,
): t => {
  // We don't need the router itself, but only validation logic,
  // since now event router is created for selection of events
  // and validation doesn't work correctly in routers.
  // Ideally to split it into two different parts.
  let eventRouter = EventRouter.empty()

  // Aggregate events we want to fetch
  let contracts = []
  let eventConfigs: array<Internal.eventConfig> = []

  let notRegisteredEvents = []

  chainConfig.contracts->Array.forEach(contract => {
    let contractName = contract.name

    contract.events->Array.forEach(eventConfig => {
      let {isWildcard} = eventConfig
      let hasContractRegister = eventConfig.contractRegister->Option.isSome

      // Should validate the events
      eventRouter->EventRouter.addOrThrow(
        eventConfig.id,
        (),
        ~contractName,
        ~chain=ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id),
        ~eventName=eventConfig.name,
        ~isWildcard,
      )

      // Filter out non-preRegistration events on preRegistration phase
      // so we don't care about it in fetch state and workers anymore
      let shouldBeIncluded = if config.enableRawEvents {
        true
      } else {
        let isRegistered = hasContractRegister || eventConfig.handler->Option.isSome
        if !isRegistered {
          notRegisteredEvents->Array.push(eventConfig)
        }
        isRegistered
      }

      if shouldBeIncluded {
        eventConfigs->Array.push(eventConfig)
      }
    })

    switch contract.startBlock {
    | Some(startBlock) if startBlock < chainConfig.startBlock =>
      Js.Exn.raiseError(
        `The start block for contract "${contractName}" is less than the chain start block. This is not supported yet.`,
      )
    | _ => ()
    }

    contract.addresses->Array.forEach(address => {
      contracts->Array.push({
        FetchState.address,
        contractName: contract.name,
        startBlock: switch contract.startBlock {
        | Some(startBlock) => startBlock
        | None => chainConfig.startBlock
        },
        register: Config,
      })
    })
  })

  dynamicContracts->Array.forEach(dc =>
    contracts->Array.push({
      FetchState.address: dc.contractAddress,
      contractName: dc.contractName,
      startBlock: dc.registeringEventBlockNumber,
      register: DC({
        registeringEventLogIndex: dc.registeringEventLogIndex,
        registeringEventBlockTimestamp: dc.registeringEventBlockTimestamp,
        registeringEventContractName: dc.registeringEventContractName,
        registeringEventName: dc.registeringEventName,
        registeringEventSrcAddress: dc.registeringEventSrcAddress,
      }),
    })
  )

  if notRegisteredEvents->Utils.Array.notEmpty {
    logger->Logging.childInfo(
      `The event${if notRegisteredEvents->Array.length > 1 {
          "s"
        } else {
          ""
        }} ${notRegisteredEvents
        ->Array.map(eventConfig => `${eventConfig.contractName}.${eventConfig.name}`)
        ->Js.Array2.joinWith(", ")} don't have an event handler and skipped for indexing.`,
    )
  }

  let onBlockConfigs = switch config.registrations {
  | None => Js.Exn.raiseError("Indexer must be initialized with event registration finished.")
  | Some(registrations) =>
    let onBlockConfigs =
      registrations.onBlockByChainId->Utils.Dict.dangerouslyGetNonOption(
        chainConfig.id->Int.toString,
      )
    switch onBlockConfigs {
    | Some(onBlockConfigs) =>
      // TODO: Move it to the EventRegister module
      // so the error is thrown with better stack trace
      onBlockConfigs->Array.forEach(onBlockConfig => {
        if onBlockConfig.startBlock->Option.getWithDefault(startBlock) < startBlock {
          Js.Exn.raiseError(
            `The start block for onBlock handler "${onBlockConfig.name}" is less than the chain start block (${startBlock->Belt.Int.toString}). This is not supported yet.`,
          )
        }
        switch endBlock {
        | Some(chainEndBlock) =>
          if onBlockConfig.endBlock->Option.getWithDefault(chainEndBlock) > chainEndBlock {
            Js.Exn.raiseError(
              `The end block for onBlock handler "${onBlockConfig.name}" is greater than the chain end block (${chainEndBlock->Belt.Int.toString}). This is not supported yet.`,
            )
          }
        | None => ()
        }
      })
    | None => ()
    }

    onBlockConfigs
  }

  let fetchState = FetchState.make(
    ~maxAddrInPartition=config.maxAddrInPartition,
    ~contracts,
    ~progressBlockNumber,
    ~startBlock,
    ~endBlock,
    ~eventConfigs,
    ~targetBufferSize,
    ~chainId=chainConfig.id,
    ~blockLag=Pervasives.max(
      !(config->Config.shouldRollbackOnReorg) || isInReorgThreshold
        ? 0
        : chainConfig.confirmedBlockThreshold,
      Env.indexingBlockLag->Option.getWithDefault(0),
    ),
    ~onBlockConfigs?,
  )

  {
    logger,
    chainConfig,
    sourceManager: SourceManager.make(
      ~sources=chainConfig.sources,
      ~maxPartitionConcurrency=Env.maxPartitionConcurrency,
    ),
    lastBlockScannedHashes,
    currentBlockHeight: 0,
    isProgressAtHead: false,
    fetchState,
    firstEventBlockNumber,
    committedProgressBlockNumber: progressBlockNumber,
    timestampCaughtUpToHeadOrEndblock,
    numEventsProcessed,
    numBatchesFetched,
    processingFilters: None,
  }
}

let makeFromConfig = (chainConfig: InternalConfig.chain, ~config, ~targetBufferSize) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.id})
  let lastBlockScannedHashes = ReorgDetection.LastBlockScannedHashes.empty(
    ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
  )

  make(
    ~chainConfig,
    ~config,
    ~startBlock=chainConfig.startBlock,
    ~endBlock=chainConfig.endBlock,
    ~lastBlockScannedHashes,
    ~firstEventBlockNumber=None,
    ~progressBlockNumber=chainConfig.startBlock - 1,
    ~timestampCaughtUpToHeadOrEndblock=None,
    ~numEventsProcessed=0,
    ~numBatchesFetched=0,
    ~targetBufferSize,
    ~logger,
    ~dynamicContracts=[],
    ~isInReorgThreshold=false,
  )
}

/**
 * This function allows a chain fetcher to be created from metadata, in particular this is useful for restarting an indexer and making sure it fetches blocks from the same place.
 */
let makeFromDbState = async (
  chainConfig: InternalConfig.chain,
  ~resumedChainState: InternalTable.Chains.t,
  ~isInReorgThreshold,
  ~config,
  ~targetBufferSize,
  ~sql=Db.sql,
) => {
  let chainId = chainConfig.id
  let logger = Logging.createChild(~params={"chainId": chainId})

  // Since we deleted all contracts after the restart point,
  // we can simply query all dcs we have in db
  let dbRecoveredDynamicContracts =
    await sql->DbFunctions.DynamicContractRegistry.readAllDynamicContracts(~chainId)

  let endOfBlockRangeScannedData =
    await sql->DbFunctions.EndOfBlockRangeScannedData.readEndOfBlockRangeScannedDataForChain(
      ~chainId,
    )

  let lastBlockScannedHashes =
    endOfBlockRangeScannedData
    ->Array.map(({blockNumber, blockHash}) => {
      ReorgDetection.blockNumber,
      blockHash,
    })
    ->ReorgDetection.LastBlockScannedHashes.makeWithData(
      ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
    )

  Prometheus.ProgressEventsCount.set(~processedCount=resumedChainState.numEventsProcessed, ~chainId)

  let progressBlockNumber =
    // Can be -1 when not set
    resumedChainState.progressBlockNumber >= 0
      ? resumedChainState.progressBlockNumber
      : resumedChainState.startBlock - 1

  make(
    ~dynamicContracts=dbRecoveredDynamicContracts,
    ~chainConfig,
    ~startBlock=resumedChainState.startBlock,
    ~endBlock=resumedChainState.endBlock->Js.Null.toOption,
    ~config,
    ~lastBlockScannedHashes,
    ~firstEventBlockNumber=resumedChainState.firstEventBlockNumber->Js.Null.toOption,
    ~progressBlockNumber,
    ~timestampCaughtUpToHeadOrEndblock=Env.updateSyncTimeOnRestart
      ? None
      : resumedChainState.timestampCaughtUpToHeadOrEndblock->Js.Null.toOption,
    ~numEventsProcessed=resumedChainState.numEventsProcessed,
    ~numBatchesFetched=0,
    ~logger,
    ~targetBufferSize,
    ~isInReorgThreshold,
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
 * Helper function to get the configured start block for a contract from config
 */
let getContractStartBlock = (
  config: Config.t,
  ~chain: ChainMap.Chain.t,
  ~contractName: string,
): option<int> => {
  let chainConfig = config.chainMap->ChainMap.get(chain)
  chainConfig.contracts
  ->Js.Array2.find(contract => contract.name === contractName)
  ->Option.flatMap(contract => contract.startBlock)
}

let runContractRegistersOrThrow = async (
  ~itemsWithContractRegister: array<Internal.item>,
  ~chain: ChainMap.Chain.t,
  ~config: Config.t,
) => {
  let dynamicContracts = []
  let isDone = ref(false)

  let onRegister = (~item: Internal.item, ~contractAddress, ~contractName) => {
    let eventItem = item->Internal.castUnsafeEventItem
    if isDone.contents {
      item->Logging.logForItem(
        #warn,
        `Skipping contract registration: The context.add${(contractName: Enums.ContractType.t :> string)} was called after the contract register resolved. Use await or return a promise from the contract register handler to avoid this error.`,
      )
    } else {
      let {timestamp, blockNumber, logIndex, eventConfig, event} = eventItem

      // Use contract-specific start block if configured, otherwise fall back to registration block
      let contractStartBlock = switch getContractStartBlock(
        config,
        ~chain,
        ~contractName=(contractName: Enums.ContractType.t :> string),
      ) {
      | Some(configuredStartBlock) => configuredStartBlock
      | None => blockNumber
      }

      let dc: FetchState.indexingContract = {
        address: contractAddress,
        contractName: (contractName: Enums.ContractType.t :> string),
        startBlock: contractStartBlock,
        register: DC({
          registeringEventBlockTimestamp: timestamp,
          registeringEventLogIndex: logIndex,
          registeringEventName: eventConfig.name,
          registeringEventContractName: eventConfig.contractName,
          registeringEventSrcAddress: event.srcAddress,
        }),
      }

      dynamicContracts->Array.push(dc)
    }
  }

  let promises = []
  for idx in 0 to itemsWithContractRegister->Array.length - 1 {
    let item = itemsWithContractRegister->Array.getUnsafe(idx)
    let eventItem = item->Internal.castUnsafeEventItem
    let contractRegister = switch eventItem {
    | {eventConfig: {contractRegister: Some(contractRegister)}} => contractRegister
    | {eventConfig: {contractRegister: None, name: eventName}} =>
      // Unexpected case, since we should pass only events with contract register to this function
      Js.Exn.raiseError("Contract register is not set for event " ++ eventName)
    }

    let errorMessage = "Event contractRegister failed, please fix the error to keep the indexer running smoothly"

    // Catch sync and async errors
    try {
      let result = contractRegister(
        item->UserContext.getContractRegisterArgs(~eventItem, ~onRegister, ~config),
      )

      // Even though `contractRegister` always returns a promise,
      // in the ReScript type, but it might return a non-promise value for TS API.
      if result->Promise.isCatchable {
        promises->Array.push(
          result->Promise.catch(exn => {
            exn->ErrorHandling.mkLogAndRaise(~msg=errorMessage, ~logger=item->Logging.getItemLogger)
          }),
        )
      }
    } catch {
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(~msg=errorMessage, ~logger=item->Logging.getItemLogger)
    }
  }

  if promises->Utils.Array.notEmpty {
    let _ = await Promise.all(promises)
  }

  isDone.contents = true
  dynamicContracts
}

@inline
let applyProcessingFilters = (~item: Internal.item, ~processingFilters) => {
  processingFilters->Js.Array2.every(processingFilter => processingFilter.filter(item))
}

/**
Updates of fetchState and cleans up event filters. Should be used whenever updating fetchState
to ensure processingFilters are always valid.
Returns Error if the node with given id cannot be found (unexpected)
*/
let handleQueryResult = (
  chainFetcher: t,
  ~query: FetchState.query,
  ~newItems,
  ~dynamicContracts,
  ~latestFetchedBlock,
) => {
  let fs = switch dynamicContracts {
  | [] => chainFetcher.fetchState
  | _ => chainFetcher.fetchState->FetchState.registerDynamicContracts(dynamicContracts)
  }

  fs
  ->FetchState.handleQueryResult(~query, ~latestFetchedBlock, ~newItems)
  ->Result.map(fetchState => {
    {
      ...chainFetcher,
      fetchState,
      processingFilters: switch chainFetcher.processingFilters {
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
  let {committedProgressBlockNumber, fetchState} = self
  switch fetchState.endBlock {
  | Some(endBlock) => committedProgressBlockNumber >= endBlock
  | None => false
  }
}

let hasNoMoreEventsToProcess = (self: t) => {
  self.fetchState->FetchState.bufferSize === 0
}

let getHighestBlockBelowThreshold = (cf: t): int => {
  let highestBlockBelowThreshold = cf.currentBlockHeight - cf.chainConfig.confirmedBlockThreshold
  highestBlockBelowThreshold < 0 ? 0 : highestBlockBelowThreshold
}

/**
Finds the last known block where hashes are valid
If not found, returns the higehest block below threshold
*/
let getLastKnownValidBlock = async (
  chainFetcher: t,
  //Parameter used for dependency injecting in tests
  ~getBlockHashes=(chainFetcher.sourceManager->SourceManager.getActiveSource).getBlockHashes,
) => {
  let scannedBlockNumbers =
    chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.getThresholdBlockNumbers(
      ~currentBlockHeight=chainFetcher.currentBlockHeight,
    )

  let getBlockHashes = blockNumbers => {
    getBlockHashes(~blockNumbers, ~logger=chainFetcher.logger)->Promise.thenResolve(res =>
      switch res {
      | Ok(v) => v
      | Error(exn) =>
        exn->ErrorHandling.mkLogAndRaise(
          ~msg="Failed to fetch blockHashes for given blockNumbers during rollback",
        )
      }
    )
  }

  let fallback = async () => {
    switch await getBlockHashes([chainFetcher->getHighestBlockBelowThreshold]) {
    | [block] => block
    | _ =>
      Js.Exn.raiseError(
        "Unexpected case. Failed to fetch block data for the last block outside of reorg threshold during reorg rollback",
      )
    }
  }

  switch scannedBlockNumbers {
  | [] => await fallback()
  | _ => {
      let blockRef = ref(None)
      let retryCount = ref(0)

      while blockRef.contents->Option.isNone {
        let blockNumbersAndHashes = await getBlockHashes(scannedBlockNumbers)

        switch chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.getLatestValidScannedBlock(
          ~blockNumbersAndHashes,
          ~currentBlockHeight=chainFetcher.currentBlockHeight,
          ~skipReorgDuplicationCheck=retryCount.contents > 2,
        ) {
        | Ok(block) => blockRef := Some(block)
        | Error(NotFound) => blockRef := Some(await fallback())
        | Error(AlreadyReorgedHashes) =>
          let delayMilliseconds = 100
          chainFetcher.logger->Logging.childTrace(
            `Failed to find a valid block to rollback to, since received already reorged hashes from another HyperSync instance. HyperSync has multiple instances and it's possible that they drift independently slightly from the head. Indexing should continue correctly after retrying the query in ${delayMilliseconds->Int.toString}ms.`,
          )
          await Utils.delay(delayMilliseconds)
          retryCount := retryCount.contents + 1
        }
      }

      blockRef.contents->Option.getUnsafe
    }
  }
}

let isActivelyIndexing = (chainFetcher: t) => chainFetcher.fetchState->FetchState.isActivelyIndexing
