// Per-chain runtime state. `t` is mutated in place through the setters below;
// the type is opaque in the interface so callers can read fields but can only
// change them through the sanctioned mutators.

type t = {
  logger: Pino.t,
  mutable fetchState: FetchState.t,
  // The chain-wide address index. Not `mutable`: the dict is mutated in place by
  // register/rollback, so the reference is stable across fetchState versions.
  indexingAddresses: IndexingAddresses.t,
  sourceManager: SourceManager.t,
  chainConfig: Config.chain,
  mutable isProgressAtHead: bool,
  mutable timestampCaughtUpToHeadOrEndblock: option<Date.t>,
  mutable committedProgressBlockNumber: int,
  mutable numEventsProcessed: float,
  // Running sum of in-flight queries' estResponseSize, kept here so the
  // scheduler doesn't re-sum pending queries on every tick. Incremented when
  // queries are dispatched, decremented as their responses land.
  mutable pendingBudget: float,
  // Block the last buffer prune rolled this chain back to. While the indexer-wide
  // buffer is still above targetBufferSize, cross-chain admission holds back
  // queries above it so a prune isn't immediately undone by refetching what it
  // dropped; cleared once the buffer drains back to the target.
  mutable lastPruneTarget: option<int>,
  mutable reorgDetection: ReorgDetection.t,
  mutable safeCheckpointTracking: option<SafeCheckpointTracking.t>,
  // Holds this chain's transactions (kept in Rust) keyed by (blockNumber,
  // transactionIndex). Fetch responses merge their page in; entries are pruned
  // as the chain progresses and dropped above the target on rollback.
  transactionStore: TransactionStore.t,
}

// Per-chain shape returned by the status API.
type chainData = {
  chainId: float,
  poweredByHyperSync: bool,
  firstEventBlockNumber: option<int>,
  latestProcessedBlock: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Date.t>,
  numEventsProcessed: float,
  latestFetchedBlockNumber: int,
  // Need this for API backwards compatibility
  @as("currentBlockHeight")
  knownHeight: int,
  numBatchesFetched: int,
  startBlock: int,
  endBlock: option<int>,
  numAddresses: int,
}

let configAddresses = (chainConfig: Config.chain): array<Internal.indexingAddress> => {
  let addresses = []
  chainConfig.contracts->Array.forEach(contract => {
    contract.addresses->Array.forEach(address => {
      addresses->Array.push({
        Internal.address,
        contractName: contract.name,
        registrationBlock: -1,
      })
    })
  })
  addresses
}

let make = (
  ~chainConfig: Config.chain,
  ~fetchState: FetchState.t,
  ~indexingAddresses: IndexingAddresses.t,
  ~sourceManager: SourceManager.t,
  ~reorgDetection: ReorgDetection.t,
  ~committedProgressBlockNumber: int,
  ~safeCheckpointTracking=None,
  ~numEventsProcessed=0.,
  ~timestampCaughtUpToHeadOrEndblock=None,
  ~isProgressAtHead=false,
  ~transactionStore=TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
  ~logger: Pino.t,
): t => {
  logger,
  fetchState,
  indexingAddresses,
  sourceManager,
  chainConfig,
  isProgressAtHead,
  timestampCaughtUpToHeadOrEndblock,
  committedProgressBlockNumber,
  numEventsProcessed,
  pendingBudget: 0.,
  lastPruneTarget: None,
  reorgDetection,
  safeCheckpointTracking,
  transactionStore,
}

