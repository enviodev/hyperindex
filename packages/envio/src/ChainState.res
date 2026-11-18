// Per-chain runtime state. `t` is mutated in place through the setters below;
// the type is opaque in the interface so callers can read fields but can only
// change them through the sanctioned mutators.

// What a build of `[fromBlock, maxBlock]` for `targetItems` returns: the items
// and the last block they cover.
type builtItems = (array<Internal.item>, option<int>)

type prebuiltItems = {
  fromBlock: int,
  maxBlock: int,
  targetItems: int,
  items: promise<builtItems>,
}

type t = {
  logger: Logger.t,
  mutable fetchState: FetchState.t,
  // The chain's fetched rows, their transactions and blocks, kept in Rust from
  // the merge of a response until the chain removes them: transaction data
  // once a batch commits, blocks once they leave the reorg window.
  chainBuffer: ChainBuffer.t,
  // The chain's registrations, by the index built items carry, which turn an
  // item back into what a handler receives.
  itemContext: StoredItems.context,
  // The chain-wide address index, kept in Rust. Not `mutable`: registration and
  // rollback mutate it in place, so the handle is stable across fetchState
  // versions - and it's the same handle this chain's source clients hold.
  addressStore: AddressStore.t,
  sourceManager: SourceManager.t,
  chainConfig: Config.chain,
  mutable isProgressAtHead: bool,
  mutable timestampCaughtUpToHeadOrEndblock: option<Date.t>,
  mutable committedProgressBlockNumber: int,
  // Where builds read from: the last block a batch has taken. It runs ahead of
  // committedProgressBlockNumber while that batch is processed.
  mutable processingBlockNumber: int,
  mutable numEventsProcessed: float,
  // Running sum of in-flight queries' itemsEst, kept here so the
  // scheduler doesn't re-sum pending queries on every tick. Incremented when
  // queries are dispatched, decremented as their responses land.
  mutable pendingBudget: float,
  // Chain-wide events/block, used to turn a chain's item budget into a target
  // block for query sizing. Seeded from cumulative progress on construction,
  // then smoothed with an EMA on every batch (see applyBatchProgress). None
  // until the chain has processed at least one event.
  mutable chainDensity: option<float>,
  // In-memory tables for the entities whose rows belong to a single chain.
  // Empty in the default cross-chain mode, where every entity's table lives on
  // the indexer instead.
  mutable entities: EntityTables.t,
  mutable safeCheckpointTracking: option<SafeCheckpointTracking.t>,
  // Reorg handling knobs, mirrored from the chain/indexer config: hashes are
  // compared for blocks within `maxReorgDepth` of the known height, and a
  // detected reorg either rolls back or is only logged.
  shouldRollbackOnReorg: bool,
  maxReorgDepth: int,
  // One-way: past it, everything the chain writes can still be rolled back.
  mutable isInReorgThreshold: bool,
  // While a contractRegister run is in flight, the backlog blocks responses
  // have brought registering events for since it started: those go back to
  // the backlog even if the run covered them, since it didn't read the new
  // events.
  mutable contractRegisterRun: option<Utils.Set.t<int>>,
  // Items built ahead for the next batch while the current one runs.
  mutable prebuilt: option<prebuiltItems>,
  // How this chain spells addresses, from `lowercaseAddresses`.
  shouldChecksum: bool,
  reorgThresholdReadyTolerance: int,
  // --- Per-chain metric counters, rendered by Metrics at scrape time.
  // Floats: cumulative counters outgrow int32. ---
  mutable blockRangeFetchSeconds: float,
  mutable parseSeconds: float,
  mutable blockRangeFetchCount: float,
  mutable blockRangeFetchedEvents: float,
  mutable blockRangeFetchedBlocks: float,
  // Whether this chain has said where it finished indexing. Being finished
  // stays true for the rest of the run, and every pass over the chains would
  // say so again.
  mutable reportedFinished: bool,
  mutable reorgCount: int,
  mutable reorgDetectedBlock: option<int>,
  mutable rollbackTargetBlock: option<int>,
  mutable progressLatencyMs: option<int>,
  // Timestamp of the committed progress block itself. See
  // `Batch.chainAfterBatch.progressBlockTime`.
  mutable committedProgressBlockTime: option<int>,
}

// The chain's config-declared addresses as storage rows: what a clean run
// writes into `envio_addresses`. The keys are encoded by the Rust codec, so the
// bytes a clean run writes are exactly the bytes a resume seeds from.
let configStorageRows = (
  chainConfig: Config.chain,
  ~ecosystem: Ecosystem.name,
  ~contractMapping: ContractMapping.t,
): array<AddressRows.row> => {
  let addresses = []
  let contractIds = []
  chainConfig.contracts->Array.forEach(contract => {
    let contractId = contractMapping->ContractMapping.idOfOrThrow(contract.name)
    contract.addresses->Array.forEach(address => {
      addresses->Array.push(address)->ignore
      contractIds->Array.push(contractId)->ignore
    })
  })
  Core.getAddon().encodeAddresses(
    ~ecosystem=(ecosystem :> string),
    ~addresses,
  )->Array.mapWithIndex((address, idx) => {
    AddressRows.chainId: chainConfig.id,
    address,
    contractId: contractIds->Array.getUnsafe(idx),
    registrationBlock: AddressRows.configRegistrationBlock,
  })
}

// Seeds an in-memory address table with every chain's config-declared
// addresses, the twin of what `Storage.initialize` writes in one insert.
let seedConfigAddresses = (
  table: AddressRows.Table.t,
  ~chainConfigs: array<Config.chain>,
  ~ecosystem: Ecosystem.name,
  ~contractMapping: ContractMapping.t,
) =>
  chainConfigs->Array.forEach(chainConfig =>
    table->AddressRows.Table.insertMany(
      chainConfig->configStorageRows(~ecosystem, ~contractMapping),
    )
  )

let validateOnEventRegistrations = (
  ~chainId: ChainId.t,
  registrations: array<Internal.onEventRegistration>,
) =>
  registrations->Array.forEachWithIndex((registration, expectedIndex) => {
    if registration.index !== expectedIndex {
      JsError.throwWithMessage(
        `Invalid onEvent registration index for chain ${chainId->ChainId.toString}: ${registration.eventConfig.contractName}.${registration.eventConfig.name} has index ${registration.index->Int.toString}, but its ChainState position is ${expectedIndex->Int.toString}.`,
      )
    }
  })

