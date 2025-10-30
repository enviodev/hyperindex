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
  chainConfig: Config.chain,
  //The latest known block of the chain
  currentBlockHeight: int,
  isProgressAtHead: bool,
  timestampCaughtUpToHeadOrEndblock: option<Js.Date.t>,
  committedProgressBlockNumber: int,
  firstEventBlockNumber: option<int>,
  numEventsProcessed: int,
  numBatchesFetched: int,
  reorgDetection: ReorgDetection.t,
  safeCheckpointTracking: option<SafeCheckpointTracking.t>,
}

//CONSTRUCTION
let make = (
  ~chainConfig: Config.chain,
  ~dynamicContracts: array<Internal.indexingContract>,
  ~startBlock,
  ~endBlock,
  ~firstEventBlockNumber,
  ~progressBlockNumber,
  ~config: Config.t,
  ~registrations: EventRegister.registrations,
  ~targetBufferSize,
  ~logger,
  ~timestampCaughtUpToHeadOrEndblock,
  ~numEventsProcessed,
  ~numBatchesFetched,
  ~isInReorgThreshold,
  ~reorgCheckpoints: array<Internal.reorgCheckpoint>,
  ~maxReorgDepth,
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
        Internal.address,
        contractName: contract.name,
        startBlock: switch contract.startBlock {
        | Some(startBlock) => startBlock
        | None => chainConfig.startBlock
        },
        registrationBlock: None,
      })
    })
  })

  dynamicContracts->Array.forEach(dc => contracts->Array.push(dc))

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

  let onBlockConfigs =
    registrations.onBlockByChainId->Utils.Dict.dangerouslyGetNonOption(chainConfig.id->Int.toString)
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

  let fetchState = FetchState.make(
    ~maxAddrInPartition=config.maxAddrInPartition,
    ~contracts,
    ~progressBlockNumber,
    ~startBlock,
    ~endBlock,
    ~eventConfigs,
    ~targetBufferSize,
    ~chainId=chainConfig.id,
    // FIXME: Shouldn't set with full history
    ~blockLag=Pervasives.max(
      !config.shouldRollbackOnReorg || isInReorgThreshold ? 0 : chainConfig.maxReorgDepth,
      Env.indexingBlockLag->Option.getWithDefault(0),
    ),
    ~onBlockConfigs?,
  )

  let chainReorgCheckpoints = reorgCheckpoints->Array.keepMapU(reorgCheckpoint => {
    if reorgCheckpoint.chainId === chainConfig.id {
      Some(reorgCheckpoint)
    } else {
      None
    }
  })

  {
    logger,
    chainConfig,
    sourceManager: SourceManager.make(
      ~sources=chainConfig.sources,
      ~maxPartitionConcurrency=Env.maxPartitionConcurrency,
    ),
    reorgDetection: ReorgDetection.make(
      ~chainReorgCheckpoints,
      ~maxReorgDepth,
      ~shouldRollbackOnReorg=config.shouldRollbackOnReorg,
    ),
    safeCheckpointTracking: SafeCheckpointTracking.make(
      ~maxReorgDepth,
      ~shouldRollbackOnReorg=config.shouldRollbackOnReorg,
      ~chainReorgCheckpoints,
    ),
    currentBlockHeight: 0,
    isProgressAtHead: false,
    fetchState,
    firstEventBlockNumber,
    committedProgressBlockNumber: progressBlockNumber,
    timestampCaughtUpToHeadOrEndblock,
    numEventsProcessed,
    numBatchesFetched,
  }
}