let makeInternal = (
  ~chainConfig: Config.chain,
  ~indexingAddresses: array<Internal.indexingAddress>,
  ~startBlock,
  ~endBlock,
  ~firstEventBlock=None,
  ~progressBlockNumber,
  ~config: Config.t,
  ~registrations: HandlerRegister.registrations,
  ~logger,
  ~timestampCaughtUpToHeadOrEndblock,
  ~numEventsProcessed,
  ~isInReorgThreshold,
  ~isRealtime,
  ~reorgCheckpoints: array<Internal.reorgCheckpoint>,
  ~maxReorgDepth,
  ~knownHeight=0,
  ~reducedPollingInterval=?,
): t => {
  // We don't need the router itself, but only validation logic,
  // since now event router is created for selection of events
  // and validation doesn't work correctly in routers.
  // Ideally to split it into two different parts.
  let eventRouter = EventRouter.empty()

  // Aggregate events we want to fetch
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

      // Check if event has Static([]) filters (from a dynamic where
      // callback returning `false` / SkipAll for this chain).
      // If so, skip it entirely - it should never be fetched
      let shouldSkip = try {
        let getEventFiltersOrThrow = (
          eventConfig->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)
        ).getEventFiltersOrThrow

        // Check for non-evm chains
        if (
          getEventFiltersOrThrow->(Utils.magic: (ChainMap.Chain.t => Internal.eventFilters) => bool)
        ) {
          switch getEventFiltersOrThrow(ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id)) {
          | Static([]) => true
          | _ => false
          }
        } else {
          false
        }
      } catch {
      // Can throw when filter is invalid
      // Don't skip an event in this case. Let it throw in a better place - source code
      | _ => false
      }

      if shouldBeIncluded && !shouldSkip {
        eventConfigs->Array.push(eventConfig)
      }
    })

    switch contract.startBlock {
    | Some(startBlock) if startBlock < chainConfig.startBlock =>
      JsError.throwWithMessage(
        `The start block for contract "${contractName}" is less than the chain start block. This is not supported yet.`,
      )
    | _ => ()
    }
  })

  if notRegisteredEvents->Utils.Array.notEmpty {
    logger->Logging.childInfo(
      `The event${if notRegisteredEvents->Array.length > 1 {
          "s"
        } else {
          ""
        }} ${notRegisteredEvents
        ->Array.map(eventConfig => `${eventConfig.contractName}.${eventConfig.name}`)
        ->Array.joinUnsafe(", ")} don't have an event handler and skipped for indexing.`,
    )
  }

  let onBlockConfigs =
    registrations.onBlockByChainId->Utils.Dict.dangerouslyGetNonOption(chainConfig.id->Int.toString)
  switch onBlockConfigs {
  | Some(onBlockConfigs) =>
    // TODO: Move it to the HandlerRegister module
    // so the error is thrown with better stack trace
    onBlockConfigs->Array.forEach(onBlockConfig => {
      if onBlockConfig.startBlock->Option.getOr(startBlock) < startBlock {
        JsError.throwWithMessage(
          `The start block for onBlock handler "${onBlockConfig.name}" is less than the chain start block (${startBlock->Int.toString}). This is not supported yet.`,
        )
      }
      switch endBlock {
      | Some(chainEndBlock) =>
        if onBlockConfig.endBlock->Option.getOr(chainEndBlock) > chainEndBlock {
          JsError.throwWithMessage(
            `The end block for onBlock handler "${onBlockConfig.name}" is greater than the chain end block (${chainEndBlock->Int.toString}). This is not supported yet.`,
          )
        }
      | None => ()
      }
    })
  | None => ()
  }

  let contractConfigs = IndexingAddresses.makeContractConfigs(~eventConfigs)
  let indexingAddressIndex = IndexingAddresses.make(~contractConfigs, ~addresses=indexingAddresses)

  let fetchState = FetchState.make(
    ~maxAddrInPartition=config.maxAddrInPartition,
    ~contractConfigs,
    ~addresses=indexingAddresses,
    ~progressBlockNumber,
    ~startBlock,
    ~endBlock,
    ~eventConfigs,
    ~maxOnBlockBufferSize=2 * config.batchSize,
    ~knownHeight,
    ~chainId=chainConfig.id,
    // FIXME: Shouldn't set with full history
    ~blockLag=Pervasives.max(
      !config.shouldRollbackOnReorg || isInReorgThreshold ? 0 : chainConfig.maxReorgDepth,
      chainConfig.blockLag,
    ),
    ~onBlockConfigs?,
    ~firstEventBlock,
  )

  let chainReorgCheckpoints = reorgCheckpoints->Array.filterMap(reorgCheckpoint => {
    if reorgCheckpoint.chainId === chainConfig.id {
      Some(reorgCheckpoint)
    } else {
      None
    }
  })

  // Create sources lazily here - this is where API token validation happens
  let chain = ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id)
  let lowercaseAddresses = config.lowercaseAddresses
  let sources = switch chainConfig.sourceConfig {
  | Config.EvmSourceConfig({hypersync, rpcs}) =>
    // Build Internal.evmContractConfig from contracts for EvmChain.makeSources
    let evmContracts: array<Internal.evmContractConfig> = chainConfig.contracts->Array.map((
      contract
    ): Internal.evmContractConfig => {
      name: contract.name,
      abi: contract.abi,
      events: contract.events->(
        Utils.magic: array<Internal.eventConfig> => array<Internal.evmEventConfig>
      ),
    })
    let evmRpcs: array<EvmChain.rpc> = rpcs->Array.map((rpc): EvmChain.rpc => {
      let syncConfig = rpc.syncConfig
      let ws = rpc.ws
      let headers = rpc.headers
      {
        url: rpc.url,
        sourceFor: rpc.sourceFor,
        ?syncConfig,
        ?ws,
        ?headers,
      }
    })
    EvmChain.makeSources(
      ~chain,
      ~contracts=evmContracts,
      ~hyperSync=hypersync,
      ~rpcs=evmRpcs,
      ~lowercaseAddresses,
    )
  | Config.FuelSourceConfig({hypersync}) => [
      HyperFuelSource.make({chain, endpointUrl: hypersync, apiToken: Env.envioApiToken}),
    ]
  | Config.SvmSourceConfig({hypersync, rpc}) =>
    switch (hypersync, rpc) {
    | (None, None) =>
      JsError.throwWithMessage(
        `Chain ${chain->ChainMap.Chain.toChainId->Int.toString} has no SVM data source`,
      )
    | (None, Some(rpc)) => [Svm.makeRPCSource(~chain, ~rpc)]
    | (Some(hypersyncUrl), _) =>
      // HyperSync drives instruction sync. A configured RPC is ignored for now
      // (RPC fallback isn't wired up yet).
      let svmEventConfigs =
        chainConfig.contracts
        ->Array.flatMap(contract => contract.events)
        ->(Utils.magic: array<Internal.eventConfig> => array<Internal.svmInstructionEventConfig>)
      let apiToken = Env.envioApiToken
      [
        SvmHyperSyncSource.make({
          chain,
          endpointUrl: hypersyncUrl,
          apiToken,
          eventConfigs: svmEventConfigs,
          clientTimeoutMillis: Env.hyperSyncClientTimeoutMillis,
        }),
      ]
    }
  // For tests: use ready-to-use sources directly
  | Config.CustomSources(sources) => sources
  }

  make(
    ~chainConfig,
    ~fetchState,
    ~indexingAddresses=indexingAddressIndex,
    ~sourceManager=SourceManager.make(~sources, ~isRealtime, ~reducedPollingInterval?),
    ~reorgDetection=ReorgDetection.make(
      ~chainReorgCheckpoints,
      ~maxReorgDepth,
      ~shouldRollbackOnReorg=config.shouldRollbackOnReorg,
    ),
    ~safeCheckpointTracking=SafeCheckpointTracking.make(
      ~maxReorgDepth,
      ~shouldRollbackOnReorg=config.shouldRollbackOnReorg,
      ~chainReorgCheckpoints,
    ),
    ~committedProgressBlockNumber=progressBlockNumber,
    ~timestampCaughtUpToHeadOrEndblock,
    ~numEventsProcessed,
    ~transactionStore=TransactionStore.make(
      ~ecosystem=config.ecosystem.name,
      ~shouldChecksum=!lowercaseAddresses,
    ),
    ~logger,
  )
}

