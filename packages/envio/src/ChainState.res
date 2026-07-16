// Per-chain runtime state. `t` is mutated in place through the setters below;
// the type is opaque in the interface so callers can read fields but can only
// change them through the sanctioned mutators.

type t = {
  logger: Pino.t,
  // The registrations used to build this chain's sources and route native items.
  onEventRegistrations: array<Internal.onEventRegistration>,
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
  mutable reorgDetection: ReorgDetection.t,
  mutable safeCheckpointTracking: option<SafeCheckpointTracking.t>,
  // Holds this chain's transactions (kept in Rust) keyed by (blockNumber,
  // transactionIndex). Fetch responses merge their page in; entries are pruned
  // as the chain progresses and dropped above the target on rollback.
  transactionStore: TransactionStore.t,
  // Holds this chain's blocks (kept in Rust) keyed by block number. Same merge /
  // prune / rollback lifecycle as the transaction store.
  blockStore: BlockStore.t,
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

let validateOnEventRegistrations = (
  ~chainId: int,
  registrations: array<Internal.onEventRegistration>,
) =>
  registrations->Array.forEachWithIndex((registration, expectedIndex) => {
    if registration.index !== expectedIndex {
      JsError.throwWithMessage(
        `Invalid onEvent registration index for chain ${chainId->Int.toString}: ${registration.eventConfig.contractName}.${registration.eventConfig.name} has index ${registration.index->Int.toString}, but its ChainState position is ${expectedIndex->Int.toString}.`,
      )
    }
  })

let make = (
  ~chainConfig: Config.chain,
  ~fetchState: FetchState.t,
  ~onEventRegistrations=[],
  ~indexingAddresses: IndexingAddresses.t,
  ~sourceManager: SourceManager.t,
  ~reorgDetection: ReorgDetection.t,
  ~committedProgressBlockNumber: int,
  ~safeCheckpointTracking=None,
  ~numEventsProcessed=0.,
  ~timestampCaughtUpToHeadOrEndblock=None,
  ~isProgressAtHead=false,
  ~transactionStore=TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
  ~blockStore=BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
  ~logger: Pino.t,
): t => {
  validateOnEventRegistrations(~chainId=chainConfig.id, onEventRegistrations)
  {
    logger,
    onEventRegistrations,
    fetchState,
    indexingAddresses,
    sourceManager,
    chainConfig,
    isProgressAtHead,
    timestampCaughtUpToHeadOrEndblock,
    committedProgressBlockNumber,
    numEventsProcessed,
    pendingBudget: 0.,
    reorgDetection,
    safeCheckpointTracking,
    transactionStore,
    blockStore,
  }
}

let makeInternal = (
  ~chainConfig: Config.chain,
  ~indexingAddresses: array<Internal.indexingAddress>,
  ~startBlock,
  ~endBlock,
  ~firstEventBlock=None,
  ~progressBlockNumber,
  ~config: Config.t,
  ~registrationsByChainId: HandlerRegister.registrationsByChainId,
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
  // Handler binding + `where`-derived fetch state, and onBlock registrations,
  // are already collected by `HandlerRegister.finishRegistration`, keyed by
  // chain - this just looks up this chain's slice.
  let {onEventRegistrations, onBlockRegistrations} =
    registrationsByChainId
    ->Utils.Dict.dangerouslyGetNonOption(chainConfig.id->Int.toString)
    ->Option.getOr({onEventRegistrations: [], onBlockRegistrations: []})

  chainConfig.contracts->Array.forEach(contract => {
    switch contract.startBlock {
    | Some(startBlock) if startBlock < chainConfig.startBlock =>
      JsError.throwWithMessage(
        `The start block for contract "${contract.name}" is less than the chain start block. This is not supported yet.`,
      )
    | _ => ()
    }
  })

  let contractConfigs = IndexingAddresses.makeContractConfigs(~onEventRegistrations)
  let indexingAddressIndex = IndexingAddresses.make(~contractConfigs, ~addresses=indexingAddresses)

  let fetchState = FetchState.make(
    ~maxAddrInPartition=config.maxAddrInPartition,
    ~contractConfigs,
    ~addresses=indexingAddresses,
    ~progressBlockNumber,
    ~startBlock,
    ~endBlock,
    ~onEventRegistrations,
    ~maxOnBlockBufferSize=2 * config.batchSize,
    ~knownHeight,
    ~chainId=chainConfig.id,
    // FIXME: Shouldn't set with full history
    ~blockLag=Pervasives.max(
      !config.shouldRollbackOnReorg || isInReorgThreshold ? 0 : chainConfig.maxReorgDepth,
      chainConfig.blockLag,
    ),
    ~onBlockRegistrations,
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
      ~onEventRegistrations=onEventRegistrations->(
        Utils.magic: array<Internal.onEventRegistration> => array<Internal.evmOnEventRegistration>
      ),
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
      let apiToken = Env.envioApiToken
      [
        SvmHyperSyncSource.make({
          chain,
          endpointUrl: hypersyncUrl,
          apiToken,
          onEventRegistrations,
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
    ~onEventRegistrations,
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
    ~blockStore=BlockStore.make(
      ~ecosystem=config.ecosystem.name,
      ~shouldChecksum=!lowercaseAddresses,
    ),
    ~logger,
  )
}

let makeFromConfig = (
  chainConfig: Config.chain,
  ~config,
  ~registrationsByChainId,
  ~knownHeight,
) => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.id})

  makeInternal(
    ~chainConfig,
    ~config,
    ~registrationsByChainId,
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
  ~registrationsByChainId,
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
    ~registrationsByChainId,
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

// Propose the chain's candidate queries against their natural ceiling
// (head/endBlock/mergeBlock). CrossChainState admits them against the shared
// buffer budget afterwards.
let getNextQuery = (cs: t) => cs.fetchState->FetchState.getNextQuery

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

// Per-store grouping data a single pass over `items` produces (see
// `groupBatchItems`), fed into `TransactionStore`/`BlockStore`'s `materialize`.
type transactionGroups = {
  txBlockNumbers: array<int>,
  transactionIndices: array<int>,
  transactionMasks: array<float>,
  payloadGroups: array<array<Internal.eventPayload>>,
  anyTransactionFieldSelected: bool,
}
type blockGroups = {
  blockBlockNumbers: array<int>,
  blockMasks: array<float>,
  blockItemGroups: array<array<Internal.eventItem>>,
}

// Walk `items` once to build both the transaction-store and block-store
// grouping data, instead of `TransactionStore`/`BlockStore` each re-walking the
// same batch independently. Items already arrive in (blockNumber, logIndex)
// order, so a (blockNumber, transactionIndex) run and a blockNumber-only run
// each stay adjacent; every item is checked against both, in the same pass.
// `includeBlocks` skips the block side entirely for Fuel, which carries the
// block inline and has no store.
let groupBatchItems = (items: array<Internal.item>, ~includeBlocks: bool): (
  transactionGroups,
  blockGroups,
) => {
  let txBlockNumbers = []
  let transactionIndices = []
  let transactionMasks = []
  let payloadGroups = []
  let anyTransactionFieldSelected = ref(false)

  let blockBlockNumbers = []
  let blockMasks = []
  let blockItemGroups = []

  items->Array.forEach(item =>
    switch item {
    | Internal.Event(_) =>
      let eventItem = item->Internal.castUnsafeEventItem
      let {blockNumber} = eventItem

      switch eventItem.payload->Internal.getPayloadTransaction->Nullable.toOption {
      | Some(_) => () // RPC/simulate/Fuel carry the transaction inline.
      | None =>
        let {transactionIndex} = eventItem
        let mask = eventItem.onEventRegistration.eventConfig.transactionFieldMask
        if mask != 0. {
          anyTransactionFieldSelected := true
        }
        let last = payloadGroups->Array.length - 1
        if (
          last >= 0 &&
          txBlockNumbers->Array.getUnsafe(last) == blockNumber &&
          transactionIndices->Array.getUnsafe(last) == transactionIndex
        ) {
          payloadGroups->Array.getUnsafe(last)->Array.push(eventItem.payload)
          transactionMasks->Array.setUnsafe(
            last,
            FieldMask.orMask(transactionMasks->Array.getUnsafe(last), mask),
          )
        } else {
          txBlockNumbers->Array.push(blockNumber)
          transactionIndices->Array.push(transactionIndex)
          transactionMasks->Array.push(mask)
          payloadGroups->Array.push([eventItem.payload])
        }
      }

      if includeBlocks {
        switch eventItem.payload->Internal.getPayloadBlock->Nullable.toOption {
        | Some(_) => () // RPC/simulate/Fuel carry the block inline.
        | None =>
          let mask = eventItem.onEventRegistration.eventConfig.blockFieldMask
          let last = blockItemGroups->Array.length - 1
          if last >= 0 && blockBlockNumbers->Array.getUnsafe(last) == blockNumber {
            blockItemGroups->Array.getUnsafe(last)->Array.push(eventItem)
            blockMasks->Array.setUnsafe(
              last,
              FieldMask.orMask(blockMasks->Array.getUnsafe(last), mask),
            )
          } else {
            blockBlockNumbers->Array.push(blockNumber)
            blockMasks->Array.push(mask)
            blockItemGroups->Array.push([eventItem])
          }
        }
      }
    | Internal.Block(_) => ()
    }
  )

  (
    {
      txBlockNumbers,
      transactionIndices,
      transactionMasks,
      payloadGroups,
      anyTransactionFieldSelected: anyTransactionFieldSelected.contents,
    },
    {blockBlockNumbers, blockMasks, blockItemGroups},
  )
}

// Materialise a `TransactionStore` against precomputed groups (see
// `groupBatchItems`). Store-backed items always get a transaction object — the
// selected fields, or `{}` when nothing was selected — so `event.transaction`
// is never `undefined` (matching the inline sources).
let applyTransactionGroups = async (store: TransactionStore.t, g: transactionGroups) => {
  if g.payloadGroups->Utils.Array.notEmpty {
    if g.anyTransactionFieldSelected {
      let txs = await store->TransactionStore.materialize(
        ~blockNumbers=g.txBlockNumbers,
        ~transactionIndices=g.transactionIndices,
        ~masks=g.transactionMasks,
      )
      g.payloadGroups->Array.forEachWithIndex((payloads, i) => {
        let tx = txs->Array.getUnsafe(i)
        payloads->Array.forEach(payload => payload->Internal.setPayloadTransaction(tx))
      })
    } else {
      g.payloadGroups->Array.forEach(payloads =>
        payloads->Array.forEach(payload => payload->Internal.setPayloadTransaction(%raw(`{}`)))
      )
    }
  }
}

// Materialise a `BlockStore` against precomputed groups (see `groupBatchItems`).
let applyBlockGroups = async (store: BlockStore.t, g: blockGroups) => {
  if g.blockItemGroups->Utils.Array.notEmpty {
    let blocks = await store->BlockStore.materialize(
      ~blockNumbers=g.blockBlockNumbers,
      ~masks=g.blockMasks,
    )
    g.blockItemGroups->Array.forEachWithIndex((group, i) => {
      let block = blocks->Array.getUnsafe(i)
      group->Array.forEach(ei => ei.payload->Internal.setPayloadBlock(block))
    })
  }
}

let includeBlocksForEcosystem = (ecosystem: Ecosystem.name) =>
  switch ecosystem {
  | Evm | Svm => true
  | Fuel => false
  }

// Materialise the chain stores' selected transaction and block fields onto a
// batch's items at batch prep (the persistent-store path). A single pass over
// `items` (`groupBatchItems`) builds both stores' selection masks before the
// two independent materialize calls run concurrently.
let materializeBatchItems = async (cs: t, ~items: array<Internal.item>, ~ecosystem) => {
  let (txGroups, blockGroups) =
    items->groupBatchItems(~includeBlocks=ecosystem->includeBlocksForEcosystem)
  let _ = await Promise.all2((
    cs.transactionStore->applyTransactionGroups(txGroups),
    cs.blockStore->applyBlockGroups(blockGroups),
  ))
}

// Materialise a fetch-response page's transactions and blocks onto its items
// before contract-register handlers read them. `None` pages (RPC/Fuel/Simulate
// keep them inline) are a no-op.
let materializePageItems = async (
  ~items: array<Internal.item>,
  ~transactionStore: option<TransactionStore.t>,
  ~blockStore: option<BlockStore.t>,
  ~ecosystem,
) => {
  let (txGroups, blockGroups) =
    items->groupBatchItems(~includeBlocks=ecosystem->includeBlocksForEcosystem)
  let _ = await Promise.all2((
    switch transactionStore {
    | Some(store) => store->applyTransactionGroups(txGroups)
    | None => Promise.resolve()
    },
    switch blockStore {
    | Some(store) => store->applyBlockGroups(blockGroups)
    | None => Promise.resolve()
    },
  ))
}

let filterByClientAddress = (cs: t, items: array<Internal.item>): array<Internal.item> =>
  items->FetchState.filterByClientAddress(~indexingAddresses=cs.indexingAddresses)

let handleQueryResult = (
  cs: t,
  ~query: FetchState.query,
  ~newItems,
  ~newItemsWithDcs,
  ~latestFetchedBlock,
  ~knownHeight,
  ~transactionStore as txPage: option<TransactionStore.t>,
  ~blockStore as blockPage: option<BlockStore.t>,
) => {
  // Merge this response's pages into the chain stores in lockstep with appending
  // its items to the buffer. Inline sources contribute no page.
  switch txPage {
  | Some(page) => cs.transactionStore->TransactionStore.merge(page)
  | None => ()
  }
  switch blockPage {
  | Some(page) => cs.blockStore->BlockStore.merge(page)
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
// chain is caught up (see markReady). `blockTimestampName` is the ecosystem's
// block-timestamp field, read off the payload block for the latency metric.
let applyBatchProgress = (cs: t, ~batch: Batch.t, ~blockTimestampName: string) => {
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

      // Calculate and set latency metrics. The payload block is materialised or
      // inline by processing time; its timestamp may still be absent (e.g. an
      // SVM slot with no block row) — the metric is skipped then.
      switch batch
      ->Batch.findLastEventItem(~chainId)
      ->Option.flatMap(eventItem =>
        eventItem.payload
        ->Internal.getPayloadBlock
        ->Nullable.toOption
      )
      ->Option.flatMap(block =>
        block
        ->(Utils.magic: Internal.eventBlock => dict<unknown>)
        ->Utils.Dict.dangerouslyGetNonOption(blockTimestampName)
      ) {
      | Some(blockTimestamp) =>
        let blockTimestampMs = blockTimestamp->(Utils.magic: unknown => int) * 1000
        Prometheus.ProgressLatency.set(
          ~latencyMs=Date.now()->Float.toInt - blockTimestampMs,
          ~chainId,
        )
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
      // Processed blocks' transactions and blocks are no longer needed.
      cs.transactionStore->TransactionStore.prune(chainAfterBatch.progressBlockNumber)
      cs.blockStore->BlockStore.prune(chainAfterBatch.progressBlockNumber)
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
    cs.blockStore->BlockStore.rollback(newProgressBlockNumber)
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
      cs.blockStore->BlockStore.rollback(rollbackTargetBlockNumber)
      cs.committedProgressBlockNumber = Pervasives.min(
        cs.committedProgressBlockNumber,
        rollbackTargetBlockNumber,
      )
    }
  }
}