let make = (
  ~chainConfig: Config.chain,
  ~fetchState: FetchState.t,
  ~chainBuffer: ChainBuffer.t,
  ~onEventRegistrations=[],
  ~onBlockRegistrations=[],
  ~addressStore: AddressStore.t,
  ~sourceManager: SourceManager.t,
  ~committedProgressBlockNumber: int,
  ~committedProgressBlockTime=None,
  ~safeCheckpointTracking=None,
  ~shouldRollbackOnReorg,
  ~maxReorgDepth,
  ~isInReorgThreshold=false,
  ~numEventsProcessed=0.,
  ~timestampCaughtUpToHeadOrEndblock=None,
  ~isProgressAtHead=false,
  ~chainDensity=None,
  ~shouldChecksum=false,
  ~reorgThresholdReadyTolerance=100,
  ~perChainEntities: array<Internal.entityConfig>=[],
  ~logger: Logger.t,
): t => {
  validateOnEventRegistrations(~chainId=chainConfig.id, onEventRegistrations)
  {
    logger,
    entities: EntityTables.make(perChainEntities),
    fetchState,
    chainBuffer,
    itemContext: {chainId: chainConfig.id, onEventRegistrations, onBlockRegistrations},
    addressStore,
    sourceManager,
    chainConfig,
    isProgressAtHead,
    timestampCaughtUpToHeadOrEndblock,
    committedProgressBlockNumber,
    processingBlockNumber: committedProgressBlockNumber,
    numEventsProcessed,
    pendingBudget: 0.,
    chainDensity,
    safeCheckpointTracking,
    shouldRollbackOnReorg,
    maxReorgDepth,
    isInReorgThreshold,
    contractRegisterRun: None,
    prebuilt: None,
    shouldChecksum,
    reorgThresholdReadyTolerance,
    blockRangeFetchSeconds: 0.,
    parseSeconds: 0.,
    blockRangeFetchCount: 0.,
    blockRangeFetchedEvents: 0.,
    blockRangeFetchedBlocks: 0.,
    reportedFinished: false,
    reorgCount: 0,
    reorgDetectedBlock: None,
    rollbackTargetBlock: None,
    progressLatencyMs: None,
    committedProgressBlockTime,
  }
}

let logFetchStateNotice = (logger, notice: FetchState.notice) =>
  switch notice {
  | SwitchedToClientSideFiltering({contractName, addressCount, threshold}) =>
    logger->Logger.trace(
      "Switching contract to client-side address filtering: registered address count crossed the server-side threshold.",
      ~params={"contractName": contractName, "addressCount": addressCount, "threshold": threshold},
    )
  | SkippedReRegistration({
      contractName,
      contractAddress,
      registeredFromBlock,
      requestedFromBlock,
    }) =>
    logger->Logger.warn(
      "Skipping same-contract re-registration: the address is already registered for this contract. The start block does not move earlier.",
      ~params={
        "contractName": contractName,
        "contractAddress": contractAddress,
        "registeredFromBlock": registeredFromBlock,
        "requestedFromBlock": requestedFromBlock,
      },
    )
  | SkippedInvalidAddress({contractName, contractAddress}) =>
    logger->Logger.warn(
      "Skipping contract registration: Not a valid address for this chain's ecosystem.",
      ~params={"contractName": contractName, "contractAddress": contractAddress},
    )
  | SkippedStoredDuplicate({
      contractName,
      contractAddress,
      registeredFromBlock,
      requestedFromBlock,
    }) =>
    logger->Logger.warn(
      "Skipping a stored address: it is already registered for this contract.",
      ~params={
        "contractName": contractName,
        "contractAddress": contractAddress,
        "registeredFromBlock": registeredFromBlock,
        "requestedFromBlock": requestedFromBlock,
      },
    )
  }