let makeFromConfig = (chainConfig: Config.chain, ~config, ~registrations, ~knownHeight) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.id})

  makeInternal(
    ~chainConfig,
    ~config,
    ~registrations,
    ~startBlock=chainConfig.startBlock,
    ~endBlock=chainConfig.endBlock,
    ~reorgCheckpoints=[],
    ~maxReorgDepth=chainConfig.maxReorgDepth,
    ~progressBlockNumber=-1,
    ~timestampCaughtUpToHeadOrEndblock=None,
    ~numEventsProcessed=0.,
    ~logger,
    ~indexingAddresses=configAddresses(chainConfig),
    ~isInReorgThreshold=false,
    ~isRealtime=false,
    ~knownHeight,
  )
}

/**
 * This function allows a chain state to be created from metadata, in particular this is useful for restarting an indexer and making sure it fetches blocks from the same place.
 */
let makeFromDbState = (
  chainConfig: Config.chain,
  ~resumedChainState: Persistence.initialChainState,
  ~reorgCheckpoints,
  ~isInReorgThreshold,
  ~isRealtime,
  ~config,
  ~registrations,
  ~reducedPollingInterval=?,
) => {
  let chainId = chainConfig.id
  let logger = Logging.createChild(~params={"chainId": chainId})

  Prometheus.ProgressEventsCount.set(~processedCount=resumedChainState.numEventsProcessed, ~chainId)

  let progressBlockNumber =
    // Can be -1 when not set
    resumedChainState.progressBlockNumber >= 0
      ? resumedChainState.progressBlockNumber
      : resumedChainState.startBlock - 1

  makeInternal(
    ~indexingAddresses=resumedChainState.indexingAddresses,
    ~chainConfig,
    ~startBlock=resumedChainState.startBlock,
    ~endBlock=resumedChainState.endBlock,
    ~config,
    ~registrations,
    ~reorgCheckpoints,
    ~maxReorgDepth=resumedChainState.maxReorgDepth,
    ~firstEventBlock=resumedChainState.firstEventBlockNumber,
    ~progressBlockNumber,
    ~timestampCaughtUpToHeadOrEndblock=Env.updateSyncTimeOnRestart
      ? None
      : resumedChainState.timestampCaughtUpToHeadOrEndblock,
    ~numEventsProcessed=resumedChainState.numEventsProcessed,
    ~logger,
    ~isInReorgThreshold,
    ~isRealtime,
    ~knownHeight=resumedChainState.sourceBlockNumber,
    ~reducedPollingInterval?,
  )
}

