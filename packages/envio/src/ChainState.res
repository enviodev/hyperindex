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
  // Progress of the batch currently being processed. The buffer is consumed at
  // batch creation (see advanceAfterBatch), so this runs ahead of
  // committedProgressBlockNumber until the batch commits — it's the true lower
  // boundary of the remaining buffer's block span.
  mutable processingBlockNumber: int,
  mutable numEventsProcessed: float,
  // Running sum of in-flight queries' itemsTarget, kept here so the
  // scheduler doesn't re-sum pending queries on every tick. Incremented when
  // queries are dispatched, decremented as their responses land.
  mutable pendingBudget: float,
  // Chain-wide events/block, used to turn a chain's item budget into a target
  // block for query sizing. Seeded from cumulative progress on construction,
  // then smoothed with an EMA on every batch (see applyBatchProgress). None
  // until the chain has processed at least one event.
  mutable chainDensity: option<float>,
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
  ~chainDensity=None,
  ~blockStore=BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
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
  processingBlockNumber: committedProgressBlockNumber,
  numEventsProcessed,
  pendingBudget: 0.,
  chainDensity,
  reorgDetection,
  safeCheckpointTracking,
  transactionStore,
  blockStore,
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

  // Seed chain density from whatever progress this chain already has (from a
  // resumed DB state, or 0 on a fresh chain) — refined per-batch afterwards.
  let chainDensity = switch fetchState.firstEventBlock {
  | Some(firstEventBlock) if progressBlockNumber > firstEventBlock && numEventsProcessed > 0. =>
    Some(numEventsProcessed /. (progressBlockNumber - firstEventBlock)->Int.toFloat)
  | _ => None
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
    ~chainDensity,
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
let chainDensity = (cs: t) => cs.chainDensity
let hasReadyItem = (cs: t) =>
  cs.fetchState->FetchState.isActivelyIndexing && cs.fetchState->FetchState.hasReadyItem
let isReadyToEnterReorgThreshold = (cs: t) => cs.fetchState->FetchState.isReadyToEnterReorgThreshold

// Mark queries as in flight and reserve their estimated size against the shared
// buffer budget in one step, so the counter stays in sync with the pending
// queries it tracks.
let startFetchingQueries = (cs: t, ~queries: array<FetchState.query>) => {
  cs.fetchState->FetchState.startFetchingQueries(~queries)
  cs.pendingBudget =
    cs.pendingBudget +.
    queries->Array.reduce(0., (acc, query) => acc +. query.itemsTarget->Int.toFloat)
}

// Drop every in-flight query and release their reservations together, keeping
// pendingBudget coupled to the pending queries it tracks.
let resetPendingQueries = (cs: t) => {
  cs.fetchState = cs.fetchState->FetchState.resetPendingQueries
  cs.pendingBudget = 0.
}

let isReady = (cs: t) => cs.timestampCaughtUpToHeadOrEndblock !== None

// Block span over which a batch fully replaces the chain density estimate;
// smaller batches blend in proportionally, so a few sparse/dense blocks only
// nudge it.
let densityBlendWindow = 100.

// The last block this chain can fetch right now: the head, or endBlock when
// it's below the head.
let fetchCeiling = (cs: t) => {
  let fetchState = cs.fetchState
  switch fetchState.endBlock {
  | Some(endBlock) => Pervasives.min(endBlock, fetchState.knownHeight)
  | None => fetchState.knownHeight
  }
}

// Events/block over the ready part of the buffer — a live signal that reacts
// to what fetching just found, unlike the processing EMA which only moves as
// batches commit.
let readyBufferDensity = (cs: t) => {
  let readyCount = cs.fetchState->FetchState.bufferReadyCount
  let span = cs.fetchState->FetchState.bufferBlockNumber - cs.processingBlockNumber
  if readyCount > 0 && span > 0 {
    Some(readyCount->Int.toFloat /. span->Int.toFloat)
  } else {
    None
  }
}

// Density used for query sizing: the higher of the processing EMA and the
// ready-buffer density, so a stale-low EMA can't undersize queries while the
// buffer proves the range is dense. None means the chain is cold — no density
// signal at all.
let effectiveDensity = (cs: t) =>
  switch (cs.chainDensity, cs->readyBufferDensity) {
  | (Some(ema), Some(buffer)) => Some(Pervasives.max(ema, buffer))
  | (Some(_) as density, None) | (None, Some(_) as density) => density
  | (None, None) => None
  }

// How far past the frontier a chain with no density signal targets while it
// takes its first measurements.
let coldTargetRange = 20_000

// This chain's share of the indexer-wide buffer budget turned into a soft
// target block: via density, or frontier + coldTargetRange when there's no
// density signal yet.
let targetBlock = (cs: t, ~chainTargetItems: float) => {
  let fetchState = cs.fetchState
  let fetchCeiling = cs->fetchCeiling
  let bufferBlockNumber = fetchState->FetchState.bufferBlockNumber
  switch cs->effectiveDensity {
  | Some(density) if density > 0. =>
    Pervasives.min(
      fetchCeiling,
      bufferBlockNumber + Math.ceil(chainTargetItems /. density)->Float.toInt,
    )
  | _ => Pervasives.min(bufferBlockNumber + coldTargetRange, fetchCeiling)
  }
}

// Block range that cross-chain progress alignment maps fractions over: from
// the first block that can hold this chain's events to the last block it will
// fetch.
let progressRange = (cs: t) => {
  let fetchState = cs.fetchState
  let lower = fetchState.firstEventBlock->Option.getOr(fetchState.startBlock)
  let upper = switch fetchState.endBlock {
  | Some(endBlock) => endBlock
  | None => fetchState.knownHeight
  }
  (lower, upper)
}

// A degenerate range (chain already at or past its last block) maps to 1 so it
// never constrains the other chains. Clamped at 0 for the initial -1 fetch
// frontier — the only possible blockNumber below the range's lower bound.
let progressAtBlock = (cs: t, ~blockNumber) => {
  let (lower, upper) = cs->progressRange
  upper <= lower
    ? 1.
    : Pervasives.max(
        0.,
        Pervasives.min(1., (blockNumber - lower)->Int.toFloat /. (upper - lower)->Int.toFloat),
      )
}

let blockAtProgress = (cs: t, ~progress) => {
  let (lower, upper) = cs->progressRange
  lower + Math.ceil(progress *. (upper - lower)->Int.toFloat)->Float.toInt
}

// Propose queries sized against this chain's target block. Called by
// CrossChainState's waterfall, furthest-behind chain first, with
// chainTargetItems set to whatever budget remains at that point and
// maxTargetBlock set to the most-behind chain's progress mapped onto this
// chain, so a chain with budget can't run further ahead than the chain the
// whole pool is prioritizing.
let getNextQuery = (cs: t, ~chainTargetItems: float, ~maxTargetBlock=?) => {
  let chainTargetBlock = cs->targetBlock(~chainTargetItems)
  let chainTargetBlock = switch maxTargetBlock {
  | Some(maxTargetBlock) => Pervasives.min(chainTargetBlock, maxTargetBlock)
  | None => chainTargetBlock
  }
  // When the target block is clamped (head/endBlock/cross-chain alignment) a
  // known-density chain can't use the whole handed budget — cap the fresh part
  // at what the clamped range actually costs (in-flight reservations stay on
  // top: they're already accounted and shouldn't crowd out new partitions), so
  // the waterfall's leftover flows to the next chain in the same tick instead
  // of being held by an oversized probe.
  let chainTargetItems = switch cs->effectiveDensity {
  | Some(density) if density > 0. =>
    let rangeCost =
      density *. (chainTargetBlock - cs.fetchState->FetchState.bufferBlockNumber)->Int.toFloat
    // 3x headroom only for a chain already caught up once and polling the
    // head: there a single query covers the whole remaining range, and a
    // slightly denser-than-expected range would otherwise truncate at the
    // server cap and force an immediate catch-up query for the last blocks.
    // During backfill the range never fits one query anyway, so headroom
    // would just hold budget away from other chains.
    let rangeCost =
      chainTargetBlock >= cs->fetchCeiling && cs->isReady ? rangeCost *. 3. : rangeCost
    Pervasives.min(chainTargetItems, Math.ceil(rangeCost) +. cs.pendingBudget)
  // No density signal: the cross-chain waterfall already clamped the handed
  // budget to the cold-chain cap, so it's used as-is.
  | _ => chainTargetItems
  }
  cs.fetchState->FetchState.getNextQuery(~chainTargetBlock, ~chainTargetItems)
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
    ->FetchState.handleQueryResult(
      ~indexingAddresses=cs.indexingAddresses,
      ~query,
      ~latestFetchedBlock,
      ~newItems,
    )
    ->FetchState.updateKnownHeight(~knownHeight)

  // The query is no longer in flight, so release its reservation.
  cs.pendingBudget = Pervasives.max(0., cs.pendingBudget -. query.itemsTarget->Int.toFloat)
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

    // The batch's items just left the buffer, so the remaining buffer's span
    // starts at the batch's progress.
    cs.processingBlockNumber = chainAfterBatch.progressBlockNumber
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

      // Chain-wide density update: seed with the batch's own events/block on
      // the first update, then blend weighted by the batch's block span — a
      // few sparse/dense blocks barely nudge the estimate, while a
      // window-sized batch replaces it.
      let deltaBlocks = chainAfterBatch.progressBlockNumber - cs.committedProgressBlockNumber
      if deltaBlocks > 0 {
        let deltaEvents = chainAfterBatch.totalEventsProcessed -. cs.numEventsProcessed
        // Don't seed a density before the first event is seen — a progress-only
        // batch would otherwise set it to 0, matching the resume-seed guard.
        switch (cs.chainDensity, deltaEvents > 0.) {
        | (None, false) => ()
        | _ =>
          let batchDensity = deltaEvents /. deltaBlocks->Int.toFloat
          cs.chainDensity = Some(
            switch cs.chainDensity {
            | None => batchDensity
            | Some(oldDensity) =>
              let alpha = Pervasives.min(1., deltaBlocks->Int.toFloat /. densityBlendWindow)
              oldDensity *. (1. -. alpha) +. batchDensity *. alpha
            },
          )
        }
      }

      cs.committedProgressBlockNumber = chainAfterBatch.progressBlockNumber

      // Normally already set by advanceAfterBatch at batch creation; catch up
      // here for paths that commit progress without it.
      cs.processingBlockNumber = Pervasives.max(
        cs.processingBlockNumber,
        chainAfterBatch.progressBlockNumber,
      )
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
    cs.processingBlockNumber = newProgressBlockNumber
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
      cs.processingBlockNumber = Pervasives.min(cs.processingBlockNumber, rollbackTargetBlockNumber)
    }
  }
}
