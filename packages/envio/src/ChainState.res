// Per-chain runtime state. `t` is mutated in place through the setters below;
// the type is opaque in the interface so callers can read fields but can only
// change them through the sanctioned mutators.

type t = {
  logger: Pino.t,
  mutable fetchState: FetchState.t,
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
  mutable reorgDetection: ReorgDetection.t,
  mutable safeCheckpointTracking: option<SafeCheckpointTracking.t>,
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
  ~sourceManager: SourceManager.t,
  ~reorgDetection: ReorgDetection.t,
  ~committedProgressBlockNumber: int,
  ~safeCheckpointTracking=None,
  ~numEventsProcessed=0.,
  ~timestampCaughtUpToHeadOrEndblock=None,
  ~isProgressAtHead=false,
  ~logger: Pino.t,
): t => {
  logger,
  fetchState,
  sourceManager,
  chainConfig,
  isProgressAtHead,
  timestampCaughtUpToHeadOrEndblock,
  committedProgressBlockNumber,
  numEventsProcessed,
  pendingBudget: 0.,
  reorgDetection,
  safeCheckpointTracking,
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

  let fetchState = FetchState.make(
    ~maxAddrInPartition=config.maxAddrInPartition,
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
      {
        url: rpc.url,
        sourceFor: rpc.sourceFor,
        ?syncConfig,
        ?ws,
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
let fetchState = (cs: t) => cs.fetchState
let sourceManager = (cs: t) => cs.sourceManager
let chainConfig = (cs: t) => cs.chainConfig
let reorgDetection = (cs: t) => cs.reorgDetection
let safeCheckpointTracking = (cs: t) => cs.safeCheckpointTracking
let isProgressAtHead = (cs: t) => cs.isProgressAtHead
let committedProgressBlockNumber = (cs: t) => cs.committedProgressBlockNumber
let numEventsProcessed = (cs: t) => cs.numEventsProcessed
let pendingBudget = (cs: t) => cs.pendingBudget
let timestampCaughtUpToHeadOrEndblock = (cs: t) => cs.timestampCaughtUpToHeadOrEndblock

// Reserve the estimated size of queries about to be dispatched, so the shared
// buffer budget accounts for them while they're in flight.
let addPendingBudget = (cs: t, ~amount) => cs.pendingBudget = cs.pendingBudget +. amount

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

// --- State transitions. The chain state is mutated only through these; each
// owns a cohesive update so callers don't juggle individual fields. ---

// Apply a fetch response: register any new dynamic contracts, append the items
// to the buffer and advance the known head.
let handleQueryResult = (
  cs: t,
  ~query: FetchState.query,
  ~newItems,
  ~newItemsWithDcs,
  ~latestFetchedBlock,
  ~knownHeight,
) => {
  let fs = switch newItemsWithDcs {
  | [] => cs.fetchState
  | _ => cs.fetchState->FetchState.registerDynamicContracts(newItemsWithDcs)
  }

  cs.fetchState =
    fs
    ->FetchState.handleQueryResult(~query, ~latestFetchedBlock, ~newItems)
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
  cs.fetchState = cs.fetchState->FetchState.resetPendingQueries

  // resetPendingQueries drops every in-flight query, so nothing is reserved.
  cs.pendingBudget = 0.
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
    cs.fetchState = cs.fetchState->FetchState.rollback(~targetBlockNumber=newProgressBlockNumber)
    cs.pendingBudget = cs.fetchState->FetchState.reservedSize
    cs.committedProgressBlockNumber = newProgressBlockNumber
    cs.numEventsProcessed = newTotalEventsProcessed
  | None =>
    if isReorgChain {
      cs.reorgDetection =
        cs.reorgDetection->ReorgDetection.rollbackToValidBlockNumber(
          ~blockNumber=rollbackTargetBlockNumber,
        )
      cs.fetchState =
        cs.fetchState->FetchState.rollback(~targetBlockNumber=rollbackTargetBlockNumber)
      cs.pendingBudget = cs.fetchState->FetchState.reservedSize
      cs.committedProgressBlockNumber = Pervasives.min(
        cs.committedProgressBlockNumber,
        rollbackTargetBlockNumber,
      )
    }
  }
}