// --- Read accessors. ---

let logger = (cs: t) => cs.logger
let sourceManager = (cs: t) => cs.sourceManager
let chainConfig = (cs: t) => cs.chainConfig
let reorgDetection = (cs: t) => cs.reorgDetection
let safeCheckpointTracking = (cs: t) => cs.safeCheckpointTracking
let isProgressAtHead = (cs: t) => cs.isProgressAtHead
let committedProgressBlockNumber = (cs: t) => cs.committedProgressBlockNumber
let numEventsProcessed = (cs: t) => cs.numEventsProcessed
let pendingBudget = (cs: t) => cs.pendingBudget
let timestampCaughtUpToHeadOrEndblock = (cs: t) => cs.timestampCaughtUpToHeadOrEndblock

// Fetch-frontier reads. The FetchState is owned here; callers go through these
// rather than reaching into it.
let knownHeight = (cs: t) => cs.fetchState.knownHeight
let contractAddresses = (cs: t, ~contractName) =>
  cs.indexingAddresses->IndexingAddresses.getContractAddresses(~contractName)
let bufferSize = (cs: t) => cs.fetchState->FetchState.bufferSize
let bufferReadyCount = (cs: t) => cs.fetchState->FetchState.bufferReadyCount
let lastPruneTarget = (cs: t) => cs.lastPruneTarget
let clearPruneTarget = (cs: t) => cs.lastPruneTarget = None
let isQueryStillPending = (cs: t, ~query) => cs.fetchState->FetchState.isQueryStillPending(~query)
let getProgressPercentage = (cs: t) => cs.fetchState->FetchState.getProgressPercentage
let getProgressPercentageAt = (cs: t, ~blockNumber) =>
  cs.fetchState->FetchState.getProgressPercentageAt(~blockNumber)
let hasReadyItem = (cs: t) =>
  cs.fetchState->FetchState.isActivelyIndexing && cs.fetchState->FetchState.hasReadyItem
let isReadyToEnterReorgThreshold = (cs: t) => cs.fetchState->FetchState.isReadyToEnterReorgThreshold

// Mark queries as in flight and reserve their estimated size against the shared
// buffer budget in one step, so the counter stays in sync with the pending
// queries it tracks.
let startFetchingQueries = (cs: t, ~queries: array<FetchState.query>) => {
  cs.fetchState->FetchState.startFetchingQueries(~queries)
  cs.pendingBudget =
    cs.pendingBudget +. queries->Array.reduce(0., (acc, query) => acc +. query.estResponseSize)
}

// Drop every in-flight query and release their reservations together, keeping
// pendingBudget coupled to the pending queries it tracks.
let resetPendingQueries = (cs: t) => {
  cs.fetchState = cs.fetchState->FetchState.resetPendingQueries
  cs.pendingBudget = 0.
}