let makeInternal = (
  ~chainConfig: Config.chain,
  ~addressRows: AddressRows.seedRows,
  // Passed rather than read off `config`, because a resume must use the mapping
  // storage holds: the ids stored rows carry, not the ids this config derives.
  ~contractMapping: ContractMapping.t,
  ~startBlock,
  ~endBlock,
  ~firstEventBlock=None,
  ~progressBlockNumber,
  ~committedProgressBlockTime=None,
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
  ~isResumed=false,
  ~sourceTiming=?,
): t => {
  // Handler binding + `where`-derived fetch state, and onBlock registrations,
  // are already collected by `HandlerRegister.finishRegistration`, keyed by
  // chain - this just looks up this chain's slice.
  let {onEventRegistrations, onBlockRegistrations} =
    registrationsByChainId
    ->Utils.Dict.dangerouslyGetNonOption(chainConfig.id->ChainId.toString)
    ->Option.getOr({onEventRegistrations: [], onBlockRegistrations: []})
  // A block handler without `_gte` counts its interval from the chain's start
  // block. Spelled out here because a source matching blocks to handlers needs
  // the origin, and the chain's start block is only resolved by now.
  let onBlockRegistrations = onBlockRegistrations->Array.map(reg => {
    ...reg,
    startBlock: Some(reg.startBlock->Option.getOr(startBlock)),
  })

  chainConfig.contracts->Array.forEach(contract => {
    switch contract.startBlock {
    // Against the resolved `~startBlock`, which came from storage:
    // `chainConfig.startBlock` still says whatever config.yaml said.
    | Some(contractStartBlock) if contractStartBlock < startBlock =>
      JsError.throwWithMessage(
        `The start block for contract "${contract.name}" is less than the chain start block. This is not supported yet.`,
      )
    | _ => ()
    }
  })

  let lowercaseAddresses = config.lowercaseAddresses
  // Created before the fetch state and the sources: `make` registers this
  // chain's addresses into it, and every source client holds the same handle.
  let addressStore = AddressStore.make(
    ~ecosystem=config.ecosystem.name,
    ~contracts=AddressStore.contractsOf(~onEventRegistrations, ~contractMapping),
  )

  let fetchState = FetchState.make(
    ~maxAddrInPartition=config.maxAddrInPartition,
    ~addressStore,
    ~addressRows,
    ~progressBlockNumber,
    ~startBlock,
    ~endBlock,
    ~onEventRegistrations,
    ~knownHeight,
    ~chainId=chainConfig.id,
    ~onNotice=notice => logger->logFetchStateNotice(notice),
    // FIXME: Shouldn't set with full history
    // The resumed depth, not the config one: the pre-threshold lag must match
    // the window reorg detection compares, or a reduced config depth would let
    // fetching enter the stored rollback window without history. One block
    // more than the window, so the last pre-threshold page ends below it and
    // the window's first block is read by a page that knows it is reorgable.
    ~blockLag=Pervasives.max(
      !config.shouldRollbackOnReorg || isInReorgThreshold || maxReorgDepth == 0
        ? 0
        : maxReorgDepth + 1,
      chainConfig.blockLag,
    ),
    ~blockThrottle=chainConfig.blockThrottle,
    ~onBlockRegistrations,
    ~firstEventBlock,
    // Fuel and SVM route through the address store like EVM does, so the
    // client-side path works for them - but their address counts are nowhere
    // near the threshold, so switching would only trade a server-side filter
    // that costs nothing today for an over-fetch. Keep them server-side until a
    // chain actually needs it.
    ~clientFilterAddressThreshold=switch config.ecosystem.name {
    | Evm => Some(config.clientFilterAddressThreshold)
    | Fuel | Svm => None
    },
    ~isResumed,
  )

  let chainReorgCheckpoints = reorgCheckpoints->Array.filterMap(reorgCheckpoint => {
    if reorgCheckpoint.chainId === chainConfig.id {
      Some(reorgCheckpoint)
    } else {
      None
    }
  })

  // Before the sources: the RPC source reads it to fetch only what it lacks.
  let chainBuffer = ChainBuffer.makeForChain(
    ~ecosystem=config.ecosystem.name,
    ~onEventRegistrations,
    ~onBlockRegistrations,
    ~shouldChecksum=!lowercaseAddresses,
    ~addressStore,
  )

  // Create sources lazily here - this is where API token validation happens
  let sources = ChainSources.make(
    ~chainConfig,
    ~onEventRegistrations,
    ~onBlockRegistrations,
    ~addressStore,
    ~lowercaseAddresses,
    ~chainBuffer,
    ~logger,
    ~maxAddressesPerRequest=config.maxAddrInPartition,
  )

  // Seed the stored reorg checkpoints (hash-only rows) so detection resumes
  // against the hashes scanned before the restart.
  if chainReorgCheckpoints->Utils.Array.notEmpty {
    let seedPage = BufferPage.fromBlocks(
      chainReorgCheckpoints->Array.map((cp): BufferPage.observedBlock => {
        blockNumber: cp.blockNumber,
        blockHash: cp.blockHash,
      }),
      ~ecosystem=config.ecosystem.name,
    )
    chainBuffer
    ->ChainBuffer.mergePage(seedPage, ~reorgThreshold=0, ~reportOnly=false)
    ->ignore
  }

  // Seed chain density from whatever progress this chain already has (from a
  // resumed DB state, or 0 on a fresh chain) - refined per-batch afterwards.
  let chainDensity = switch fetchState.firstEventBlock {
  | Some(firstEventBlock) if progressBlockNumber > firstEventBlock && numEventsProcessed > 0. =>
    Some(numEventsProcessed /. (progressBlockNumber - firstEventBlock)->Int.toFloat)
  | _ => None
  }

  make(
    ~chainConfig,
    ~fetchState,
    ~chainBuffer,
    ~onEventRegistrations,
    ~onBlockRegistrations,
    ~addressStore,
    ~sourceManager=SourceManager.make(~sources, ~logger, ~isRealtime, ~timing=?sourceTiming),
    ~shouldRollbackOnReorg=config.shouldRollbackOnReorg,
    ~maxReorgDepth,
    ~isInReorgThreshold,
    ~safeCheckpointTracking=SafeCheckpointTracking.make(
      ~maxReorgDepth,
      ~shouldRollbackOnReorg=config.shouldRollbackOnReorg,
      ~chainReorgCheckpoints,
    ),
    ~committedProgressBlockNumber=progressBlockNumber,
    ~committedProgressBlockTime,
    ~perChainEntities=config.userEntities->EntityTables.perChain,
    ~timestampCaughtUpToHeadOrEndblock,
    ~numEventsProcessed,
    ~chainDensity,
    ~shouldChecksum=!lowercaseAddresses,
    ~reorgThresholdReadyTolerance=config.reorgThresholdReadyTolerance,
    ~logger,
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
  ~contractMapping,
  ~registrationsByChainId,
  // The indexer's root logger; the chain's own adds its id.
  ~logger,
  ~sourceTiming=?,
) => {
  let logger = logger->Logger.withChainId(chainConfig.id)

  let progressBlockNumber =
    // Can be -1 when not set
    resumedChainState.progressBlockNumber >= 0
      ? resumedChainState.progressBlockNumber
      : resumedChainState.startBlock - 1

  makeInternal(
    ~addressRows=resumedChainState.addressRows,
    ~contractMapping,
    ~chainConfig,
    ~startBlock=resumedChainState.startBlock,
    ~endBlock=resumedChainState.endBlock,
    ~config,
    ~registrationsByChainId,
    ~reorgCheckpoints,
    ~maxReorgDepth=resumedChainState.maxReorgDepth,
    ~firstEventBlock=resumedChainState.firstEventBlockNumber,
    ~progressBlockNumber,
    // A block's time never changes, so the stored one stays true for the block
    // progress is at - and keeps the metric reporting from the first scrape
    // after a restart, rather than only once a batch commits.
    ~committedProgressBlockTime=resumedChainState.progressBlockTime,
    ~timestampCaughtUpToHeadOrEndblock=resumedChainState.timestampCaughtUpToHeadOrEndblock,
    ~numEventsProcessed=resumedChainState.numEventsProcessed,
    ~logger,
    ~isInReorgThreshold,
    ~isRealtime,
    ~knownHeight=resumedChainState.sourceBlockNumber,
    ~isResumed=true,
    ~sourceTiming?,
  )
}

// --- Read accessors. ---

let logger = (cs: t) => cs.logger
let chainBuffer = (cs: t) => cs.chainBuffer
let itemContext = (cs: t) => cs.itemContext
let processingBlockNumber = (cs: t) => cs.processingBlockNumber
let fetchStateOf = (cs: t) => cs.fetchState
let shouldChecksum = (cs: t) => cs.shouldChecksum
let entities = (cs: t) => cs.entities

// Rollback discards every uncommitted change, so this chain's partition is
// rebuilt from scratch alongside the indexer's cross-chain one.
let resetEntities = (cs: t, ~perChainEntities) => cs.entities = EntityTables.make(perChainEntities)
let sourceManager = (cs: t) => cs.sourceManager
let chainConfig = (cs: t) => cs.chainConfig
let shouldRollbackOnReorg = (cs: t) => cs.shouldRollbackOnReorg
// Reorg-scan reads over the buffer's blocks, for the rollback flow: the scanned
// block numbers still inside the reorg threshold, and the highest of them whose
// re-fetched hash still matches.
let getReorgThresholdBlockNumbersBelow = (cs: t, ~blockNumber) =>
  (
    cs.chainBuffer->ChainBuffer.getBlockHashes(
      ~fromBlock=Pervasives.max(cs.fetchState.knownHeight - cs.maxReorgDepth, 0),
      ~belowBlock=blockNumber,
    )
  ).blockNumbers

let getLatestValidScannedBlock = (cs: t, ~page: BufferPage.t, ~blockNumbers: array<int>) =>
  cs.chainBuffer
  ->ChainBuffer.findLatestBlockWithMatchingHash(page, blockNumbers)
  ->Null.toOption
let safeCheckpointTracking = (cs: t) => cs.safeCheckpointTracking
let committedProgressBlockNumber = (cs: t) => cs.committedProgressBlockNumber
let committedProgressBlockTime = (cs: t) => cs.committedProgressBlockTime
let numEventsProcessed = (cs: t) => cs.numEventsProcessed
let pendingBudget = (cs: t) => cs.pendingBudget
let timestampCaughtUpToHeadOrEndblock = (cs: t) => cs.timestampCaughtUpToHeadOrEndblock

// --- Metric counters. ---

let recordParse = (cs: t, ~milliseconds) =>
  cs.parseSeconds = cs.parseSeconds +. milliseconds /. 1000.

let recordBlockRangeFetch = (cs: t, ~totalTimeElapsed, ~numEvents, ~blockRangeSize) => {
  cs.blockRangeFetchSeconds = cs.blockRangeFetchSeconds +. totalTimeElapsed
  cs.blockRangeFetchCount = cs.blockRangeFetchCount +. 1.
  cs.blockRangeFetchedEvents = cs.blockRangeFetchedEvents +. numEvents->Int.toFloat
  cs.blockRangeFetchedBlocks = cs.blockRangeFetchedBlocks +. blockRangeSize->Int.toFloat
}

let recordReorgDetected = (cs: t, ~blockNumber) => {
  cs.reorgCount = cs.reorgCount + 1
  cs.reorgDetectedBlock = Some(blockNumber)
}

let setRollbackTargetBlock = (cs: t, ~blockNumber) => cs.rollbackTargetBlock = Some(blockNumber)

// Fetch-frontier reads. The FetchState is owned here; callers go through these
// rather than reaching into it.
let knownHeight = (cs: t) => cs.fetchState.knownHeight
let contractAddresses = (cs: t, ~contractName) =>
  cs.addressStore->AddressStore.contractAddresses(contractName, ~shouldChecksum=cs.shouldChecksum)

// Hands over the dynamically registered addresses the database hasn't seen yet,
// up to the block the caller is about to commit, each paired with the checkpoint
// that registered it. Destructive: the caller must persist them or take the
// indexer down. Throws with nothing consumed when a registration's block has no
// checkpoint in the batch.
let drainAddressesForWrite = (cs: t, ~toBlockInclusive, ~checkpointBlockNumbers) =>
  cs.addressStore->AddressStore.drainForWrite(toBlockInclusive, checkpointBlockNumbers)
let hasAddressesToWrite = (cs: t) => cs.addressStore->AddressStore.pendingCount > 0
let bufferSize = (cs: t) => cs.chainBuffer->ChainBuffer.rowCount
let bufferReadyCount = (cs: t) =>
  cs.fetchState->FetchState.bufferReadyCount(
    ~buffer=cs.chainBuffer,
    ~processingBlockNumber=cs.processingBlockNumber,
  )
let chainDensity = (cs: t) => cs.chainDensity
let hasReadyItem = (cs: t) =>
  cs.fetchState->FetchState.isActivelyIndexing(
    ~buffer=cs.chainBuffer,
    ~processingBlockNumber=cs.processingBlockNumber,
  ) &&
    cs.fetchState->FetchState.hasReadyItem(
      ~buffer=cs.chainBuffer,
      ~processingBlockNumber=cs.processingBlockNumber,
    )

// Mark queries as in flight and reserve their estimated size against the shared
// buffer budget in one step, so the counter stays in sync with the pending
// queries it tracks.
let startFetchingQueries = (cs: t, ~queries: array<FetchState.query>) => {
  cs.fetchState->FetchState.startFetchingQueries(~queries)
  cs.pendingBudget =
    cs.pendingBudget +.
    queries->Array.reduce(0., (acc, query) => acc +. query.itemsEst->Int.toFloat)
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

// The last block this chain can fetch right now: the lagged head
// (knownHeight - blockLag, the frontier when a reorg-threshold blockLag holds
// back the tip), or endBlock when it's below that head. Matching isFetchingAtHead's
// definition of the head is what lets a chain parked at its lagged head read
// 100% progress instead of looking behind against blocks it can't fetch.
let fetchCeiling = (cs: t) => {
  let fetchState = cs.fetchState
  let head = Pervasives.max(0, fetchState.knownHeight - fetchState.blockLag)
  switch fetchState.endBlock {
  | Some(endBlock) => Pervasives.min(endBlock, head)
  | None => head
  }
}

// Events/block over the ready part of the buffer - a live signal that reacts
// to what fetching just found, unlike the processing EMA which only moves as
// batches commit.
let readyBufferDensity = (cs: t) => {
  let readyCount = cs->bufferReadyCount
  let span = cs.fetchState->FetchState.bufferBlockNumber - cs.processingBlockNumber
  if readyCount > 0 && span > 0 {
    Some(readyCount->Int.toFloat /. span->Int.toFloat)
  } else {
    None
  }
}

// Density used for query sizing: the higher of the processing EMA and the
// ready-buffer density, so a stale-low EMA can't undersize queries while the
// buffer proves the range is dense. None means the chain is cold - no density
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
    // Decided by comparison so no unbounded value is ever converted to int:
    // at low densities chainTargetItems /. density exceeds the int range, and
    // truncating it wraps negative - the target collapses below the frontier
    // and the chain stops querying. The division only runs when its result is
    // provably below the ceiling-bounded range.
    if density *. (fetchCeiling - bufferBlockNumber)->Int.toFloat <= chainTargetItems {
      fetchCeiling
    } else {
      bufferBlockNumber + Math.ceil(chainTargetItems /. density)->Float.toInt
    }
  | _ => Pervasives.min(bufferBlockNumber + coldTargetRange, fetchCeiling)
  }
}