let makeFromConfig = (chainConfig: Config.chain, ~config, ~registrations, ~targetBufferSize) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.id})

  make(
    ~chainConfig,
    ~config,
    ~registrations,
    ~startBlock=chainConfig.startBlock,
    ~endBlock=chainConfig.endBlock,
    ~reorgCheckpoints=[],
    ~maxReorgDepth=chainConfig.maxReorgDepth,
    ~firstEventBlockNumber=None,
    ~progressBlockNumber=-1,
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
  chainConfig: Config.chain,
  ~resumedChainState: Persistence.initialChainState,
  ~reorgCheckpoints,
  ~isInReorgThreshold,
  ~config,
  ~registrations,
  ~targetBufferSize,
) => {
  let chainId = chainConfig.id
  let logger = Logging.createChild(~params={"chainId": chainId})

  Prometheus.ProgressEventsCount.set(~processedCount=resumedChainState.numEventsProcessed, ~chainId)

  let progressBlockNumber =
    // Can be -1 when not set
    resumedChainState.progressBlockNumber >= 0
      ? resumedChainState.progressBlockNumber
      : resumedChainState.startBlock - 1

  make(
    ~dynamicContracts=resumedChainState.dynamicContracts,
    ~chainConfig,
    ~startBlock=resumedChainState.startBlock,
    ~endBlock=resumedChainState.endBlock,
    ~config,
    ~registrations,
    ~reorgCheckpoints,
    ~maxReorgDepth=resumedChainState.maxReorgDepth,
    ~firstEventBlockNumber=resumedChainState.firstEventBlockNumber,
    ~progressBlockNumber,
    ~timestampCaughtUpToHeadOrEndblock=Env.updateSyncTimeOnRestart
      ? None
      : resumedChainState.timestampCaughtUpToHeadOrEndblock,
    ~numEventsProcessed=resumedChainState.numEventsProcessed,
    ~numBatchesFetched=0,
    ~logger,
    ~targetBufferSize,
    ~isInReorgThreshold,
  )
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
  let itemsWithDcs = []

  let onRegister = (~item: Internal.item, ~contractAddress, ~contractName) => {
    let eventItem = item->Internal.castUnsafeEventItem
    let {blockNumber} = eventItem

    // Use contract-specific start block if configured, otherwise fall back to registration block
    let contractStartBlock = switch getContractStartBlock(
      config,
      ~chain,
      ~contractName=(contractName: Enums.ContractType.t :> string),
    ) {
    | Some(configuredStartBlock) => configuredStartBlock
    | None => blockNumber
    }

    let dc: Internal.indexingContract = {
      address: contractAddress,
      contractName: (contractName: Enums.ContractType.t :> string),
      startBlock: contractStartBlock,
      registrationBlock: Some(blockNumber),
    }

    switch item->Internal.getItemDcs {
    | None => {
        item->Internal.setItemDcs([dc])
        itemsWithDcs->Array.push(item)
      }
    | Some(dcs) => dcs->Array.push(dc)
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
      let params: UserContext.contractRegisterParams = {
        item,
        onRegister,
        config,
        isResolved: false,
      }
      let result = contractRegister(UserContext.getContractRegisterArgs(params))

      // Even though `contractRegister` always returns a promise,
      // in the ReScript type, but it might return a non-promise value for TS API.
      if result->Promise.isCatchable {
        promises->Array.push(
          result
          ->Promise.thenResolve(r => {
            params.isResolved = true
            r
          })
          ->Promise.catch(exn => {
            params.isResolved = true
            exn->ErrorHandling.mkLogAndRaise(~msg=errorMessage, ~logger=item->Logging.getItemLogger)
          }),
        )
      } else {
        params.isResolved = true
      }
    } catch {
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(~msg=errorMessage, ~logger=item->Logging.getItemLogger)
    }
  }

  if promises->Utils.Array.notEmpty {
    let _ = await Promise.all(promises)
  }

  itemsWithDcs
}

let handleQueryResult = (
  chainFetcher: t,
  ~query: FetchState.query,
  ~newItems,
  ~newItemsWithDcs,
  ~latestFetchedBlock,
) => {
  let fs = switch newItemsWithDcs {
  | [] => chainFetcher.fetchState
  | _ => chainFetcher.fetchState->FetchState.registerDynamicContracts(newItemsWithDcs)
  }

  fs
  ->FetchState.handleQueryResult(~query, ~latestFetchedBlock, ~newItems)
  ->Result.map(fs => {
    ...chainFetcher,
    fetchState: fs,
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
  let highestBlockBelowThreshold = cf.currentBlockHeight - cf.chainConfig.maxReorgDepth
  highestBlockBelowThreshold < 0 ? 0 : highestBlockBelowThreshold
}

/**
Finds the last known valid block number below the reorg block
If not found, returns the highest block below threshold
*/
let getLastKnownValidBlock = async (
  chainFetcher: t,
  ~reorgBlockNumber: int,
  //Parameter used for dependency injecting in tests
  ~getBlockHashes=(chainFetcher.sourceManager->SourceManager.getActiveSource).getBlockHashes,
) => {
  // Improtant: It's important to not include the reorg detection block number
  // because there might be different instances of the source
  // with mismatching hashes between them.
  // So we MUST always rollback the block number where we detected a reorg.
  let scannedBlockNumbers =
    chainFetcher.reorgDetection->ReorgDetection.getThresholdBlockNumbersBelowBlock(
      ~blockNumber=reorgBlockNumber,
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

  switch scannedBlockNumbers {
  | [] => chainFetcher->getHighestBlockBelowThreshold
  | _ => {
      let blockNumbersAndHashes = await getBlockHashes(scannedBlockNumbers)

      switch chainFetcher.reorgDetection->ReorgDetection.getLatestValidScannedBlock(
        ~blockNumbersAndHashes,
      ) {
      | Some(blockNumber) => blockNumber
      | None => chainFetcher->getHighestBlockBelowThreshold
      }
    }
  }
}

let isActivelyIndexing = (chainFetcher: t) => chainFetcher.fetchState->FetchState.isActivelyIndexing