// Propose the chain's candidate queries for cross-chain admission.
let getNextQuery = (cs: t, ~hasBudget) => cs.fetchState->FetchState.getNextQuery(~hasBudget)

// Block to prune above (and how many buffer items that frees) for a given
// cross-chain progress threshold. See FetchState.getPruneTarget.
let getPruneTarget = (cs: t, ~progressThreshold) =>
  cs.fetchState->FetchState.getPruneTarget(
    ~progressThreshold,
    ~maxReorgDepth=cs.chainConfig.maxReorgDepth,
  )

// Reclaim buffer memory by discarding fetched-ahead items above targetBlockNumber
// and rolling the partitions that fetched them back to it, so they re-fetch later
// once processing has caught up. Unlike a reorg rollback this touches only the
// fetch frontier and transaction store — committed progress, reorg detection and
// the DB are untouched, since nothing processed is being reverted. In-flight
// queries above the target are dropped by the rollback itself (their late
// responses fail the still-pending check); queries at/below it keep running.
// Rolled-back partitions collapse to targetBlockNumber and re-merge,
// de-fragmenting them.
let pruneBuffer = (cs: t, ~targetBlockNumber) => {
  cs.fetchState =
    cs.fetchState->FetchState.rollback(~indexingAddresses=cs.indexingAddresses, ~targetBlockNumber)
  cs.transactionStore->TransactionStore.rollback(targetBlockNumber)
  cs.pendingBudget = cs.fetchState->FetchState.pendingBudgetSize

  // A later prune in the same above-target episode may land on a higher block
  // while ranges parked at the earlier target are still held back; keep the
  // lower target, or releasing them would refetch what the first prune dropped.
  cs.lastPruneTarget = Some(
    switch cs.lastPruneTarget {
    | Some(prev) => Pervasives.min(prev, targetBlockNumber)
    | None => targetBlockNumber
    },
  )
}

// Run a fetch tick for this chain against its sources, feeding the owned fetch
// frontier to the source manager.
let dispatch = (
  cs: t,
  ~executeQuery,
  ~waitForNewBlock,
  ~onNewBlock,
  ~action: FetchState.nextQuery,
  ~stateId,
) =>
  cs.sourceManager->SourceManager.dispatch(
    ~fetchState=cs.fetchState,
    ~executeQuery,
    ~waitForNewBlock,
    ~onNewBlock,
    ~action,
    ~stateId,
  )

// --- Derived (pure). ---

let hasProcessedToEndblock = (cs: t) => {
  let {committedProgressBlockNumber, fetchState} = cs
  switch fetchState.endBlock {
  | Some(endBlock) => committedProgressBlockNumber >= endBlock
  | None => false
  }
}

let getHighestBlockBelowThreshold = (cs: t): int => {
  let highestBlockBelowThreshold = cs.fetchState.knownHeight - cs.chainConfig.maxReorgDepth
  highestBlockBelowThreshold < 0 ? 0 : highestBlockBelowThreshold
}

let isActivelyIndexing = (cs: t) => cs.fetchState->FetchState.isActivelyIndexing

let isReady = (cs: t) => cs.timestampCaughtUpToHeadOrEndblock !== None

// True once the fetch frontier has reached the head/endBlock for this chain.
let isFetchingAtHead = (cs: t) => cs.fetchState->FetchState.isFetchingAtHead

// Reached head on a chain with no configured endBlock — used by auto-exit to
// detect that no events were found in the start..head range.
let isAtHeadWithoutEndBlock = (cs: t) =>
  cs.isProgressAtHead && cs.fetchState.endBlock->Option.isNone

// --- State transitions. The chain state is mutated only through these; each
// owns a cohesive update so callers don't juggle individual fields. ---

// Apply a fetch response: register any new dynamic contracts, append the items
// to the buffer and advance the known head.
// Materialise the chain store's selected transaction fields onto a batch's
// items at batch prep (the persistent-store path).
let materializeBatchItems = (cs: t, ~items: array<Internal.item>) =>
  cs.transactionStore->TransactionStore.materializeItems(~items)

// Materialise a fetch-response page's transactions onto its items before
// contract-register handlers read them. `None` pages (RPC/Fuel/Simulate keep the
// transaction inline) are a no-op.
let materializePageItems = (~items: array<Internal.item>, ~page: option<TransactionStore.t>) =>
  switch page {
  | Some(store) => store->TransactionStore.materializeItems(~items)
  | None => Promise.resolve()
  }