// Block range that cross-chain progress alignment maps fractions over: from
// the chain's startBlock to the last block it can fetch right now. The lower
// bound is deliberately static - anchoring it at firstEventBlock would make
// two chains sitting at the same block read different progress fractions
// depending on whether each has discovered its first event yet, so the
// anchor's line could map below a follower's own frontier and stall it.
let progressRange = (cs: t) => {
  let fetchState = cs.fetchState
  (fetchState.startBlock, cs->fetchCeiling)
}

// A degenerate range (chain already at or past its last block) maps to 1 so it
// never constrains the other chains. Clamped at 0 for the initial -1 fetch
// frontier - the only possible blockNumber below the range's lower bound.
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

// The fetch frontier as a fraction of the alignable range - what the
// cross-chain waterfall aligns other chains against. Based on blocks actually
// fetched, so it holds up even while this chain's queries are in flight.
let frontierProgress = (cs: t) =>
  cs->progressAtBlock(~blockNumber=cs.fetchState->FetchState.bufferBlockNumber)

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
  // known-density chain can't use the whole handed budget - cap the fresh part
  // at what the clamped range actually costs (in-flight reservations stay on
  // top: they're already accounted and shouldn't crowd out new partitions), so
  // the waterfall's leftover flows to the next chain in the same tick instead
  // of being held by an oversized probe.
  let chainTargetItems = switch cs->effectiveDensity {
  | Some(density) if density > 0. =>
    let rangeCost =
      density *. (chainTargetBlock - cs.fetchState->FetchState.bufferBlockNumber)->Int.toFloat
    Pervasives.min(chainTargetItems, Math.ceil(rangeCost) +. cs.pendingBudget)
  // No density signal: the cross-chain waterfall already clamped the handed
  // budget to the cold-chain cap, so it's used as-is.
  | _ => chainTargetItems
  }
  cs.fetchState->FetchState.getNextQuery(
    ~processingBlockNumber=cs.processingBlockNumber,
    ~chainTargetBlock,
    ~chainTargetItems,
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

// Caught up as judged by persisted values alone: progress reached the endBlock,
// or the head the previous run had already observed (less the lag that holds the
// tip back). Unlike `isFetchingAtHead` this doesn't move when a fresh height
// lands, so a run resumed at the head still knows it was caught up even once the
// head has run away from it while the indexer was down.
let isDurablyCaughtUp = (cs: t) => {
  let {committedProgressBlockNumber, fetchState} = cs
  let atEndBlock =
    fetchState.endBlock->Option.mapOr(false, endBlock => committedProgressBlockNumber >= endBlock)
  // Either one, like `isFetchingAtHead`: an `end_block` above the head is never
  // reached, and testing only for it would leave such a chain reading as behind
  // however long it sits at the head.
  //
  // The configured lag, not the fetch state's: pre-threshold that one also
  // carries maxReorgDepth, which would read a chain a whole reorg depth behind
  // the head as caught up. Clamped at zero: the -1 a run that has processed
  // nothing carries would otherwise clear a chain younger than its own lag.
  let atHead =
    fetchState.knownHeight > 0 &&
      committedProgressBlockNumber >=
      Pervasives.max(0, fetchState.knownHeight - cs.chainConfig.blockLag)
  atEndBlock || atHead
}

// This chain has indexed everything there was to index: it reached its end
// block, or its progress reached the head. The single reading of that, for
// everything that turns on it — what the chain reports, and whether the whole
// process may finalize.
//
// Both spellings, because neither covers the other: `isProgressAtHead` latches
// the moment a batch's progress met the head known when it was created, which a
// head that has since moved on would read as behind; `isDurablyCaughtUp` judges
// the head as it stands, which is all a run resumed at the head has — it has no
// batch to latch anything.
let hasCaughtUp = (cs: t) => cs.isProgressAtHead || cs->isDurablyCaughtUp

// Where this chain has finished indexing, the first time it gets there.
// `EndBlock` is terminal: the chain indexed everything it was configured to.
// `Backfill` is the rest of the history, up to the point where blocks can
// still be reorged, which is as far as a chain indexes before the indexer
// crosses into them.
type finished = EndBlock(int) | Backfill(int)

let takeFinished = (cs: t) =>
  if cs.reportedFinished {
    None
  } else {
    switch (cs.fetchState.endBlock, cs->hasProcessedToEndblock, cs->hasCaughtUp) {
    | (Some(endBlock), true, _) => {
        cs.reportedFinished = true
        Some(EndBlock(endBlock))
      }
    | (_, _, true) => {
        cs.reportedFinished = true
        // Finishing a backfill happens in a run, and a chain resumed with its
        // `ready_at` already committed did none in this one. Being at the end
        // block, above, stays true across runs and is said on every one.
        cs->isReady ? None : Some(Backfill(cs.committedProgressBlockNumber))
      }
    | _ => None
    }
  }

// The block reorg detection compares from is itself in the window, so the
// highest block below it is the one before, where catch-up stops.
let getHighestBlockBelowThreshold = (cs: t): int =>
  Pervasives.max(cs.fetchState.knownHeight - cs.maxReorgDepth - 1, 0)

// True once the fetch frontier has reached the head/endBlock for this chain.
let isFetchingAtHead = (cs: t) => cs.fetchState->FetchState.isFetchingAtHead

// Reached head on a chain with no configured endBlock - used by auto-exit to
// detect that no events were found in the start..head range.
let isAtHeadWithoutEndBlock = (cs: t) =>
  cs.isProgressAtHead && cs.fetchState.endBlock->Option.isNone

// --- State transitions. The chain state is mutated only through these; each
// owns a cohesive update so callers don't juggle individual fields. ---

// Near the head: each new block in as few queries as possible, of a shape that
// stays the same while contracts keep being registered. Once every partition is
// close enough, the chain's dynamic contracts leave the server-side address
// filter for the rest of the run.
//
// Judged only when the chain learns a newer head. An RPC response repeats the
// height its query went out with, which can be hours old by the end of a
// backfill: judged against it, every block produced since would be fetched
// address-free.
let switchDynamicContractsToClientSideFilteringNearHead = (cs: t) =>
  if (
    !cs.fetchState.clientFilterPolicy.allDynamicContracts &&
    cs.fetchState->FetchState.isWithinHeadClientFilteringDistance
  ) {
    cs.fetchState =
      cs.fetchState->FetchState.switchDynamicContractsToClientSideFiltering(
        ~addressStore=cs.addressStore,
      )
    if (
      cs.itemContext.onEventRegistrations->Array.some(registration =>
        registration.contractRegister !== None
      )
    ) {
      cs.logger->Logger.trace(
        "Near the head: dynamic contracts are fetched without their addresses for the rest of the run, and filtered on our side.",
        ~params={
          "contractNames": cs.fetchState.optimizedPartitions.dynamicContracts->Utils.Set.toArray,
        },
      )
    }
  }

let handleQueryResult = (
  cs: t,
  ~query: FetchState.query,
  ~itemsCount,
  ~registeringBlockNumbers,
  ~latestFetchedBlock: int,
  ~knownHeight,
) => {
  switch cs.contractRegisterRun {
  | Some(readded) =>
    registeringBlockNumbers->Array.forEach(block => readded->Utils.Set.add(block)->ignore)
  | None => ()
  }
  let previousKnownHeight = cs.fetchState.knownHeight
  // A source returns the blocks of the handlers its query selects, not their
  // runs, so the runs are counted here: the density the next queries are
  // priced by includes them.
  let blockHandlerRuns = switch query.selection.onBlockRegistrations {
  | [] => 0
  | onBlockRegistrations =>
    cs.chainBuffer
    ->ChainBuffer.countBlockHandlerRunsInBlockRange(
      ~fromBlock=query.fromBlock,
      ~toBlock=latestFetchedBlock,
      ~registrationIndexes=onBlockRegistrations->Array.map(registration => registration.index),
    )
    ->Float.toInt
  }
  cs.fetchState =
    cs.fetchState
    ->FetchState.handleQueryResult(
      ~query,
      ~latestFetchedBlock,
      ~itemsCount=itemsCount + blockHandlerRuns,
      ~registeringBlockNumbers,
    )
    ->FetchState.updateKnownHeight(~knownHeight)

  // The query is no longer in flight, so release its reservation.
  cs.pendingBudget = Pervasives.max(0., cs.pendingBudget -. query.itemsEst->Int.toFloat)
  if cs.fetchState.knownHeight > previousKnownHeight {
    cs->switchDynamicContractsToClientSideFilteringNearHead
  }
}

let hasContractRegisterBacklog = (cs: t) =>
  cs.fetchState.contractRegisterBacklog->Utils.Array.notEmpty
let isRegisteringContracts = (cs: t) => cs.contractRegisterRun !== None

// Starts a contractRegister run, returning the backlog it reads.
let beginContractRegisterRun = (cs: t) => {
  cs.contractRegisterRun = Some(Utils.Set.make())
  cs.fetchState.contractRegisterBacklog->Array.copy
}

let endContractRegisterRun = (cs: t) => cs.contractRegisterRun = None

// Registers what a contractRegister run added, and takes the backlog blocks it
// covered out of the backlog. A run comes out of no response, so a query can
// claim no further than the chain has fetched or knows of.
let registerContracts = (
  cs: t,
  ~registrations: array<AddressStore.registration>,
  ~builtBlockNumbers: array<int>,
) => {
  let fetchState = switch registrations {
  | [] => cs.fetchState
  | _ =>
    cs.fetchState->FetchState.registerDynamicContracts(
      ~addressStore=cs.addressStore,
      ~onNotice=notice => cs.logger->logFetchStateNotice(notice),
      ~claimCeiling=Pervasives.max(
        cs.fetchState.knownHeight,
        cs.fetchState->FetchState.highestFetchedBlock,
      ),
      registrations,
    )
  }
  let readded = cs.contractRegisterRun->Option.getOr(Utils.Set.make())
  cs.fetchState =
    fetchState->FetchState.popContractRegisterBacklog(
      ~blocks=builtBlockNumbers->Array.filter(block => !(readded->Utils.Set.has(block))),
    )
  cs.logger->Logger.trace(
    "Registered contracts",
    ~params={
      "registrations": registrations->Array.length,
      "partitions": cs.fetchState->FetchState.partitionsCount,
      "backlog": cs.fetchState.contractRegisterBacklog,
      "addresses": cs.addressStore->AddressStore.size,
    },
  )
}

// The response's page joins the buffer, its block hashes checked against the
// stored ones on the way: those of blocks inside the reorg threshold are
// compared. On a mismatch with rollback enabled nothing of the page merges (the
// stored hashes stay for the rollback comparison); in detect-only mode the page
// still merges, so the overwritten hash doesn't re-report on every response.
let mergePage = (cs: t, ~page, ~knownHeight) => {
  let merged =
    cs.chainBuffer->ChainBuffer.mergePage(
      page,
      ~reorgThreshold=Pervasives.max(knownHeight - cs.maxReorgDepth, 0),
      ~reportOnly=!cs.shouldRollbackOnReorg,
    )
  let reorgResult: ReorgDetection.reorgResult = switch merged.mismatch {
  | None => NoReorg
  | Some({blockNumber, storedHash, receivedHash}) =>
    ReorgDetected({
      scannedBlock: {blockNumber, blockHash: storedHash},
      receivedBlock: {blockNumber, blockHash: receivedHash},
    })
  }
  (reorgResult, merged)
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

// A chain waiting at its head goes address-free before querying the new block.
let updateKnownHeight = (cs: t, ~knownHeight) => {
  cs.fetchState = cs.fetchState->FetchState.updateKnownHeight(~knownHeight)
  cs->switchDynamicContractsToClientSideFilteringNearHead
}

// In auto-exit mode, pin the endBlock to the earliest observed event block.
let setEndBlockToFirstEvent = (cs: t, ~blockNumber) =>
  switch cs.fetchState.endBlock {
  | None => cs.fetchState = {...cs.fetchState, endBlock: Some(blockNumber)}
  | Some(currentEndBlock) if blockNumber < currentEndBlock =>
    cs.fetchState = {...cs.fetchState, endBlock: Some(blockNumber)}
  | Some(_) => ()
  }

// Shrink the fetch buffer by the configured blockLag on entering the reorg threshold.
let enterReorgThreshold = (cs: t) => {
  cs.isInReorgThreshold = true
  cs.fetchState = cs.fetchState->FetchState.updateInternal(~blockLag=cs.chainConfig.blockLag)
}

let isInReorgThreshold = (cs: t) => cs.isInReorgThreshold

// The first block a query can find still reorgable, the same window reorg
// detection compares. Before the threshold, fetching stops below it; a chain
// that never rolls back never enters the threshold, so realtime opens it too,
// where reorgs are still detected and reported.
let reorgableFrom = (cs: t, ~isRealtime) =>
  if cs.isInReorgThreshold || isRealtime {
    Some(Pervasives.max(cs.fetchState.knownHeight - cs.maxReorgDepth, 0))
  } else {
    None
  }

// Whether the chain's writes need history: only what a rollback could still
// reach. A chain with no reorg depth is never rolled back, however far its
// progress has run.
let shouldSaveHistory = (cs: t) =>
  cs.shouldRollbackOnReorg && cs.maxReorgDepth > 0 && cs.isInReorgThreshold
// What crossing into the recent blocks changed for this chain. Until now it
// stopped short of the head by its reorg depth, because it kept nothing it
// could roll back with; crossing lifts both at once. The second half is the
// answer to why the indexer starts writing more than it was.
// Whether crossing gives this chain anything more to index: the last block it
// may fetch afterwards against the last it may fetch now. Read before the
// crossing, while the lag being lifted is still the one in place.
//
// False wherever the lag was never holding this chain back, which is every
// configuration that also keeps no history: a chain that isn't rolled back on a
// reorg, or has no reorg depth, already fetches as far as it ever will. It is
// false too for a chain whose end block sits below the blocks being opened up,
// which will never reach one of them.
let reorgThresholdLiftsCeiling = (cs: t) => {
  let ceiling = (~blockLag) => {
    let head = Pervasives.max(0, cs.fetchState.knownHeight - blockLag)
    switch cs.fetchState.endBlock {
    | Some(endBlock) => Pervasives.min(endBlock, head)
    | None => head
    }
  }
  ceiling(~blockLag=cs.chainConfig.blockLag) > ceiling(~blockLag=cs.fetchState.blockLag)
}

// Only ever said by a chain the crossing lifts, and lifting it takes a reorg
// depth to have been held back by, which is the same thing that makes the
// history below worth keeping. So there is no second form without it.
let reorgThresholdEntryMessage = "Indexing the latest blocks now. These can be reorged, so the indexer starts storing a history of every change to roll back with."

// Snapshot the chain's metadata fields for staging into the chains table.
let toChainMetadata = (cs: t): InternalTable.Chains.metaFields => {
  firstEventBlockNumber: cs.fetchState.firstEventBlock->Null.fromOption,
  isHyperSync: (cs.sourceManager->SourceManager.getActiveSource).poweredByHyperSync,
  latestFetchedBlockNumber: cs.fetchState->FetchState.bufferBlockNumber,
  timestampCaughtUpToHeadOrEndblock: cs.timestampCaughtUpToHeadOrEndblock->Null.fromOption,
}

let toMetrics = (cs: t): Metrics.chainMetrics => {
  chainId: cs.chainConfig.id,
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
  numAddresses: cs.addressStore->AddressStore.size,
  addressesByContract: cs.addressStore
  ->AddressStore.contractCounts
  ->Array.map(({contractName, count}) => (contractName, count)),
  isReady: cs->isReady,
  sourceBlockNumber: cs.fetchState.knownHeight,
  progressBlockNumber: cs.committedProgressBlockNumber,
  progressLatencyMs: cs.progressLatencyMs,
  progressBlockTime: cs.committedProgressBlockTime,
  concurrency: cs.sourceManager->SourceManager.inFlightCount,
  partitionsCount: cs.fetchState->FetchState.partitionsCount,
  bufferSize: cs->bufferSize,
  bufferBlockNumber: cs.fetchState->FetchState.bufferBlockNumber,
  idleSeconds: cs.sourceManager->SourceManager.idleSeconds,
  waitingForNewBlockSeconds: cs.sourceManager->SourceManager.waitingForNewBlockSeconds,
  queryingSeconds: cs.sourceManager->SourceManager.queryingSeconds,
  blockRangeFetchSeconds: cs.blockRangeFetchSeconds,
  parseSeconds: cs.parseSeconds,
  blockRangeFetchCount: cs.blockRangeFetchCount,
  blockRangeFetchedEvents: cs.blockRangeFetchedEvents,
  blockRangeFetchedBlocks: cs.blockRangeFetchedBlocks,
  reorgCount: cs.reorgCount,
  reorgDetectedBlock: cs.reorgDetectedBlock,
  rollbackTargetBlock: cs.rollbackTargetBlock,
  rateLimitTimeMs: cs.sourceManager->SourceManager.getRateLimitTimeMs,
  rateLimitResetInMs: cs.sourceManager->SourceManager.getRateLimitResetInMs,
}

// Snapshot the inputs a batch build needs from this chain. The scanned
// in-threshold block hashes are copied up front because the build reuses the
// whole set; the block time comes as a lookup instead, since the key it needs -
// the batch's own progress block - isn't known until the build computes it.
let buildItemsNow = (cs: t, ~fromBlock, ~maxBlock, ~targetItems): promise<builtItems> =>
  cs.chainBuffer
  ->ChainBuffer.buildHandlerItems(~fromBlock, ~maxBlock, ~targetItems)
  ->Promise.thenResolve(built => (
    built->StoredItems.read(~context=cs.itemContext),
    built.lastBlock,
  ))

// The items built ahead when they answer this build: the same start and
// target, read no further than `maxBlock`. Fewer blocks than the range allows
// still make a whole batch, which ends where its items end.
let buildItems = (cs: t, ~fromBlock, ~maxBlock, ~targetItems): promise<builtItems> => {
  let prebuilt = cs.prebuilt
  cs.prebuilt = None
  switch prebuilt {
  | Some(prebuilt)
    if prebuilt.fromBlock === fromBlock &&
    prebuilt.maxBlock <= maxBlock &&
    prebuilt.targetItems === targetItems =>
    prebuilt.items
  | _ => cs->buildItemsNow(~fromBlock, ~maxBlock, ~targetItems)
  }
}

// Starts building the next batch's items from the read position, for
// `buildItems` to take up.
let prebuildItems = (cs: t, ~targetItems) => {
  let fromBlock = cs.processingBlockNumber + 1
  let maxBlock = cs.fetchState->FetchState.bufferBlockNumber
  cs.prebuilt = if (
    maxBlock >= fromBlock &&
      cs.chainBuffer->ChainBuffer.countItemsInBlockRange(~fromBlock, ~toBlock=maxBlock) > 0
  ) {
    let items = cs->buildItemsNow(~fromBlock, ~maxBlock, ~targetItems)
    // A build nobody takes up must not surface as an unhandled rejection; one
    // that is taken up rejects for its taker.
    items->Promise.catch(_ => Promise.resolve(([], None)))->ignore
    Some({fromBlock, maxBlock, targetItems, items})
  } else {
    None
  }
}

let toChainBeforeBatch = (cs: t, ~isRealtime): Batch.chainBeforeBatch => {
  let {blockNumbers, hashes} =
    cs.chainBuffer->ChainBuffer.getBlockHashes(
      ~fromBlock=Pervasives.max(cs.fetchState.knownHeight - cs.maxReorgDepth, 0),
      ~belowBlock=cs.fetchState.knownHeight + 1,
    )
  let hashByBlockNumber = Dict.make()
  blockNumbers->Array.forEachWithIndex((blockNumber, idx) =>
    hashByBlockNumber->Utils.Dict.setByInt(blockNumber, hashes->Array.getUnsafe(idx))
  )
  {
    fetchState: cs.fetchState,
    buffer: cs.chainBuffer,
    buildItems: (~fromBlock, ~maxBlock, ~targetItems) =>
      cs->buildItems(~fromBlock, ~maxBlock, ~targetItems),
    recordParse: milliseconds => cs->recordParse(~milliseconds),
    progressBlockNumber: cs.processingBlockNumber,
    totalEventsProcessed: cs.numEventsProcessed,
    sourceBlockNumber: cs.fetchState.knownHeight,
    scannedHashes: {blockNumbers, hashByBlockNumber},
    // A slot that produced no block only counts as skipped where the query
    // covered every slot in its range, which is what a chain at the head asks
    // for.
    blockTimeAt: blockNumber =>
      cs.chainBuffer
      ->ChainBuffer.getBlockTimestamp(blockNumber, ~allowSkippedSlot=isRealtime)
      ->Null.toOption,
    shouldRollbackOnReorg: cs.shouldRollbackOnReorg,
    chainConfig: cs.chainConfig,
  }
}

// Whether the chain's post-batch fetch frontier is ready to cross into the reorg
// threshold, using the batch's progressed frontier when this chain advanced.
// The same question asked of where the chain stands now rather than of where a
// batch would leave it. Entering the threshold is what lifts the pre-threshold
// lag, so a chain waiting to enter it has fetched as far as it can.
let isReadyToEnterReorgThreshold = (cs: t) =>
  cs.fetchState->FetchState.isReadyToEnterReorgThreshold(
    ~buffer=cs.chainBuffer,
    ~processingBlockNumber=cs.processingBlockNumber,
    ~tolerance=cs.reorgThresholdReadyTolerance,
  )

let isReadyToEnterReorgThresholdAfterBatch = (cs: t, ~batch: Batch.t) =>
  cs.fetchState->FetchState.isReadyToEnterReorgThreshold(
    ~buffer=cs.chainBuffer,
    ~processingBlockNumber=switch batch.progressedChainsById->ChainId.Dict.dangerouslyGetNonOption(
      cs.fetchState.chainId,
    ) {
    | Some(chainAfterBatch) => chainAfterBatch.progressBlockNumber
    | None => cs.processingBlockNumber
    },
    ~tolerance=cs.reorgThresholdReadyTolerance,
  )

// Moves the read position past the batch's items, and applies blockLag when
// this batch also crosses into the reorg threshold.
let advanceAfterBatch = (cs: t, ~batch: Batch.t, ~enteringReorgThreshold) => {
  if enteringReorgThreshold {
    cs.fetchState = cs.fetchState->FetchState.updateInternal(~blockLag=cs.chainConfig.blockLag)
  }
  switch batch.progressedChainsById->ChainId.Dict.dangerouslyGetNonOption(cs.fetchState.chainId) {
  | Some(chainAfterBatch) => cs.processingBlockNumber = chainAfterBatch.progressBlockNumber
  | None => ()
  }
}

// Commit a processed batch's progress for this chain (progress block, events
// processed, head/safe-checkpoint tracking, first event block). Readiness is
// decided by CrossChainState once every chain is caught up (see markReady).
// `blockTimestampName` is the ecosystem's block-timestamp field, read off the
// payload block for the latency metric.
let applyBatchProgress = (cs: t, ~batch: Batch.t, ~blockTimestampName: string) => {
  let chainId = cs.chainConfig.id

  switch batch.progressedChainsById->ChainId.Dict.dangerouslyGetNonOption(chainId) {
  | Some(chainAfterBatch) => {
      // Calculate and set latency metrics. The payload block is materialised or
      // inline by processing time; its timestamp may still be absent (e.g. an
      // SVM slot with no block row) - the metric is skipped then.
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
        cs.progressLatencyMs = Some(Date.now()->Float.toInt - blockTimestampMs)
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
      // the first update, then blend weighted by the batch's block span - a
      // few sparse/dense blocks barely nudge the estimate, while a
      // window-sized batch replaces it.
      let deltaBlocks = chainAfterBatch.progressBlockNumber - cs.committedProgressBlockNumber
      if deltaBlocks > 0 {
        let deltaEvents = chainAfterBatch.totalEventsProcessed -. cs.numEventsProcessed
        // Don't seed a density before the first event is seen - a progress-only
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
      cs.committedProgressBlockTime = chainAfterBatch.progressBlockTime

      // Normally already set by advanceAfterBatch at batch creation; catch up
      // here for paths that commit progress without it.
      cs.processingBlockNumber = Pervasives.max(
        cs.processingBlockNumber,
        chainAfterBatch.progressBlockNumber,
      )
      cs.numEventsProcessed = chainAfterBatch.totalEventsProcessed
      // Processed blocks' rows are no longer needed. Their blocks stay while
      // inside the reorg window, whose hashes reorg detection compares.
      cs.chainBuffer
      ->ChainBuffer.removeTransactionDataInBlockRange(
        ~fromBlock=0,
        ~toBlock=chainAfterBatch.progressBlockNumber,
      )
      ->ignore
      cs.chainBuffer
      ->ChainBuffer.removeBlocksInBlockRange(
        ~fromBlock=0,
        ~toBlock=Pervasives.min(
          chainAfterBatch.progressBlockNumber,
          cs.fetchState.knownHeight - cs.maxReorgDepth - 1,
        ),
      )
      ->ignore
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
// every chain this process drives is caught up and the indexes the schema
// promises them are committed, so no chain flips to ready while an index it
// promised is still missing. `readyAt` is the timestamp already committed to
// `envio_chains.ready_at` in that same transaction. Sticky: a chain stays ready
// once set.
let markReady = (cs: t, ~readyAt) =>
  if !(cs->isReady) {
    cs.timestampCaughtUpToHeadOrEndblock = Some(readyAt)
  }

// Rewind progress to a reorg target. Moving it means the timestamp now belongs
// to an orphaned block, so it's re-read for the block progress actually lands
// on - normally `None`, since the store keeps only hashes below the last
// committed progress, until the re-fetch commits a new progress block. A target
// at or above the progress block leaves both alone: that block was never
// orphaned, and re-reading its long-pruned header would drop a valid timestamp.
let rollbackCommittedProgress = (cs: t, blockNumber) =>
  if blockNumber !== cs.committedProgressBlockNumber {
    cs.committedProgressBlockNumber = blockNumber

    // Exact block only: the rolled-back region is about to be refetched, and
    // the next batch re-establishes the time either way.
    cs.committedProgressBlockTime =
      cs.chainBuffer
      ->ChainBuffer.getBlockTimestamp(blockNumber, ~allowSkippedSlot=false)
      ->Null.toOption
  }

type progressDiff = {blockNumber: int, eventsProcessed: float}

type rolledBackTo =
  | RecomputedProgress(progressDiff)
  | ForkBlock(int)
  | Untouched

// Returns the address registrations the storage has to delete along with the
// chain — the store is what decides which ones died, so the two halves of a
// rollback can't disagree.
let rollback = (cs: t, ~rolledBackTo: rolledBackTo): array<AddressRows.key> => {
  cs.prebuilt = None
  let rollbackTo = targetBlockNumber => {
    let {fetchState, rolledBackAddresses} =
      cs.fetchState->FetchState.rollback(
        ~rolledBackAddressStore=cs.addressStore,
        ~targetBlockNumber,
      )
    cs.fetchState = fetchState
    // Everything above the target is refetched. Keeping any block hash of it
    // would compare the refetch against a fork the rollback already disproved.
    cs.chainBuffer
    ->ChainBuffer.removeTransactionDataInBlockRange(
      ~fromBlock=targetBlockNumber + 1,
      ~toBlock=Int.Constants.maxValue,
    )
    ->ignore
    cs.chainBuffer
    ->ChainBuffer.removeBlocksInBlockRange(
      ~fromBlock=targetBlockNumber + 1,
      ~toBlock=Int.Constants.maxValue,
    )
    ->ignore
    rolledBackAddresses->Array.map(({address, contractId}): AddressRows.key => {
      chainId: cs.chainConfig.id,
      address,
      contractId,
    })
  }

  switch rolledBackTo {
  | RecomputedProgress({blockNumber, eventsProcessed}) =>
    // A rollback only ever takes a chain back. The diff recomputes progress from
    // the checkpoints still in the database, so a chain that an unwritten
    // rollback already took below them — to a fork block only that rollback
    // knew — would be handed their MIN back and moved forward onto blocks it
    // never re-indexed.
    let newProgressBlockNumber = Pervasives.min(blockNumber, cs.committedProgressBlockNumber)
    let newTotalEventsProcessed = cs.numEventsProcessed -. eventsProcessed

    switch cs.safeCheckpointTracking {
    | Some(safeCheckpointTracking) =>
      cs.safeCheckpointTracking = Some(
        safeCheckpointTracking->SafeCheckpointTracking.rollback(
          ~targetBlockNumber=newProgressBlockNumber,
        ),
      )
    | None => ()
    }
    let rolledBackAddresses = rollbackTo(newProgressBlockNumber)
    cs->rollbackCommittedProgress(newProgressBlockNumber)
    cs.processingBlockNumber = newProgressBlockNumber
    cs.numEventsProcessed = newTotalEventsProcessed
    rolledBackAddresses
  | ForkBlock(forkBlock) =>
    // Rewinds the stores too, not just progress: otherwise the stale block hash
    // survives and re-triggers the same reorg.
    let rolledBackAddresses = rollbackTo(forkBlock)
    cs->rollbackCommittedProgress(Pervasives.min(cs.committedProgressBlockNumber, forkBlock))
    cs.processingBlockNumber = Pervasives.min(cs.processingBlockNumber, forkBlock)
    rolledBackAddresses
  | Untouched => []
  }
}