let handleQueryResult = (
  cs: t,
  ~query: FetchState.query,
  ~newItems,
  ~newItemsWithDcs,
  ~latestFetchedBlock,
  ~knownHeight,
  ~transactionStore as page: option<TransactionStore.t>,
) => {
  // Merge this response's page into the chain store in lockstep with appending
  // its items to the buffer. Inline-transaction sources contribute no page.
  switch page {
  | Some(page) => cs.transactionStore->TransactionStore.merge(page)
  | None => ()
  }

  let fs = switch newItemsWithDcs {
  | [] => cs.fetchState
  | _ =>
    cs.fetchState->FetchState.registerDynamicContracts(
      ~indexingAddresses=cs.indexingAddresses,
      newItemsWithDcs,
    )
  }

  cs.fetchState =
    fs
    ->FetchState.handleQueryResult(
      ~indexingAddresses=cs.indexingAddresses,
      ~query,
      ~latestFetchedBlock,
      ~newItems,
    )
    ->FetchState.updateKnownHeight(~knownHeight)

  // The query is no longer in flight, so release its reservation.
  cs.pendingBudget = Pervasives.max(0., cs.pendingBudget -. query.estResponseSize)
}

// Run reorg detection against a fetch response and commit the updated guard.
// Returns the result so the caller can decide whether to roll back; on the
// rollback path registerReorgGuard returns the guard unchanged, so committing
// here is a no-op there.
let registerReorgGuard = (cs: t, ~blockHashes, ~knownHeight): ReorgDetection.reorgResult => {
  let (updatedReorgDetection, reorgResult) =
    cs.reorgDetection->ReorgDetection.registerReorgGuard(~blockHashes, ~knownHeight)
  cs.reorgDetection = updatedReorgDetection
  reorgResult
}

// Prepare for a reorg rollback: restore the events-processed counter to its
// pre-rollback value when an uncommitted rollback diff is being redone, and drop
// pending queries bound to the about-to-be-invalidated chain state.
let prepareReorg = (cs: t, ~eventsProcessedDiff) => {
  switch eventsProcessedDiff {
  | Some(diff) => cs.numEventsProcessed = cs.numEventsProcessed +. diff
  | None => ()
  }
  cs->resetPendingQueries
}

let updateKnownHeight = (cs: t, ~knownHeight) =>
  cs.fetchState = cs.fetchState->FetchState.updateKnownHeight(~knownHeight)

// In auto-exit mode, pin the endBlock to the earliest observed event block.
let setEndBlockToFirstEvent = (cs: t, ~blockNumber) =>
  switch cs.fetchState.endBlock {
  | None => cs.fetchState = {...cs.fetchState, endBlock: Some(blockNumber)}
  | Some(currentEndBlock) if blockNumber < currentEndBlock =>
    cs.fetchState = {...cs.fetchState, endBlock: Some(blockNumber)}
  | Some(_) => ()
  }

// Shrink the fetch buffer by the configured blockLag on entering the reorg threshold.
let enterReorgThreshold = (cs: t) =>
  cs.fetchState = cs.fetchState->FetchState.updateInternal(~blockLag=cs.chainConfig.blockLag)

// Snapshot the chain's metadata fields for staging into the chains table.
let toChainMetadata = (cs: t): InternalTable.Chains.metaFields => {
  firstEventBlockNumber: cs.fetchState.firstEventBlock->Null.fromOption,
  isHyperSync: (cs.sourceManager->SourceManager.getActiveSource).poweredByHyperSync,
  latestFetchedBlockNumber: cs.fetchState->FetchState.bufferBlockNumber,
  timestampCaughtUpToHeadOrEndblock: cs.timestampCaughtUpToHeadOrEndblock->Null.fromOption,
}

// Snapshot the chain's view for the status API.
let toChainData = (cs: t): chainData => {
  chainId: cs.chainConfig.id->Int.toFloat,
  poweredByHyperSync: (cs.sourceManager->SourceManager.getActiveSource).poweredByHyperSync,
  firstEventBlockNumber: cs.fetchState.firstEventBlock,
  latestProcessedBlock: cs.committedProgressBlockNumber === -1
    ? None
    : Some(cs.committedProgressBlockNumber),
  timestampCaughtUpToHeadOrEndblock: cs.timestampCaughtUpToHeadOrEndblock,
  numEventsProcessed: cs.numEventsProcessed,
  latestFetchedBlockNumber: Pervasives.max(cs.fetchState->FetchState.bufferBlockNumber, 0),
  knownHeight: cs->hasProcessedToEndblock
    ? cs.fetchState.endBlock->Option.getOr(cs.fetchState.knownHeight)
    : cs.fetchState.knownHeight,
  numBatchesFetched: 0,
  startBlock: cs.fetchState.startBlock,
  endBlock: cs.fetchState.endBlock,
  numAddresses: cs.indexingAddresses->IndexingAddresses.size,
}

// Snapshot the inputs a batch build needs from this chain.
let toChainBeforeBatch = (cs: t): Batch.chainBeforeBatch => {
  fetchState: cs.fetchState,
  progressBlockNumber: cs.committedProgressBlockNumber,
  totalEventsProcessed: cs.numEventsProcessed,
  sourceBlockNumber: cs.fetchState.knownHeight,
  reorgDetection: cs.reorgDetection,
  chainConfig: cs.chainConfig,
}

// Whether the chain's post-batch fetch frontier is ready to cross into the reorg
// threshold, using the batch's progressed frontier when this chain advanced.
let isReadyToEnterReorgThresholdAfterBatch = (cs: t, ~batch: Batch.t) => {
  let fetchState = switch batch.progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(
    cs.fetchState.chainId,
  ) {
  | Some(chainAfterBatch) => chainAfterBatch.fetchState
  | None => cs.fetchState
  }
  fetchState->FetchState.isReadyToEnterReorgThreshold
}

// Commit the post-batch fetch frontier for a chain that progressed in the batch,
// applying blockLag when this batch also crosses into the reorg threshold.
let advanceAfterBatch = (cs: t, ~batch: Batch.t, ~enteringReorgThreshold) =>
  switch batch.progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(
    cs.fetchState.chainId,
  ) {
  | Some(chainAfterBatch) =>
    cs.fetchState = enteringReorgThreshold
      ? chainAfterBatch.fetchState->FetchState.updateInternal(~blockLag=cs.chainConfig.blockLag)
      : chainAfterBatch.fetchState
  | None => ()
  }

// Commit a processed batch's progress for this chain (progress block, events
// processed, head/safe-checkpoint tracking, first event block). Emits the
// per-chain progress metrics. Readiness is decided by CrossChainState once every
// chain is caught up (see markReady).
let applyBatchProgress = (cs: t, ~batch: Batch.t) => {
  let chainId = cs.chainConfig.id

  switch batch.progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(chainId) {
  | Some(chainAfterBatch) => {
      if cs.committedProgressBlockNumber !== chainAfterBatch.progressBlockNumber {
        Prometheus.ProgressBlockNumber.set(
          ~blockNumber=chainAfterBatch.progressBlockNumber,
          ~chainId,
        )
      }
      if cs.numEventsProcessed !== chainAfterBatch.totalEventsProcessed {
        Prometheus.ProgressEventsCount.set(
          ~processedCount=chainAfterBatch.totalEventsProcessed,
          ~chainId,
        )
      }

      // Calculate and set latency metrics
      switch batch->Batch.findLastEventItem(~chainId) {
      | Some(eventItem) => {
          let blockTimestampMs = eventItem.timestamp * 1000
          Prometheus.ProgressLatency.set(
            ~latencyMs=Date.now()->Float.toInt - blockTimestampMs,
            ~chainId,
          )
        }
      | None => ()
      }

      // Since we process per chain always in order, calculate firstEventBlock
      // once, from the first item in a batch.
      switch cs.fetchState.firstEventBlock {
      | Some(_) => ()
      | None =>
        switch batch->Batch.findFirstEventBlockNumber(~chainId) {
        | Some(_) as firstEventBlock => cs.fetchState = {...cs.fetchState, firstEventBlock}
        | None => ()
        }
      }

      cs.committedProgressBlockNumber = chainAfterBatch.progressBlockNumber
      cs.numEventsProcessed = chainAfterBatch.totalEventsProcessed
      // Processed blocks' transactions are no longer needed.
      cs.transactionStore->TransactionStore.prune(chainAfterBatch.progressBlockNumber)
      cs.isProgressAtHead = cs.isProgressAtHead || chainAfterBatch.isProgressAtHeadWhenBatchCreated
      switch cs.safeCheckpointTracking {
      | Some(safeCheckpointTracking) =>
        cs.safeCheckpointTracking = Some(
          safeCheckpointTracking->SafeCheckpointTracking.updateOnNewBatch(
            ~sourceBlockNumber=cs.fetchState.knownHeight,
            ~chainId,
            ~batchCheckpointIds=batch.checkpointIds,
            ~batchCheckpointBlockNumbers=batch.checkpointBlockNumbers,
            ~batchCheckpointChainIds=batch.checkpointChainIds,
          ),
        )
      | None => ()
      }
    }
  | None => ()
  }
}

// Mark the chain caught up to head/endblock. Called by CrossChainState only once
// every chain in the indexer is caught up, so no chain flips to ready while
// another is still backfilling. Sticky: a chain stays ready once set.
let markReady = (cs: t) =>
  if !(cs->isReady) {
    cs.timestampCaughtUpToHeadOrEndblock = Date.make()->Some
    Prometheus.ProgressReady.set(~chainId=cs.chainConfig.id)
  }

// Roll a chain back to a reorg target. With a progress diff, restore fetch/
// safe-checkpoint/progress state to `newProgressBlockNumber`; the reorg chain
// additionally rewinds its reorg-detection guard. A reorg chain with no diff
// entry still rewinds guard + fetch state to the target — otherwise the stale
// block hash stays in the guard and re-triggers the same reorg.
let rollback = (
  cs: t,
  ~newProgressBlockNumber,
  ~eventsProcessedDiff,
  ~rollbackTargetBlockNumber,
  ~isReorgChain,
) => {
  let chainId = cs.chainConfig.id
  switch newProgressBlockNumber {
  | Some(newProgressBlockNumber) =>
    let newTotalEventsProcessed =
      cs.numEventsProcessed -.
      // Both dicts are populated together per progress-diff row, so a chain with
      // a progress diff always has an events-processed diff too.
      eventsProcessedDiff->Option.getOrThrow(
        ~message="Missing events-processed diff for rolled-back chain",
      )

    if cs.committedProgressBlockNumber !== newProgressBlockNumber {
      Prometheus.ProgressBlockNumber.set(~blockNumber=newProgressBlockNumber, ~chainId)
    }
    if cs.numEventsProcessed !== newTotalEventsProcessed {
      Prometheus.ProgressEventsCount.set(~processedCount=newTotalEventsProcessed, ~chainId)
    }
    if isReorgChain {
      cs.reorgDetection =
        cs.reorgDetection->ReorgDetection.rollbackToValidBlockNumber(
          ~blockNumber=rollbackTargetBlockNumber,
        )
    }
    switch cs.safeCheckpointTracking {
    | Some(safeCheckpointTracking) =>
      cs.safeCheckpointTracking = Some(
        safeCheckpointTracking->SafeCheckpointTracking.rollback(
          ~targetBlockNumber=newProgressBlockNumber,
        ),
      )
    | None => ()
    }
    cs.fetchState =
      cs.fetchState->FetchState.rollback(
        ~indexingAddresses=cs.indexingAddresses,
        ~targetBlockNumber=newProgressBlockNumber,
      )
    cs.transactionStore->TransactionStore.rollback(newProgressBlockNumber)
    cs.committedProgressBlockNumber = newProgressBlockNumber
    cs.numEventsProcessed = newTotalEventsProcessed
  | None =>
    if isReorgChain {
      cs.reorgDetection =
        cs.reorgDetection->ReorgDetection.rollbackToValidBlockNumber(
          ~blockNumber=rollbackTargetBlockNumber,
        )
      cs.fetchState =
        cs.fetchState->FetchState.rollback(
          ~indexingAddresses=cs.indexingAddresses,
          ~targetBlockNumber=rollbackTargetBlockNumber,
        )
      cs.transactionStore->TransactionStore.rollback(rollbackTargetBlockNumber)
      cs.committedProgressBlockNumber = Pervasives.min(
        cs.committedProgressBlockNumber,
        rollbackTargetBlockNumber,
      )
    }
  }
}
