type indexingAddress = Internal.indexingContract

type blockNumberAndTimestamp = {
  blockNumber: int,
  blockTimestamp: int,
}

type blockNumberAndLogIndex = {blockNumber: int, logIndex: int}

type selection = {
  onEventRegistrations: array<Internal.onEventRegistration>,
  dependsOnAddresses: bool,
}

type pendingQuery = {
  fromBlock: int,
  toBlock: option<int>,
  isChunk: bool,
  // Items this in-flight query is targeting (server maxNumLogs-style cap), carried
  // from the query so the shared buffer budget can account for what's already
  // being fetched.
  itemsTarget: int,
  // Stores latestFetchedBlock when query completes. Only needed to persist
  // timestamp while earlier queries are still pending before updating
  // the partition's latestFetchedBlock.
  mutable fetchedBlock: option<blockNumberAndTimestamp>,
}

/**
A state that holds a queue of events and data regarding what to fetch next
for specific contract events with a given contract address.
When partitions for the same events are caught up to each other
the are getting merged until the maxAddrInPartition is reached.
*/
type partition = {
  id: string,
  // The block number of the latest fetched query
  // which added all its events to the queue
  latestFetchedBlock: blockNumberAndTimestamp,
  selection: selection,
  addressesByContractName: dict<array<Address.t>>,
  mergeBlock: option<int>,
  // When set, partition indexes a single dynamic contract type.
  // The addressesByContractName must contain only addresses for this contract.
  dynamicContract: option<string>,
  // Mutable array for SourceManager sync - queries exist only while being fetched
  mutPendingQueries: array<pendingQuery>,
  // Track last 3 successful query ranges for chunking heuristic (0 means no data)
  prevQueryRange: int,
  prevPrevQueryRange: int,
  // Item count of the response that set prevQueryRange. Paired with it to derive
  // the partition's event density (prevRangeSize / prevQueryRange) for sizing
  // queries against the buffer budget.
  prevRangeSize: int,
  // Tracks the latestFetchedBlock.blockNumber of the most recent response
  // that updated prevQueryRange. Prevents degradation of the chunking heuristic
  // when parallel query responses arrive out of order.
  latestBlockRangeUpdateBlock: int,
}

type query = {
  partitionId: string,
  fromBlock: int,
  toBlock: option<int>,
  isChunk: bool,
  // Items this query targets: the server-side maxNumLogs-style cap, and the
  // unit the chain's per-tick budget is reserved/consumed in. For a partition
  // with known density this is density × the query's block range; for a
  // partition with no signal yet it's whatever budget share the query was
  // sized against.
  itemsTarget: int,
  selection: selection,
  addressesByContractName: dict<array<Address.t>>,
}

// Invert addressesByContractName into address→contractName for log-ownership
// routing. 1:1 today (each address belongs to one contract), so no key
// collisions. Memoized on the addressesByContractName object so a partition's
// many responses share one derivation and a large factory never rebuilds the
// whole index; sound because the dict is immutable after construction (every
// mutation produces a new dict).
let deriveContractNameByAddress: dict<array<Address.t>> => dict<
  string,
> = Utils.WeakMap.memoize(addressesByContractName => {
  let result = Dict.make()
  addressesByContractName->Utils.Dict.forEachWithKey((addresses, contractName) => {
    for i in 0 to addresses->Array.length - 1 {
      result->Dict.set(addresses->Array.getUnsafe(i)->Address.toString, contractName)
    }
  })
  result
})

// itemsTarget for a query over [fromBlock, toBlock] at the given event density
// (items/block). toBlock None is the open-ended tail, capped at
// chainTargetBlock — the soft per-tick horizon the owning chain wants to reach
// (see getNextQuery).
let densityItemsTarget = (~density, ~fromBlock, ~toBlock, ~chainTargetBlock) => {
  // Floor at 1: the reservation must equal the server-side cap SourceManager
  // sends, and a 0 cap would ask the backend for nothing.
  Pervasives.max(
    1,
    ((toBlock->Option.getOr(chainTargetBlock) - fromBlock + 1)->Int.toFloat *. density)
    ->Math.ceil
    ->Float.toInt,
  )
}

// Calculate the chunk range from history using min-of-last-3-ranges heuristic
let getMinHistoryRange = (p: partition) => {
  switch (p.prevQueryRange, p.prevPrevQueryRange) {
  | (0, _) | (_, 0) => None
  | (a, b) => Some(a < b ? a : b)
  }
}

// Density (items/block) from the last response, trusted only after two
// responses — a single sample is too noisy to size the next query by.
let getTrustedDensity = (p: partition) => {
  switch (p.prevQueryRange, p.prevPrevQueryRange) {
  | (0, _) | (_, 0) => None
  | (prevQueryRange, _) => Some(p.prevRangeSize->Int.toFloat /. prevQueryRange->Int.toFloat)
  }
}

let getMinQueryRange = (partitions: array<partition>) => {
  let min = ref(0)
  for i in 0 to partitions->Array.length - 1 {
    let p = partitions->Array.getUnsafe(i)

    // Even if it's fetching, set dynamicContract field
    let a = p.prevQueryRange
    let b = p.prevPrevQueryRange
    if a > 0 && (min.contents == 0 || a < min.contents) {
      min := a
    }
    if b > 0 && (min.contents == 0 || b < min.contents) {
      min := b
    }
  }
  min.contents
}

module OptimizedPartitions = {
  type t = {
    idsInAscOrder: array<string>,
    entities: dict<partition>, // hello redux-toolkit :)
    // Used for the incremental partition id. Can't use the partitions length,
    // since partitions might be deleted on merge or cleaned up
    maxAddrInPartition: int,
    nextPartitionIndex: int,
    // Tracks all contract names that have been dynamically added.
    // Never reset - used to determine when to split existing partitions.
    dynamicContracts: Utils.Set.t<string>,
  }

  @inline
  let count = (optimizedPartitions: t) => optimizedPartitions.idsInAscOrder->Array.length

  @inline
  let getOrThrow = (optimizedPartitions: t, ~partitionId) => {
    switch optimizedPartitions.entities->Dict.get(partitionId) {
    | Some(p) => p
    | None => JsError.throwWithMessage(`Unexpected case: Couldn't find partition ${partitionId}`)
    }
  }

  // Merges two partitions at a given potentialMergeBlock.
  // Returns array<partition> where the last element is the continuing partition
  // and all preceding elements are completed (have mergeBlock set).
  // Handles address overflow splitting inline.
  let mergePartitionsAtBlock = (
    ~p1: partition,
    ~p2: partition,
    ~potentialMergeBlock: int,
    ~contractName: string,
    ~maxAddrInPartition: int,
    ~nextPartitionIndexRef: ref<int>,
  ) => {
    let combinedAddresses =
      p1.addressesByContractName
      ->Dict.getUnsafe(contractName)
      ->Array.concat(p2.addressesByContractName->Dict.getUnsafe(contractName))

    let p1Below = p1.latestFetchedBlock.blockNumber < potentialMergeBlock
    let p2Below = p2.latestFetchedBlock.blockNumber < potentialMergeBlock

    // Build the continuing partition (at potentialMergeBlock with combined addresses),
    // collecting completed partitions (with mergeBlock) along the way
    let completed = []
    let continuingBase = switch (p1Below, p2Below) {
    | (false, false) => p1
    | (false, true) =>
      completed->Array.push({...p2, mergeBlock: Some(potentialMergeBlock)})->ignore
      p1
    | (true, false) =>
      completed->Array.push({...p1, mergeBlock: Some(potentialMergeBlock)})->ignore
      p2
    | (true, true) =>
      completed->Array.push({...p1, mergeBlock: Some(potentialMergeBlock)})->ignore
      completed->Array.push({...p2, mergeBlock: Some(potentialMergeBlock)})->ignore
      let newId = nextPartitionIndexRef.contents->Int.toString
      nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
      let minRange = getMinQueryRange([p1, p2])
      // The merged partition indexes both parents' addresses, so its expected
      // event rate is the sum of their densities. Parents without a trusted
      // density contribute 0; if none has one, prevRangeSize stays 0 and the
      // partition probes for a fresh signal instead of chunking.
      let inheritedDensity =
        p1->getTrustedDensity->Option.getOr(0.) +. p2->getTrustedDensity->Option.getOr(0.)
      {
        id: newId,
        dynamicContract: Some(contractName),
        selection: p1.selection,
        latestFetchedBlock: {blockNumber: potentialMergeBlock, blockTimestamp: 0},
        mergeBlock: None,
        addressesByContractName: Dict.make(), // set below
        mutPendingQueries: [],
        prevQueryRange: minRange,
        prevPrevQueryRange: minRange,
        prevRangeSize: (inheritedDensity *. minRange->Int.toFloat)->Math.ceil->Float.toInt,
        latestBlockRangeUpdateBlock: 0,
      }
    }

    // Apply address split on the continuing partition
    if combinedAddresses->Array.length > maxAddrInPartition {
      let addressesFull = combinedAddresses->Array.slice(~start=0, ~end=maxAddrInPartition)
      let addressesRest = combinedAddresses->Array.slice(~start=maxAddrInPartition)
      let abcFull = Dict.make()
      abcFull->Dict.set(contractName, addressesFull)
      let abcRest = Dict.make()
      abcRest->Dict.set(contractName, addressesRest)
      completed->Array.push({...continuingBase, addressesByContractName: abcFull})->ignore
      let restId = nextPartitionIndexRef.contents->Int.toString
      nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
      completed
      ->Array.push({
        ...continuingBase,
        id: restId,
        addressesByContractName: abcRest,
        mutPendingQueries: [],
      })
      ->ignore
      completed
    } else {
      let abc = Dict.make()
      abc->Dict.set(contractName, combinedAddresses)
      completed->Array.push({...continuingBase, addressesByContractName: abc})->ignore
      completed
    }
  }

  // Random number from my head
  // Not super critical if it's too big or too small
  // We optimize for fastest data which we get in any case.
  // If the value is off, it'll only result in
  // quering the same block range multiple times
  let tooFarBlockRange = 20_000

  let ascSortFn = (a, b) =>
    Int.compare(a.latestFetchedBlock.blockNumber, b.latestFetchedBlock.blockNumber)

  /**
   * Optimizes partitions by finding opportunities to merge partitions that
   * are behind other partitions with same/superset of contract names.
   *
   * Only partitions with dynamicContract set are eligible for optimization.
   * This way we don't have optimization overhead when partitions are stable.
   */
  let make = (
    ~partitions: array<partition>,
    ~maxAddrInPartition,
    ~nextPartitionIndex: int,
    ~dynamicContracts: Utils.Set.t<string>,
  ) => {
    let newPartitions = []
    let mergingPartitions = Dict.make()
    let nextPartitionIndexRef = ref(nextPartitionIndex)

    for idx in 0 to partitions->Array.length - 1 {
      let p = partitions->Array.getUnsafe(idx)
      switch p {
      // Since it's not a dynamic contract partition,
      // there's no need for merge logic
      | {dynamicContract: None}
      | // Wildcard doesn't need merging
      {selection: {dependsOnAddresses: false}}
      | // For now don't merge partitions with mergeBlock,
      // assuming they are already merged,
      // TODO: Although there might be cases with too far away mergeBlock,
      // which is worth merging
      {mergeBlock: Some(_)} =>
        newPartitions->Array.push(p)->ignore
      | {dynamicContract: Some(contractName)} =>
        let pAddressesCount = p.addressesByContractName->Dict.getUnsafe(contractName)->Array.length
        // Compute merge block: last pending query's toBlock, or lfb if idle
        let potentialMergeBlock = switch p.mutPendingQueries->Utils.Array.last {
        | Some({isChunk: true, toBlock: Some(toBlock)}) => Some(toBlock)
        | Some(_) => None // unbounded query -- can't merge
        | None => Some(p.latestFetchedBlock.blockNumber)
        }
        switch potentialMergeBlock {
        | None => newPartitions->Array.push(p)->ignore
        | Some(potentialMergeBlock) =>
          if pAddressesCount >= maxAddrInPartition {
            newPartitions->Array.push(p)->ignore
          } else {
            let partitionsByMergeBlock =
              mergingPartitions->Utils.Dict.getOrInsertEmptyDict(contractName)
            switch partitionsByMergeBlock->Utils.Dict.dangerouslyGetByIntNonOption(
              potentialMergeBlock,
            ) {
            | Some(existingPartition) =>
              let result = mergePartitionsAtBlock(
                ~p1=existingPartition,
                ~p2=p,
                ~potentialMergeBlock,
                ~contractName,
                ~maxAddrInPartition,
                ~nextPartitionIndexRef,
              )
              for i in 0 to result->Array.length - 2 {
                newPartitions->Array.push(result->Array.getUnsafe(i))->ignore
              }
              partitionsByMergeBlock->Utils.Dict.setByInt(
                potentialMergeBlock,
                result->Utils.Array.lastUnsafe,
              )
            | None => partitionsByMergeBlock->Utils.Dict.setByInt(potentialMergeBlock, p)
            }
          }
        }
      }
    }

    let merginDynamicContracts = mergingPartitions->Dict.keysToArray
    for idx in 0 to merginDynamicContracts->Array.length - 1 {
      let contractName = merginDynamicContracts->Array.getUnsafe(idx)
      let partitionsByMergeBlock = mergingPartitions->Dict.getUnsafe(contractName)
      // JS engine automatically sorts number keys in objects
      let ascPartitionKeys = partitionsByMergeBlock->Dict.keysToArray

      // But -1 is placed last...
      if ascPartitionKeys->Array.getUnsafe(ascPartitionKeys->Array.length - 1) === "-1" {
        ascPartitionKeys
        ->Array.unshift(ascPartitionKeys->Array.pop->Option.getUnsafe)
        ->ignore
      }
      let currentPRef = ref(
        partitionsByMergeBlock->Dict.getUnsafe(ascPartitionKeys->Utils.Array.firstUnsafe),
      )
      let currentPMergeBlockRef = ref(
        ascPartitionKeys->Utils.Array.firstUnsafe->Int.fromString->Option.getUnsafe,
      )
      let nextJdx = ref(1)
      while nextJdx.contents < ascPartitionKeys->Array.length {
        let nextKey = ascPartitionKeys->Array.getUnsafe(nextJdx.contents)
        let currentP = currentPRef.contents
        let nextP = partitionsByMergeBlock->Dict.getUnsafe(nextKey)
        let nextPMergeBlock = nextKey->Int.fromString->Option.getUnsafe
        let currentPMergeBlock = currentPMergeBlockRef.contents

        let isTooFar = currentPMergeBlock + tooFarBlockRange < nextPMergeBlock
        if isTooFar {
          newPartitions->Array.push(currentP)->ignore
          currentPRef := nextP
          currentPMergeBlockRef := nextPMergeBlock
        } else {
          let result = mergePartitionsAtBlock(
            ~p1=nextP,
            ~p2=currentP,
            ~potentialMergeBlock=nextPMergeBlock,
            ~contractName,
            ~maxAddrInPartition,
            ~nextPartitionIndexRef,
          )
          for i in 0 to result->Array.length - 2 {
            newPartitions->Array.push(result->Array.getUnsafe(i))->ignore
          }
          currentPRef := result->Utils.Array.lastUnsafe
          currentPMergeBlockRef := nextPMergeBlock
        }

        nextJdx := nextJdx.contents + 1
      }

      newPartitions->Array.push(currentPRef.contents)->ignore
    }

    // Sort partitions by latestFetchedBlock ascending
    let _ = newPartitions->Array.sort(ascSortFn)

    let partitionsCount = newPartitions->Array.length
    let idsInAscOrder = Utils.Array.jsArrayCreate(partitionsCount)
    let entities = Dict.make()
    for idx in 0 to partitionsCount - 1 {
      let p = newPartitions->Array.getUnsafe(idx)
      idsInAscOrder->Array.setUnsafe(idx, p.id)
      entities->Dict.set(p.id, p)
    }

    {
      idsInAscOrder,
      entities,
      maxAddrInPartition,
      nextPartitionIndex: nextPartitionIndexRef.contents,
      dynamicContracts,
    }
  }

  // Helper to process fetched queries from the front of the queue
  // Removes consecutive fetched queries and returns the last fetchedBlock.
  // Stops if the next query's fromBlock is not contiguous with the current
  // latestFetchedBlock (gap from a partial chunk fetch).
  @inline
  let consumeFetchedQueries = (
    mutPendingQueries: array<pendingQuery>,
    ~initialLatestFetchedBlock: blockNumberAndTimestamp,
  ) => {
    let latestFetchedBlock = ref(initialLatestFetchedBlock)

    while (
      mutPendingQueries->Array.length > 0 && {
          let pq = mutPendingQueries->Utils.Array.firstUnsafe
          pq.fetchedBlock !== None && pq.fromBlock <= latestFetchedBlock.contents.blockNumber + 1
        }
    ) {
      let removedQuery = mutPendingQueries->Array.shift->Option.getUnsafe
      latestFetchedBlock := removedQuery.fetchedBlock->Option.getUnsafe
    }

    latestFetchedBlock.contents
  }

  let getPendingQueryOrThrow = (p: partition, ~fromBlock) => {
    let idxRef = ref(0)
    let pendingQueryRef = ref(None)
    while idxRef.contents < p.mutPendingQueries->Array.length && pendingQueryRef.contents === None {
      let pq = p.mutPendingQueries->Array.getUnsafe(idxRef.contents)
      if pq.fromBlock === fromBlock {
        pendingQueryRef := Some(pq)
      }
      idxRef := idxRef.contents + 1
    }
    switch pendingQueryRef.contents {
    | Some(pq) => pq
    | None =>
      JsError.throwWithMessage(
        `Pending query not found for partition ${p.id} fromBlock ${fromBlock->Int.toString}`,
      )
    }
  }

  let handleQueryResponse = (
    optimizedPartitions: t,
    ~query,
    ~knownHeight,
    ~itemsCount,
    ~latestFetchedBlock: blockNumberAndTimestamp,
  ) => {
    let p = optimizedPartitions->getOrThrow(~partitionId=query.partitionId)
    let mutEntities = optimizedPartitions.entities->Utils.Dict.shallowCopy

    // Mark query as fetched
    let pendingQuery = getPendingQueryOrThrow(p, ~fromBlock=query.fromBlock)
    pendingQuery.fetchedBlock = Some(latestFetchedBlock)

    let blockRange = latestFetchedBlock.blockNumber - query.fromBlock + 1
    // Skip updating block range if a later response already updated it.
    // Prevents degradation of the chunking heuristic when parallel query
    // responses arrive out of order (e.g. earlier query with smaller range
    // arriving after a later query with bigger range).
    let shouldUpdateBlockRange =
      latestFetchedBlock.blockNumber > p.latestBlockRangeUpdateBlock &&
        switch query.toBlock {
        | None => latestFetchedBlock.blockNumber < knownHeight - 10 // Don't update block range when very close to the head
        | Some(queryToBlock) =>
          // Update on partial response (direct capacity evidence),
          // or when the query's intended range covers at least the partition's
          // current chunk range — meaning it was a capacity-based split chunk,
          // not a small gap-fill whose toBlock is an artificial boundary.
          latestFetchedBlock.blockNumber < queryToBlock ||
            switch getMinHistoryRange(p) {
            | None => false // Chunking not active yet, don't update
            | Some(minHistoryRange) => queryToBlock - query.fromBlock + 1 >= minHistoryRange
            }
        }
    let updatedPrevQueryRange = shouldUpdateBlockRange ? blockRange : p.prevQueryRange
    let updatedPrevPrevQueryRange = shouldUpdateBlockRange ? p.prevQueryRange : p.prevPrevQueryRange
    let updatedPrevRangeSize = shouldUpdateBlockRange ? itemsCount : p.prevRangeSize

    // Process fetched queries from front of queue for main partition
    let updatedLatestFetchedBlock = consumeFetchedQueries(
      p.mutPendingQueries,
      ~initialLatestFetchedBlock=p.latestFetchedBlock,
    )

    // Check if partition reached its mergeBlock and should be removed
    let partitionReachedMergeBlock = switch p.mergeBlock {
    | Some(mergeBlock) => updatedLatestFetchedBlock.blockNumber >= mergeBlock
    | None => false
    }

    if partitionReachedMergeBlock {
      mutEntities->Utils.Dict.deleteInPlace(p.id)
    } else {
      let updatedMainPartition = {
        ...p,
        latestFetchedBlock: updatedLatestFetchedBlock,
        prevQueryRange: updatedPrevQueryRange,
        prevPrevQueryRange: updatedPrevPrevQueryRange,
        prevRangeSize: updatedPrevRangeSize,
        latestBlockRangeUpdateBlock: shouldUpdateBlockRange
          ? latestFetchedBlock.blockNumber
          : p.latestBlockRangeUpdateBlock,
      }

      mutEntities->Dict.set(p.id, updatedMainPartition)
    }

    // Re-optimize to maintain sorted order and apply optimizations
    make(
      ~partitions=mutEntities->Dict.valuesToArray,
      ~maxAddrInPartition=optimizedPartitions.maxAddrInPartition,
      ~nextPartitionIndex=optimizedPartitions.nextPartitionIndex,
      ~dynamicContracts=optimizedPartitions.dynamicContracts,
    )
  }

  @inline
  let getLatestFullyFetchedBlock = (optimizedPartitions: t) => {
    switch optimizedPartitions.idsInAscOrder->Array.get(0) {
    | Some(id) => Some((optimizedPartitions.entities->Dict.getUnsafe(id)).latestFetchedBlock)
    | None => None
    }
  }
}

type t = {
  optimizedPartitions: OptimizedPartitions.t,
  startBlock: int,
  endBlock: option<int>,
  normalSelection: selection,
  // By contract name
  contractConfigs: dict<IndexingAddresses.contractConfig>,
  // Not used for logic - only metadata
  chainId: int,
  // The block number of the latest block which was added to the queue
  // by the onBlock configs
  // Need a separate pointer for this
  // to prevent OOM when adding too many items to the queue
  latestOnBlockBlockNumber: int,
  // How much blocks behind the head we should query
  // Needed to query before entering reorg threshold
  blockLag: int,
  // Buffer of items ordered from earliest to latest
  buffer: array<Internal.item>,
  // Caps how far ahead onBlock items are pre-generated (set to 2x the batch
  // size). Event fetch depth is bounded separately, by CrossChainState's
  // cross-chain admission against the indexer-wide buffer pool.
  maxOnBlockBufferSize: int,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
  knownHeight: int,
  firstEventBlock: option<int>,
}

@inline
let bufferBlockNumber = ({latestOnBlockBlockNumber, optimizedPartitions}: t) => {
  switch optimizedPartitions->OptimizedPartitions.getLatestFullyFetchedBlock {
  | None => latestOnBlockBlockNumber
  | Some(latestFullyFetchedBlock) =>
    latestOnBlockBlockNumber < latestFullyFetchedBlock.blockNumber
      ? latestOnBlockBlockNumber
      : latestFullyFetchedBlock.blockNumber
  }
}

/**
* Returns the latest block which is ready to be consumed
*/
@inline
let bufferBlock = ({optimizedPartitions, latestOnBlockBlockNumber}: t) => {
  switch optimizedPartitions->OptimizedPartitions.getLatestFullyFetchedBlock {
  | None => {
      blockNumber: latestOnBlockBlockNumber,
      blockTimestamp: 0,
    }
  | Some(latestFullyFetchedBlock) =>
    latestOnBlockBlockNumber < latestFullyFetchedBlock.blockNumber
      ? {
          blockNumber: latestOnBlockBlockNumber,
          blockTimestamp: 0,
        }
      : latestFullyFetchedBlock
  }
}

// Number of buffered items at or below the ready frontier (processable now,
// i.e. not stuck behind a gap from a lagging partition or out-of-order chunk).
// The buffer is kept sorted, so binary-search the frontier in O(log n).
let bufferReadyCount = (fetchState: t) => {
  let frontier = fetchState->bufferBlockNumber
  let buffer = fetchState.buffer
  let lo = ref(0)
  let hi = ref(buffer->Array.length)
  while lo.contents < hi.contents {
    let mid = (lo.contents + hi.contents) / 2
    if buffer->Array.getUnsafe(mid)->Internal.getItemBlockNumber <= frontier {
      lo := mid + 1
    } else {
      hi := mid
    }
  }
  lo.contents
}

/*
Comparitor for two events from the same chain. No need for chain id or timestamp
*/
let compareBufferItem = (a: Internal.item, b: Internal.item) => {
  let blockOrdering = Int.compare(a->Internal.getItemBlockNumber, b->Internal.getItemBlockNumber)
  if blockOrdering === Ordering.equal {
    Int.compare(a->Internal.getItemLogIndex, b->Internal.getItemLogIndex)
  } else {
    blockOrdering
  }
}

// Some big number which should be bigger than any log index
let blockItemLogIndex = 16777216

// Appends Block items produced by the onBlock handlers for every block in
// (fromBlock, maxBlockNumber] into mutItems and returns the new
// latestOnBlockBlockNumber pointer. maxOnBlockBufferSize bounds how many items
// are generated at once to prevent OOM.
let appendOnBlockItems = (
  ~mutItems: array<Internal.item>,
  ~onBlockRegistrations: array<Internal.onBlockRegistration>,
  ~indexerStartBlock,
  ~fromBlock,
  ~maxBlockNumber,
  ~maxOnBlockBufferSize,
) => {
  let newItemsCounter = ref(0)
  let latestOnBlockBlockNumber = ref(fromBlock)

  // Simply iterate over every block
  // could have a better algorithm to iterate over blocks in a more efficient way
  // but raw loops are fast enough
  while (
    latestOnBlockBlockNumber.contents < maxBlockNumber &&
      // Additional safeguard to prevent OOM
      newItemsCounter.contents <= maxOnBlockBufferSize
  ) {
    let blockNumber = latestOnBlockBlockNumber.contents + 1
    latestOnBlockBlockNumber := blockNumber

    for configIdx in 0 to onBlockRegistrations->Array.length - 1 {
      let onBlockRegistration = onBlockRegistrations->Array.getUnsafe(configIdx)

      let handlerStartBlock = switch onBlockRegistration.startBlock {
      | Some(startBlock) => startBlock
      | None => indexerStartBlock
      }

      if (
        blockNumber >= handlerStartBlock &&
        switch onBlockRegistration.endBlock {
        | Some(endBlock) => blockNumber <= endBlock
        | None => true
        } &&
        (blockNumber - handlerStartBlock)->Pervasives.mod(onBlockRegistration.interval) === 0
      ) {
        mutItems->Array.push(
          Block({
            onBlockRegistration,
            blockNumber,
            logIndex: blockItemLogIndex + onBlockRegistration.index,
          }),
        )
        newItemsCounter := newItemsCounter.contents + 1
      }
    }
  }

  latestOnBlockBlockNumber.contents
}

/*
Update fetchState, merge registers and recompute derived values.
Runs partition optimization when partitions change.
*/
let updateInternal = (
  fetchState: t,
  ~optimizedPartitions=fetchState.optimizedPartitions,
  ~mutItems=?,
  ~blockLag=fetchState.blockLag,
  ~knownHeight=fetchState.knownHeight,
): t => {
  let mutItemsRef = ref(mutItems)

  let latestOnBlockBlockNumber = switch fetchState.onBlockRegistrations {
  | [] => knownHeight
  | onBlockRegistrations => {
      // Calculate the max block number we are going to create items for
      // Use maxOnBlockBufferSize to get the last target item in the buffer
      //
      // mutItems is not very reliable, since it might not be sorted,
      // but the chances for it happen are very low and not critical
      //
      // All this needed to prevent OOM when adding too many block items to the queue
      let maxBlockNumber = switch switch mutItemsRef.contents {
      | Some(mutItems) => mutItems
      | None => fetchState.buffer
      }->Array.get(fetchState.maxOnBlockBufferSize - 1) {
      | Some(item) => item->Internal.getItemBlockNumber
      | None =>
        switch optimizedPartitions->OptimizedPartitions.getLatestFullyFetchedBlock {
        | None => knownHeight
        | Some(latestFullyFetchedBlock) => latestFullyFetchedBlock.blockNumber
        }
      }

      let mutItems = switch mutItemsRef.contents {
      | Some(mutItems) => mutItems
      | None => fetchState.buffer->Array.copy
      }
      mutItemsRef := Some(mutItems)

      appendOnBlockItems(
        ~mutItems,
        ~onBlockRegistrations,
        ~indexerStartBlock=fetchState.startBlock,
        ~fromBlock=fetchState.latestOnBlockBlockNumber,
        ~maxBlockNumber,
        ~maxOnBlockBufferSize=fetchState.maxOnBlockBufferSize,
      )
    }
  }

  let updatedFetchState = {
    startBlock: fetchState.startBlock,
    endBlock: fetchState.endBlock,
    contractConfigs: fetchState.contractConfigs,
    normalSelection: fetchState.normalSelection,
    chainId: fetchState.chainId,
    onBlockRegistrations: fetchState.onBlockRegistrations,
    maxOnBlockBufferSize: fetchState.maxOnBlockBufferSize,
    optimizedPartitions,
    latestOnBlockBlockNumber,
    blockLag,
    knownHeight,
    buffer: switch mutItemsRef.contents {
    // Theoretically it could be faster to asume that
    // the items are sorted, but there are cases
    // when the data source returns them unsorted
    | Some(mutItems) => {
        mutItems->Array.sort(compareBufferItem)
        mutItems
      }
    | None => fetchState.buffer
    },
    firstEventBlock: fetchState.firstEventBlock,
  }

  Prometheus.IndexingPartitions.set(
    ~partitionsCount=optimizedPartitions->OptimizedPartitions.count,
    ~chainId=fetchState.chainId,
  )
  Prometheus.IndexingBufferSize.set(
    ~bufferSize=updatedFetchState.buffer->Array.length,
    ~chainId=fetchState.chainId,
  )
  Prometheus.IndexingBufferBlockNumber.set(
    ~blockNumber=updatedFetchState->bufferBlockNumber,
    ~chainId=fetchState.chainId,
  )

  updatedFetchState
}

let warnDifferentContractType = (
  fetchState,
  ~existingContract: indexingAddress,
  ~dc: indexingAddress,
) => {
  let logger = Logging.createChild(
    ~params={
      "chainId": fetchState.chainId,
      "contractAddress": dc.address->Address.toString,
      "existingContractType": existingContract.contractName,
      "newContractType": dc.contractName,
    },
  )
  logger->Logging.childWarn(`Skipping contract registration: Contract address is already registered for one contract and cannot be registered for another contract.`)
}

let addressesByContractNameCount = (addressesByContractName: dict<array<Address.t>>) => {
  let numAddresses = ref(0)
  addressesByContractName->Utils.Dict.forEach(addresses => {
    numAddresses := numAddresses.contents + addresses->Array.length
  })
  numAddresses.contents
}

let addressesByContractNameGetAll = (addressesByContractName: dict<array<Address.t>>) => {
  let all = []
  addressesByContractName->Utils.Dict.forEach(addresses => {
    for idx in 0 to addresses->Array.length - 1 {
      all->Array.push(addresses->Array.getUnsafe(idx))->ignore
    }
  })
  all
}

/**
Creates partitions from indexing addresses with two phases:
Phase 1: Create per-contract-name partitions (smart grouping by startBlock)
Phase 2: Merge non-dynamic partitions together to reduce unnecessary concurrency
Returns OptimizedPartitions.t directly.
(Dynamic partitions are merged by OptimizedPartitions.make automatically)
*/
let createPartitionsFromIndexingAddresses = (
  ~registeringContractsByContract: dict<dict<indexingAddress>>,
  ~dynamicContracts: Utils.Set.t<string>,
  ~normalSelection: selection,
  ~maxAddrInPartition: int,
  ~nextPartitionIndex: int,
  ~existingPartitions: array<partition>,
  ~progressBlockNumber: int,
): // Floor for latestFetchedBlock (use progressBlockNumber from make, or 0 for registerDynamicContracts)
OptimizedPartitions.t => {
  let nextPartitionIndexRef = ref(nextPartitionIndex)

  // ── Phase 1: Create per-contract-name partitions ──
  let dynamicPartitions = []
  let nonDynamicPartitions = []

  let contractNames = registeringContractsByContract->Dict.keysToArray
  for cIdx in 0 to contractNames->Array.length - 1 {
    let contractName = contractNames->Array.getUnsafe(cIdx)
    let registeringContracts = registeringContractsByContract->Dict.getUnsafe(contractName)
    let addresses =
      registeringContracts->Dict.keysToArray->(Utils.magic: array<string> => array<Address.t>)

    let isDynamic = dynamicContracts->Utils.Set.has(contractName)
    let partitions = isDynamic ? dynamicPartitions : nonDynamicPartitions

    let byStartBlock = Dict.make()
    for jdx in 0 to addresses->Array.length - 1 {
      let address = addresses->Array.getUnsafe(jdx)
      let indexingContract = registeringContracts->Dict.getUnsafe(address->Address.toString)
      byStartBlock->Utils.Dict.push(indexingContract.effectiveStartBlock->Int.toString, address)
    }

    // Will be in ASC order by JS spec
    let ascKeys = byStartBlock->Dict.keysToArray
    let initialKey = ascKeys->Utils.Array.firstUnsafe

    let startBlockRef = ref(initialKey->Int.fromString->Option.getUnsafe)
    let addressesRef = ref(byStartBlock->Dict.getUnsafe(initialKey))

    for idx in 0 to ascKeys->Array.length - 1 {
      let maybeNextStartBlockKey =
        ascKeys->Array.getUnsafe(idx + 1)->(Utils.magic: string => option<string>)

      let shouldAllocateNewPartition = switch maybeNextStartBlockKey {
      | None => true
      | Some(nextStartBlockKey) => {
          let nextStartBlock = nextStartBlockKey->Int.fromString->Option.getUnsafe
          let shouldJoinCurrentStartBlock =
            nextStartBlock - startBlockRef.contents < OptimizedPartitions.tooFarBlockRange

          // Addresses with different start blocks within range share a partition;
          // events before each address's effectiveStartBlock are dropped on the
          // client side (EventRouter for the srcAddress, the event's
          // clientAddressFilter for address-valued params).
          if shouldJoinCurrentStartBlock {
            addressesRef :=
              addressesRef.contents->Array.concat(byStartBlock->Dict.getUnsafe(nextStartBlockKey))
            false
          } else {
            true
          }
        }
      }

      if shouldAllocateNewPartition {
        let latestFetchedBlock = {
          blockNumber: Pervasives.max(startBlockRef.contents - 1, progressBlockNumber),
          blockTimestamp: 0,
        }
        while addressesRef.contents->Array.length > 0 {
          let pAddresses = addressesRef.contents->Array.slice(~start=0, ~end=maxAddrInPartition)
          addressesRef.contents = addressesRef.contents->Array.slice(~start=maxAddrInPartition)

          let addressesByContractName = Dict.make()
          addressesByContractName->Dict.set(contractName, pAddresses)
          partitions->Array.push({
            id: nextPartitionIndexRef.contents->Int.toString,
            latestFetchedBlock,
            selection: normalSelection,
            dynamicContract: isDynamic ? Some(contractName) : None,
            addressesByContractName,
            mergeBlock: None,
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            prevRangeSize: 0,
            latestBlockRangeUpdateBlock: 0,
          })
          nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
        }

        switch maybeNextStartBlockKey {
        | None => ()
        | Some(nextStartBlockKey) => {
            startBlockRef := nextStartBlockKey->Int.fromString->Option.getUnsafe
            addressesRef := byStartBlock->Dict.getUnsafe(nextStartBlockKey)
          }
        }
      }
    }
  }

  // ── Phase 2: Merge non-dynamic partitions ──
  let mergedNonDynamic = []

  if nonDynamicPartitions->Array.length > 0 {
    // Sort non-dynamic partitions by latestFetchedBlock ascending
    let _ = nonDynamicPartitions->Array.sort(OptimizedPartitions.ascSortFn)

    let currentPRef = ref(nonDynamicPartitions->Array.getUnsafe(0))
    let nextIdx = ref(1)

    while nextIdx.contents < nonDynamicPartitions->Array.length {
      let nextP = nonDynamicPartitions->Array.getUnsafe(nextIdx.contents)
      let currentP = currentPRef.contents
      let currentPBlock = currentP.latestFetchedBlock.blockNumber
      let nextPBlock = nextP.latestFetchedBlock.blockNumber

      // Compute total count WITHOUT mutating any arrays
      let totalCount =
        currentP.addressesByContractName->addressesByContractNameCount +
          nextP.addressesByContractName->addressesByContractNameCount

      if totalCount > maxAddrInPartition {
        // Exceeds address limit - don't merge, keep partitions separate
        mergedNonDynamic->Array.push(currentP)->ignore
        currentPRef := nextP
      } else {
        // Build merged addresses using Array.concat (non-mutating)
        let mergedAddresses = nextP.addressesByContractName->Utils.Dict.shallowCopy
        let currentContractNames = currentP.addressesByContractName->Dict.keysToArray
        for jdx in 0 to currentContractNames->Array.length - 1 {
          let cn = currentContractNames->Array.getUnsafe(jdx)
          let currentAddrs = currentP.addressesByContractName->Dict.getUnsafe(cn)
          switch mergedAddresses->Utils.Dict.dangerouslyGetNonOption(cn) {
          | Some(existingAddrs) =>
            // Use concat (non-mutating) to avoid corrupting nextP's arrays
            mergedAddresses->Dict.set(cn, existingAddrs->Array.concat(currentAddrs))
          | None => mergedAddresses->Dict.set(cn, currentAddrs)
          }
        }

        let isTooFar = currentPBlock + OptimizedPartitions.tooFarBlockRange < nextPBlock

        if isTooFar {
          // Too far: mergeBlock on current, merge addresses into next
          mergedNonDynamic
          ->Array.push({
            ...currentP,
            mergeBlock: currentPBlock < nextPBlock ? Some(nextPBlock) : None,
          })
          ->ignore
          currentPRef := {
              ...nextP,
              addressesByContractName: mergedAddresses,
            }
        } else {
          // Close: push next's addresses into current
          currentPRef := {
              ...currentP,
              addressesByContractName: mergedAddresses,
            }
        }
      }

      nextIdx := nextIdx.contents + 1
    }

    mergedNonDynamic->Array.push(currentPRef.contents)->ignore
  }

  let mergedPartitions = mergedNonDynamic->Array.concat(dynamicPartitions)

  // Final step: concat existing partitions with phase 1+2 result and call OptimizedPartitions.make
  OptimizedPartitions.make(
    ~partitions=existingPartitions->Array.concat(mergedPartitions),
    ~maxAddrInPartition,
    ~nextPartitionIndex=nextPartitionIndexRef.contents,
    ~dynamicContracts,
  )
}

let registerDynamicContracts = (
  fetchState: t,
  ~indexingAddresses: IndexingAddresses.t,
  // These are raw items which might have dynamic contracts received from contractRegister call.
  // Might contain duplicates which we should filter out
  items: array<Internal.item>,
) => {
  if fetchState.normalSelection.onEventRegistrations->Utils.Array.isEmpty {
    // Can the normalSelection be empty?
    JsError.throwWithMessage(
      "Invalid configuration. No events to fetch for the dynamic contract registration.",
    )
  }

  let registeringContractsByContract: dict<dict<indexingAddress>> = Dict.make()
  let earliestRegisteringEventBlockNumber = ref(%raw(`Infinity`))
  // Addresses registered for contracts without matching events. These are not
  // added to partitions, but they are tracked on indexingAddresses
  // so that later conflicting registrations are detected, and are persisted
  // to envio_addresses so they can be picked up on restart with updated config.
  let noEventsAddresses: dict<indexingAddress> = Dict.make()
  // Batch-level view of all addresses registered so far (across contracts,
  // including no-events ones), so two contracts registering the same address
  // within one batch conflict the same way as against indexingAddresses.
  let registeringAddresses: dict<indexingAddress> = Dict.make()

  for itemIdx in 0 to items->Array.length - 1 {
    let item = items->Array.getUnsafe(itemIdx)
    switch item->Internal.getItemDcs {
    | None => ()
    | Some(dcs) =>
      let idx = ref(0)
      while idx.contents < dcs->Array.length {
        let dc = dcs->Array.getUnsafe(idx.contents)

        let shouldRemove = ref(false)

        switch fetchState.contractConfigs->Utils.Dict.dangerouslyGetNonOption(dc.contractName) {
        | Some({startBlock: contractStartBlock}) =>
          let dcWithStartBlock: indexingAddress = {
            address: dc.address,
            contractName: dc.contractName,
            registrationBlock: dc.registrationBlock,
            effectiveStartBlock: IndexingAddresses.deriveEffectiveStartBlock(
              ~registrationBlock=dc.registrationBlock,
              ~contractStartBlock,
            ),
          }
          // Prevent registering already indexing contracts
          switch indexingAddresses->IndexingAddresses.get(dc.address->Address.toString) {
          | Some(existingContract) =>
            // FIXME: Instead of filtering out duplicates,
            // we should check the block number first.
            // If new registration with earlier block number
            // we should register it for the missing block range
            if existingContract.contractName != dc.contractName {
              fetchState->warnDifferentContractType(~existingContract, ~dc=dcWithStartBlock)
            } else if existingContract.effectiveStartBlock > dcWithStartBlock.effectiveStartBlock {
              let logger = Logging.createChild(
                ~params={
                  "chainId": fetchState.chainId,
                  "contractAddress": dc.address->Address.toString,
                  "existingBlockNumber": existingContract.effectiveStartBlock,
                  "newBlockNumber": dcWithStartBlock.effectiveStartBlock,
                },
              )
              logger->Logging.childWarn(`Skipping contract registration: Contract address is already registered at a later block number. Currently registration of the same contract address is not supported by Envio. Reach out to us if it's a problem for you.`)
            }
            shouldRemove := true
          | None =>
            let shouldUpdate = switch registeringAddresses->Utils.Dict.dangerouslyGetNonOption(
              dc.address->Address.toString,
            ) {
            | Some(registeringContract) if registeringContract.contractName != dc.contractName =>
              fetchState->warnDifferentContractType(
                ~existingContract=registeringContract,
                ~dc=dcWithStartBlock,
              )
              false
            | Some(_) => // Since the DC is registered by an earlier item in the query
              // FIXME: This unsafely relies on the asc order of the items
              // which is 99% true, but there were cases when the source ordering was wrong
              false
            | None => true
            }
            if shouldUpdate {
              earliestRegisteringEventBlockNumber :=
                Pervasives.min(
                  earliestRegisteringEventBlockNumber.contents,
                  dcWithStartBlock.effectiveStartBlock,
                )
              registeringContractsByContract
              ->Utils.Dict.getOrInsertEmptyDict(dc.contractName)
              ->Dict.set(dc.address->Address.toString, dcWithStartBlock)
              registeringAddresses->Dict.set(dc.address->Address.toString, dcWithStartBlock)
            } else {
              shouldRemove := true
            }
          }
        | None =>
          let dcAsIndexingAddress: indexingAddress = {
            address: dc.address,
            contractName: dc.contractName,
            registrationBlock: dc.registrationBlock,
            effectiveStartBlock: IndexingAddresses.deriveEffectiveStartBlock(
              ~registrationBlock=dc.registrationBlock,
              ~contractStartBlock=None,
            ),
          }
          // Prevent duplicate logging/persistence when the same address is
          // already tracked on fetchState, either from the db on startup or
          // from an earlier registration in this batch.
          switch indexingAddresses->IndexingAddresses.get(dc.address->Address.toString) {
          | Some(existingContract) =>
            if existingContract.contractName != dc.contractName {
              fetchState->warnDifferentContractType(~existingContract, ~dc=dcAsIndexingAddress)
            }
            shouldRemove := true
          | None =>
            switch registeringAddresses->Utils.Dict.dangerouslyGetNonOption(
              dc.address->Address.toString,
            ) {
            | Some(existingContract) =>
              if existingContract.contractName != dc.contractName {
                fetchState->warnDifferentContractType(~existingContract, ~dc=dcAsIndexingAddress)
              }
              // Otherwise already queued for persistence by an earlier item in this batch.
              shouldRemove := true
            | None =>
              let logger = Logging.createChild(
                ~params={
                  "chainId": fetchState.chainId,
                  "contractAddress": dc.address->Address.toString,
                  "contractName": dc.contractName,
                },
              )
              // Persist the address to the db so a future config change that
              // adds events for this contract can pick it up on restart, but
              // skip partition registration since there's nothing to fetch.
              logger->Logging.childWarn(`Persisting contract registration without fetching: Contract doesn't have any events to fetch. It'll be picked up on restart if you add events for the contract.`)
              noEventsAddresses->Dict.set(dc.address->Address.toString, dcAsIndexingAddress)
              registeringAddresses->Dict.set(dc.address->Address.toString, dcAsIndexingAddress)
            }
          }
        }

        if shouldRemove.contents {
          // Remove the DC from item to prevent it from saving to the db
          let _ = dcs->Array.splice(~start=idx.contents, ~remove=1, ~insert=[])
          // Don't increment idx - next element shifted into current position
        } else {
          idx := idx.contents + 1
        }
      }
    }
  }

  let dcContractNamesToStore = registeringContractsByContract->Dict.keysToArray
  let hasNoEventsUpdates = !(noEventsAddresses->Utils.Dict.isEmpty)
  switch (dcContractNamesToStore, hasNoEventsUpdates) {
  // Dont update anything when everything was filter out
  | ([], false) => fetchState
  | ([], true) =>
    // Only dcs for contracts without events. Track them on
    // indexingAddresses so subsequent registrations see them, but don't touch
    // partitions since there's nothing to fetch for them.
    indexingAddresses->IndexingAddresses.register(noEventsAddresses)
    fetchState
  | (_, _) => {
      let newPartitions = []
      let dynamicContractsRef = ref(fetchState.optimizedPartitions.dynamicContracts)
      let mutExistingPartitions = fetchState.optimizedPartitions.entities->Dict.valuesToArray

      for idx in 0 to dcContractNamesToStore->Array.length - 1 {
        let contractName = dcContractNamesToStore->Array.getUnsafe(idx)

        // When a new contract name is added as a dynamic contract for the first time (not in dynamicContracts set):
        // Walks through existing partitions that have addresses for this contract name
        // - If partition has ONLY this contract's addresses -> sets dynamicContract field
        // - If partition has this contract's addresses AND other contracts -> splits them
        // For the sake of merging simplicity we want to make sure that
        // partition has addresses of only one contract
        if !(dynamicContractsRef.contents->Utils.Set.has(contractName)) {
          dynamicContractsRef := dynamicContractsRef.contents->Utils.Set.immutableAdd(contractName)

          for idx in 0 to mutExistingPartitions->Array.length - 1 {
            let p = mutExistingPartitions->Array.getUnsafe(idx)
            switch p.addressesByContractName->Utils.Dict.dangerouslyGetNonOption(contractName) {
            | None => () // Skip partitions which don't have our contract
            | Some(addresses) =>
              // Also filter out partitions which are 100% not mergable
              if p.selection.dependsOnAddresses && p.mergeBlock === None {
                let allPartitionContractNames = p.addressesByContractName->Dict.keysToArray
                switch allPartitionContractNames {
                | [_] =>
                  mutExistingPartitions->Array.setUnsafe(
                    idx,
                    {
                      ...p,
                      dynamicContract: Some(contractName),
                    },
                  )
                | _ => {
                    let isFetching = p.mutPendingQueries->Array.length > 0
                    if isFetching {
                      // The partition won't be split and won't get a dynamicContract field
                      // This won't allow to optimize the partitions to the potential max
                      // Not super critical - at least we won't have a burden of
                      // splitting a fetching partition and then handing the response
                      ()
                    } else {
                      let newPartitionId =
                        (fetchState.optimizedPartitions.nextPartitionIndex +
                        newPartitions->Array.length)->Int.toString

                      let restAddressesByContractName =
                        p.addressesByContractName->Utils.Dict.shallowCopy
                      restAddressesByContractName->Utils.Dict.deleteInPlace(contractName)

                      mutExistingPartitions->Array.setUnsafe(
                        idx,
                        {
                          ...p,
                          addressesByContractName: restAddressesByContractName,
                        },
                      )

                      let addressesByContractName = Dict.make()
                      addressesByContractName->Dict.set(contractName, addresses)
                      newPartitions->Array.push({
                        id: newPartitionId,
                        latestFetchedBlock: p.latestFetchedBlock,
                        selection: fetchState.normalSelection,
                        dynamicContract: Some(contractName),
                        addressesByContractName,
                        mergeBlock: None,
                        mutPendingQueries: p.mutPendingQueries,
                        prevQueryRange: p.prevQueryRange,
                        prevPrevQueryRange: p.prevPrevQueryRange,
                        prevRangeSize: p.prevRangeSize,
                        latestBlockRangeUpdateBlock: p.latestBlockRangeUpdateBlock,
                      })
                    }
                  }
                }
              }
            }
          }
        }

        let registeringContracts = registeringContractsByContract->Dict.getUnsafe(contractName)
        indexingAddresses->IndexingAddresses.register(registeringContracts)
      }
      // Include no-events dcs so later batches detect conflicts against them.
      indexingAddresses->IndexingAddresses.register(noEventsAddresses)

      let optimizedPartitions = createPartitionsFromIndexingAddresses(
        ~registeringContractsByContract,
        ~dynamicContracts=dynamicContractsRef.contents,
        ~normalSelection=fetchState.normalSelection,
        ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
        ~nextPartitionIndex=fetchState.optimizedPartitions.nextPartitionIndex +
        newPartitions->Array.length,
        ~existingPartitions=mutExistingPartitions->Array.concat(newPartitions),
        ~progressBlockNumber=0,
      )

      fetchState->updateInternal(~optimizedPartitions)
    }
  }
}

/*
Updates fetchState with a response for a given query.
Returns Error if the partition with given query cannot be found (unexpected)

newItems are ordered earliest to latest (as they are returned from the worker)
*/
let handleQueryResult = (
  fetchState: t,
  ~indexingAddresses: IndexingAddresses.t,
  ~query: query,
  ~latestFetchedBlock: blockNumberAndTimestamp,
  ~newItems,
): t => {
  // Drop events an address-param filter rejects. A merged partition may
  // over-fetch a wildcard event whose indexed address param references an
  // address registered after the log's block; `clientAddressFilter` is the
  // param-level analogue of EventRouter's srcAddress effectiveStartBlock check.
  let newItems = newItems->Array.filter(item =>
    switch item {
    | Internal.Event({onEventRegistration, payload, blockNumber}) =>
      switch onEventRegistration.clientAddressFilter {
      | Some(filter) =>
        filter(payload, blockNumber, indexingAddresses->IndexingAddresses.rawForFilter)
      | None => true
      }
    | _ => true
    }
  )
  fetchState->updateInternal(
    ~optimizedPartitions=fetchState.optimizedPartitions->OptimizedPartitions.handleQueryResponse(
      ~query,
      ~knownHeight=fetchState.knownHeight,
      ~itemsCount=newItems->Array.length,
      ~latestFetchedBlock,
    ),
    ~mutItems=?{
      switch newItems {
      | [] => None
      | _ => Some(fetchState.buffer->Array.concat(newItems))
      }
    },
  )
}

type nextQuery =
  | WaitingForNewBlock
  | NothingToQuery
  | Ready(array<query>)

let startFetchingQueries = ({optimizedPartitions}: t, ~queries: array<query>) => {
  for qIdx in 0 to queries->Array.length - 1 {
    let q = queries->Array.getUnsafe(qIdx)
    let p = optimizedPartitions->OptimizedPartitions.getOrThrow(~partitionId=q.partitionId)

    let pq = {
      fromBlock: q.fromBlock,
      toBlock: q.toBlock,
      isChunk: q.isChunk,
      itemsTarget: q.itemsTarget,
      fetchedBlock: None,
    }

    // Insert in sorted order by fromBlock to maintain queue invariant.
    // Gap-fill queries may have lower fromBlock than existing pending queries.
    let inserted = ref(false)
    let i = ref(0)
    while i.contents < p.mutPendingQueries->Array.length && !inserted.contents {
      if (p.mutPendingQueries->Array.getUnsafe(i.contents)).fromBlock > q.fromBlock {
        p.mutPendingQueries->Array.splice(~start=i.contents, ~remove=0, ~insert=[pq])->ignore
        inserted := true
      }
      i := i.contents + 1
    }
    if !inserted.contents {
      p.mutPendingQueries->Array.push(pq)->ignore
    }
  }
}

// Most parallel in-flight chunk queries a single partition may have at once.
let maxPendingChunksPerPartition = 10

// Fills a gap range (a hole left between completed/pending chunks, e.g. from an
// out-of-order partial response) unconditionally — gaps are already-committed
// range, not subject to this tick's water-fill budget. Priced by the
// partition's trusted density when it has one; otherwise by the "available
// density" — the partition's equal-divide budget spread over its remaining
// range this tick — so a small gap reserves proportionally little instead of a
// noisy one-sample estimate. Chunks only on a trusted POSITIVE density, same
// rule as the water-fill. Returns the created queries' total itemsTarget.
let pushGapFillQueries = (
  queries: array<query>,
  ~partitionId: string,
  ~rangeFromBlock: int,
  ~rangeEndBlock: option<int>,
  ~knownHeight: int,
  ~chainTargetBlock: int,
  ~maybeChunkRange: option<int>,
  ~maxChunks: int,
  ~partition: partition,
  ~partitionBudget: float,
  ~selection: selection,
  ~addressesByContractName: dict<array<Address.t>>,
) => {
  let cost = ref(0.)
  if rangeFromBlock <= knownHeight && maxChunks > 0 {
    switch rangeEndBlock {
    | Some(endBlock) if rangeFromBlock > endBlock => ()
    | _ =>
      let trustedDensity = partition->getTrustedDensity
      let maxBlock = switch rangeEndBlock {
      | Some(eb) => eb
      | None => chainTargetBlock
      }
      let pushSingleQuery = (~density, ~isChunk) => {
        let itemsTarget = densityItemsTarget(
          ~density,
          ~fromBlock=rangeFromBlock,
          ~toBlock=rangeEndBlock,
          ~chainTargetBlock,
        )
        queries->Array.push({
          partitionId,
          fromBlock: rangeFromBlock,
          toBlock: rangeEndBlock,
          selection,
          isChunk,
          itemsTarget,
          addressesByContractName,
        })
        cost := cost.contents +. itemsTarget->Int.toFloat
      }
      switch (trustedDensity, maybeChunkRange) {
      | (Some(density), Some(chunkRange)) if density > 0. =>
        let chunkSize = Js.Math.ceil_int(chunkRange->Int.toFloat *. 1.8)
        if rangeFromBlock + chunkSize * 2 - 1 <= maxBlock {
          let chunkFromBlock = ref(rangeFromBlock)
          let chunkIdx = ref(0)
          while (
            chunkIdx.contents < maxChunks && chunkFromBlock.contents + chunkSize - 1 <= maxBlock
          ) {
            let chunkToBlock = chunkFromBlock.contents + chunkSize - 1
            let itemsTarget = densityItemsTarget(
              ~density,
              ~fromBlock=chunkFromBlock.contents,
              ~toBlock=Some(chunkToBlock),
              ~chainTargetBlock,
            )
            queries->Array.push({
              partitionId,
              fromBlock: chunkFromBlock.contents,
              toBlock: Some(chunkToBlock),
              isChunk: true,
              selection,
              itemsTarget,
              addressesByContractName,
            })
            cost := cost.contents +. itemsTarget->Int.toFloat
            chunkFromBlock := chunkToBlock + 1
            chunkIdx := chunkIdx.contents + 1
          }
        } else {
          // Not enough room for 2 chunks, fall back to a single query
          pushSingleQuery(~density, ~isChunk=rangeEndBlock !== None)
        }
      | (Some(density), _) => pushSingleQuery(~density, ~isChunk=false)
      | (None, _) =>
        let remainingRange = Pervasives.max(1, chainTargetBlock - rangeFromBlock + 1)
        pushSingleQuery(~density=partitionBudget /. remainingRange->Int.toFloat, ~isChunk=false)
      }
    }
  }
  cost.contents
}

// The level every partition ends at when `budget` is poured across partitions
// already holding `footprints`: the unique L with Σ max(0, L - fᵢ) = budget.
// Partitions above L get nothing (their head start is their share); the rest
// are topped up exactly to L, so the pour equals the budget no matter how
// uneven the footprints are.
let waterLevel = (~budget: float, ~footprints: array<float>) => {
  let sorted = footprints->Array.toSorted(Float.compare)
  let n = sorted->Array.length
  let prefix = ref(0.)
  let level = ref(None)
  let idx = ref(0)
  while level.contents == None && idx.contents < n {
    let i = idx.contents
    prefix := prefix.contents +. sorted->Array.getUnsafe(i)
    // The level if only the i+1 lowest footprints receive water — correct once
    // it doesn't reach the next footprint up.
    let candidate = (budget +. prefix.contents) /. (i + 1)->Int.toFloat
    if i == n - 1 || candidate <= sorted->Array.getUnsafe(i + 1) {
      level := Some(candidate)
    }
    idx := idx.contents + 1
  }
  level.contents->Option.getOr(0.)
}

// Per-partition mutable state threaded through the water-fill rounds below.
type waterFillState = {
  partitionId: string,
  p: partition,
  mutable cursor: int,
  mutable chunksUsedThisCall: int,
  // Existing mutPendingQueries count before this call — fixed for the call,
  // used with chunksUsedThisCall against maxPendingChunksPerPartition.
  pendingCount: int,
  queryEndBlock: option<int>,
  maybeChunkRange: option<int>,
  // This partition's own slot in queriesByPartitionIndex — gap-fill and every
  // water-fill round push here directly, so query order falls out of
  // idsInAscOrder for free (see getNextQuery) instead of a final sort pass.
  bucket: array<query>,
}

// Candidate queries are sized against chainTargetBlock, the soft querying
// horizon the owning chain wants to reach this tick — derived by ChainState
// from its share of the indexer-wide buffer budget and its chain-level event
// density. chainTargetBlock is never used as a hard query end, only to (a)
// select which partitions are "in range" this tick and (b) size an open-ended
// query with no other ceiling: the true hard bounds stay
// endBlock/mergeBlock/the lagged head.
//
// In-range partitions share chainTargetItems (this chain's target total
// footprint — in-flight plus new) by water-fill: each round pours exactly the
// remaining fresh budget at the level computed by waterLevel, so a partition
// already holding more than the level (from earlier ticks' in-flight queries)
// gets nothing and its implicit share flows to the others, while totals stay
// even and the pour never exceeds the budget. Rounds repeat only because
// emits are quantized: a partition may consume less than its allotment (range
// or chunk-cap runs out) or slightly more (min one chunk), and the leftover
// re-pours over whoever still has range left.
//
// A partition with a trusted positive density (two or more responses — see
// getMinHistoryRange) always emits at least one full-size chunk/query once
// given an allotment, sized by its real density — may overshoot the
// allotment by at most one chunk (the server also enforces itemsTarget via a
// maxNumLogs-style cap, so an overshoot truncates the response rather than
// the buffer). Any other partition (no signal, one noisy sample, or a
// density-0 estimate) emits one open-ended probe sized exactly at its
// allotment instead.
let getNextQuery = (
  {optimizedPartitions, blockLag, latestOnBlockBlockNumber, knownHeight, endBlock}: t,
  ~chainTargetBlock: int,
  ~chainTargetItems: float,
) => {
  let headBlockNumber = knownHeight - blockLag
  if headBlockNumber <= 0 {
    WaitingForNewBlock
  } else {
    let isOnBlockBehindTheHead = latestOnBlockBlockNumber < headBlockNumber
    let shouldWaitForNewBlock = ref(
      switch endBlock {
      | Some(endBlock) => headBlockNumber < endBlock
      | None => true
      } &&
      !isOnBlockBehindTheHead,
    )

    let partitionsCount = optimizedPartitions.idsInAscOrder->Array.length

    // Every partition is visited once here regardless of whether it gets a
    // query pushed below — waiting-for-new-block bookkeeping shouldn't depend
    // on this tick's budget.
    for idx in 0 to partitionsCount - 1 {
      let partitionId = optimizedPartitions.idsInAscOrder->Array.getUnsafe(idx)
      let p = optimizedPartitions.entities->Dict.getUnsafe(partitionId)
      if (
        p.mutPendingQueries->Array.length > 0 || p.latestFetchedBlock.blockNumber < headBlockNumber
      ) {
        // Even if there are some partitions waiting for the new block
        // We still want to wait for all partitions reaching the head
        // because they might update knownHeight in their response
        // Also, there are cases when some partitions fetching at 50% of the chain
        // and we don't want to poll the head for a few small partitions
        shouldWaitForNewBlock := false
      }
    }

    // One bucket per partition, in idsInAscOrder order — gap-fill and
    // water-fill both push into a partition's own bucket, so flattening at
    // the end (see below) reproduces idsInAscOrder without a sort.
    let queriesByPartitionIndex: array<
      array<query>,
    > = Array.fromInitializer(~length=partitionsCount, _ => [])

    // Compute queryEndBlock for this partition
    let computeQueryEndBlock = (p: partition) => {
      let queryEndBlock = Utils.Math.minOptInt(endBlock, p.mergeBlock)
      switch blockLag {
      | 0 => queryEndBlock
      | _ =>
        // Force head block as an endBlock when blockLag is set
        // because otherwise HyperSync might return bigger range
        Utils.Math.minOptInt(Some(headBlockNumber), queryEndBlock)
      }
    }

    // Each partition's existing in-flight itemsTarget, summed once and reused
    // both for chainReserved (the call-wide fresh-budget ceiling below) and to
    // seed each partition's water-fill footprint — so a partition already
    // holding in-flight queries is counted toward its even share and doesn't
    // get topped up past the others.
    let existingReservedByPartition = Dict.make()
    let chainReserved = ref(0.)
    for idx in 0 to partitionsCount - 1 {
      let partitionId = optimizedPartitions.idsInAscOrder->Array.getUnsafe(idx)
      let p = optimizedPartitions.entities->Dict.getUnsafe(partitionId)
      let cost = ref(0.)
      for pqIdx in 0 to p.mutPendingQueries->Array.length - 1 {
        cost :=
          cost.contents +. (p.mutPendingQueries->Array.getUnsafe(pqIdx)).itemsTarget->Int.toFloat
      }
      existingReservedByPartition->Dict.set(partitionId, cost.contents)
      chainReserved := chainReserved.contents +. cost.contents
    }

    // Phase A: gap-fill. Walk each partition's pending queries once,
    // unconditionally filling any hole (e.g. from an out-of-order partial
    // chunk response) — uncapped, same as before this tick's water-fill was
    // introduced. This also determines each partition's post-gap cursor and
    // whether it's blocked on an unresolved single-shot query.
    let fillStates = []
    let gapFillCost = ref(0.)
    for idx in 0 to partitionsCount - 1 {
      let partitionId = optimizedPartitions.idsInAscOrder->Array.getUnsafe(idx)
      let p = optimizedPartitions.entities->Dict.getUnsafe(partitionId)
      let bucket = queriesByPartitionIndex->Array.getUnsafe(idx)
      let pendingCount = p.mutPendingQueries->Array.length
      let queryEndBlock = computeQueryEndBlock(p)
      let maybeChunkRange = getMinHistoryRange(p)

      let cursor = ref(p.latestFetchedBlock.blockNumber + 1)
      let canContinue = ref(true)
      let chunksUsedThisCall = ref(0)
      let pqIdx = ref(0)
      while pqIdx.contents < pendingCount && canContinue.contents {
        let pq = p.mutPendingQueries->Array.getUnsafe(pqIdx.contents)

        if pq.fromBlock > cursor.contents {
          let beforeLen = bucket->Array.length
          let cost = pushGapFillQueries(
            bucket,
            ~partitionId,
            ~rangeFromBlock=cursor.contents,
            ~rangeEndBlock=Utils.Math.minOptInt(Some(pq.fromBlock - 1), queryEndBlock),
            ~knownHeight,
            ~chainTargetBlock,
            ~maybeChunkRange,
            ~maxChunks=maxPendingChunksPerPartition - pendingCount - chunksUsedThisCall.contents,
            ~partition=p,
            ~partitionBudget=chainTargetItems /. partitionsCount->Int.toFloat,
            ~selection=p.selection,
            ~addressesByContractName=p.addressesByContractName,
          )
          chunksUsedThisCall := chunksUsedThisCall.contents + (bucket->Array.length - beforeLen)
          gapFillCost := gapFillCost.contents +. cost
        }
        switch pq {
        | {isChunk: true, toBlock: Some(toBlock), fetchedBlock: Some({blockNumber})}
          if blockNumber < toBlock =>
          cursor := blockNumber + 1
        | {isChunk: true, toBlock: Some(toBlock)} => cursor := toBlock + 1
        | _ => canContinue := false
        }
        pqIdx := pqIdx.contents + 1
      }

      if canContinue.contents {
        fillStates
        ->Array.push({
          partitionId,
          p,
          cursor: cursor.contents,
          chunksUsedThisCall: chunksUsedThisCall.contents,
          pendingCount,
          queryEndBlock,
          maybeChunkRange,
          bucket,
        })
        ->ignore
      }
    }

    // Fresh budget for this call — what's left of chainTargetItems after
    // existing in-flight queries and this tick's gap-fill. The water-fill
    // rounds below hand it out; a partition already holding a large share
    // (seeded below) gets proportionally less so totals stay even.
    let rangeItemsTarget = Pervasives.max(
      0.,
      chainTargetItems -. chainReserved.contents -. gapFillCost.contents,
    )

    // Each in-range partition's running footprint: existing in-flight plus any
    // gap-fill just pushed into its bucket. The water-fill levels every
    // partition up toward a shared line, so this seed is what a partition
    // starts the fill already holding.
    let reservedByPartition = Dict.make()
    fillStates->Array.forEach(fs => {
      let cost = ref(existingReservedByPartition->Dict.getUnsafe(fs.partitionId))
      for i in 0 to fs.bucket->Array.length - 1 {
        cost := cost.contents +. (fs.bucket->Array.getUnsafe(i)).itemsTarget->Int.toFloat
      }
      reservedByPartition->Dict.set(fs.partitionId, cost.contents)
    })

    let isInRange = (fs: waterFillState) =>
      fs.cursor <= chainTargetBlock &&
      switch fs.queryEndBlock {
      | Some(eb) => fs.cursor <= eb
      | None => true
      } &&
      fs.pendingCount + fs.chunksUsedThisCall < maxPendingChunksPerPartition

    let inRangeStates = fillStates->Array.filter(isInRange)

    // Emits this round's queries for one partition, given its water-fill
    // allotment. Mutates fs.cursor/chunksUsedThisCall and returns the
    // itemsTarget consumed.
    //
    // Chunks require a POSITIVE trusted density: density 0 prices every chunk
    // at ~nothing, letting a partition flood its full chunk pipeline with
    // hard-bounded queries that crawl 1.8× per two responses — an open-ended
    // probe instead gets the server's full scan range in one response.
    let emitQueries = (fs: waterFillState, ~budget: float) => {
      let p = fs.p
      let maxBlock = switch fs.queryEndBlock {
      | Some(eb) => eb
      | None => chainTargetBlock
      }
      switch (fs.maybeChunkRange, p->getTrustedDensity) {
      | (Some(minHistoryRange), Some(density)) if density > 0. =>
        // Chunking active: strict chunks with a hard endBlock, uncapped real
        // density — at least one full chunk this round even if budget falls
        // short.
        let chunkSize = Js.Math.ceil_int(minHistoryRange->Int.toFloat *. 1.8)
        let chunkCost = density *. chunkSize->Int.toFloat
        let maxChunksRemaining =
          maxPendingChunksPerPartition - fs.pendingCount - fs.chunksUsedThisCall
        let affordable = Math.floor(budget /. chunkCost)->Float.toInt
        let numChunks = Pervasives.max(1, Pervasives.min(affordable, maxChunksRemaining))
        let consumed = ref(0.)
        let created = ref(0)
        let chunkFromBlock = ref(fs.cursor)
        while created.contents < numChunks && chunkFromBlock.contents <= maxBlock {
          let chunkToBlock = Pervasives.min(chunkFromBlock.contents + chunkSize - 1, maxBlock)
          let itemsTarget = Pervasives.max(
            1,
            (density *. (chunkToBlock - chunkFromBlock.contents + 1)->Int.toFloat)
            ->Math.ceil
            ->Float.toInt,
          )
          fs.bucket->Array.push({
            partitionId: fs.partitionId,
            fromBlock: chunkFromBlock.contents,
            toBlock: Some(chunkToBlock),
            isChunk: true,
            selection: p.selection,
            itemsTarget,
            addressesByContractName: p.addressesByContractName,
          })
          consumed := consumed.contents +. itemsTarget->Int.toFloat
          chunkFromBlock := chunkToBlock + 1
          created := created.contents + 1
        }
        fs.cursor = chunkFromBlock.contents
        fs.chunksUsedThisCall = fs.chunksUsedThisCall + created.contents
        consumed.contents
      | _ =>
        let itemsTarget = Pervasives.max(1, Math.round(budget)->Float.toInt)
        fs.bucket->Array.push({
          partitionId: fs.partitionId,
          fromBlock: fs.cursor,
          toBlock: fs.queryEndBlock,
          isChunk: false,
          selection: p.selection,
          itemsTarget,
          addressesByContractName: p.addressesByContractName,
        })
        fs.cursor = maxBlock + 1
        fs.chunksUsedThisCall = fs.chunksUsedThisCall + 1
        itemsTarget->Int.toFloat
      }
    }

    // Water-fill. Range membership is fixed by chainTargetBlock/queryEndBlock,
    // so the in-range partitions are filtered once up front; each round pours
    // the remaining fresh budget at the waterLevel of the still-not-filled
    // partitions' footprints and keeps only those still in range for the next
    // round. Allotments sum to exactly the poured budget, so the outcome is
    // order-independent and never exceeds it — the only overshoot left is the
    // min-one-chunk quantization in emitQueries, bounded by one chunk per
    // partition per round.
    //
    // No explicit round cap: a partition survives a round only by advancing
    // chunksUsedThisCall (capped at maxPendingChunksPerPartition) or by
    // consuming fresh budget (every emit consumes at least 1), so the
    // not-filled set drains on its own and the loop also stops once the whole
    // budget is poured.
    let notFilledPartitions = ref(inRangeStates)
    let remainingBudget = ref(rangeItemsTarget)
    while notFilledPartitions.contents->Array.length > 0 && remainingBudget.contents > 0. {
      let level = waterLevel(
        ~budget=remainingBudget.contents,
        ~footprints=notFilledPartitions.contents->Array.map(fs =>
          reservedByPartition->Dict.getUnsafe(fs.partitionId)
        ),
      )
      let next = []
      notFilledPartitions.contents->Array.forEach(fs => {
        let reserved = reservedByPartition->Dict.getUnsafe(fs.partitionId)
        let budget = level -. reserved
        if budget > 0. {
          let consumed = emitQueries(fs, ~budget)
          reservedByPartition->Dict.set(fs.partitionId, reserved +. consumed)
          remainingBudget := remainingBudget.contents -. consumed
          if fs->isInRange {
            next->Array.push(fs)->ignore
          }
        }
      })
      notFilledPartitions := next
    }

    // Each partition pushed only into its own bucket (indexed by its
    // idsInAscOrder position), so flattening reproduces idsInAscOrder order
    // directly — no sort needed even though water-fill rounds interleave
    // across partitions.
    let queries = queriesByPartitionIndex->Array.flat

    if queries->Utils.Array.isEmpty {
      if shouldWaitForNewBlock.contents {
        WaitingForNewBlock
      } else {
        NothingToQuery
      }
    } else {
      Ready(queries)
    }
  }
}

let hasReadyItem = ({buffer} as fetchState: t) => {
  switch buffer->Array.get(0) {
  | Some(item) => item->Internal.getItemBlockNumber <= fetchState->bufferBlockNumber
  | None => false
  }
}

let getReadyItemsCount = (fetchState: t, ~targetSize: int, ~fromItem) => {
  let readyBlockNumber = ref(fetchState->bufferBlockNumber)
  let acc = ref(0)
  let isFinished = ref(false)
  while !isFinished.contents {
    switch fetchState.buffer->Array.get(fromItem + acc.contents) {
    | Some(item) =>
      let itemBlockNumber = item->Internal.getItemBlockNumber
      if itemBlockNumber <= readyBlockNumber.contents {
        acc := acc.contents + 1
        if acc.contents === targetSize {
          // Should finish accumulating items from the same block
          readyBlockNumber := itemBlockNumber
        }
      } else {
        isFinished := true
      }
    | None => isFinished := true
    }
  }
  acc.contents
}

/**
Instantiates a fetch state with partitions for initial addresses
*/
let make = (
  ~startBlock,
  ~endBlock,
  ~onEventRegistrations: array<Internal.onEventRegistration>,
  ~contractConfigs: dict<IndexingAddresses.contractConfig>,
  ~addresses: array<Internal.indexingAddress>,
  ~maxAddrInPartition,
  ~chainId,
  ~maxOnBlockBufferSize,
  ~knownHeight,
  ~progressBlockNumber=startBlock - 1,
  ~onBlockRegistrations=[],
  ~blockLag=0,
  ~firstEventBlock=None,
): t => {
  let latestFetchedBlock = {
    blockTimestamp: 0,
    blockNumber: progressBlockNumber,
  }

  let notDependingOnAddresses = []
  let normalRegistrations = []
  let contractNamesWithNormalEvents = Utils.Set.make()

  onEventRegistrations->Array.forEach(reg => {
    if reg.dependsOnAddresses {
      normalRegistrations->Array.push(reg)
      contractNamesWithNormalEvents->Utils.Set.add(reg.eventConfig.contractName)->ignore
    } else {
      notDependingOnAddresses->Array.push(reg)
    }
  })

  let partitions = []

  if notDependingOnAddresses->Array.length > 0 {
    partitions->Array.push({
      id: partitions->Array.length->Int.toString,
      latestFetchedBlock,
      selection: {
        dependsOnAddresses: false,
        onEventRegistrations: notDependingOnAddresses,
      },
      addressesByContractName: Dict.make(),
      mergeBlock: None,
      dynamicContract: None,
      mutPendingQueries: [],
      prevQueryRange: 0,
      prevPrevQueryRange: 0,
      prevRangeSize: 0,
      latestBlockRangeUpdateBlock: 0,
    })
  }

  let normalSelection = {
    dependsOnAddresses: true,
    onEventRegistrations: normalRegistrations,
  }

  let registeringContractsByContract: dict<dict<indexingAddress>> = Dict.make()
  let dynamicContracts = Utils.Set.make()

  addresses->Array.forEach(contract => {
    let contractName = contract.contractName

    // Only addresses whose contract has events that depend on addresses get
    // registered for active fetching via partitions.
    if contractNamesWithNormalEvents->Utils.Set.has(contractName) {
      registeringContractsByContract
      ->Utils.Dict.getOrInsertEmptyDict(contractName)
      ->Dict.set(
        contract.address->Address.toString,
        IndexingAddresses.makeIndexingAddress(~contract, ~contractConfigs),
      )

      // Detect dynamic contracts by registrationBlock
      if contract.registrationBlock !== -1 {
        dynamicContracts->Utils.Set.add(contractName)->ignore
      }
    }
  })

  let optimizedPartitions = createPartitionsFromIndexingAddresses(
    ~registeringContractsByContract,
    ~dynamicContracts,
    ~normalSelection,
    ~maxAddrInPartition,
    ~nextPartitionIndex=partitions->Array.length,
    ~existingPartitions=partitions, // wildcard partition(s) if any
    ~progressBlockNumber,
  )

  if (
    optimizedPartitions->OptimizedPartitions.count === 0 &&
      onBlockRegistrations->Utils.Array.isEmpty
  ) {
    JsError.throwWithMessage(
      `Invalid configuration: Nothing to fetch on chain ${chainId->Int.toString}. ` ++
      `addresses=${addresses->Array.length->Int.toString}, ` ++
      `onEventRegistrations=${onEventRegistrations->Array.length->Int.toString}, ` ++
      `normalRegistrations=${normalRegistrations
        ->Array.length
        ->Int.toString}. ` ++ `Make sure that you provided at least one contract address to index, or have events with Wildcard mode enabled, or have onBlock handlers.`,
    )
  }

  // On resume knownHeight is restored from the DB but the buffer starts empty.
  // For onBlock-only indexers (e.g. SVM onSlot) there are no partitions to drive
  // fetching, so without seeding the buffer here getNextQuery would return
  // NothingToQuery and the indexer would get stuck.
  let buffer = []
  let latestOnBlockBlockNumber = if knownHeight > 0 && onBlockRegistrations->Utils.Array.notEmpty {
    let maxBlockNumber = switch optimizedPartitions->OptimizedPartitions.getLatestFullyFetchedBlock {
    | None => knownHeight
    | Some(latestFullyFetchedBlock) => latestFullyFetchedBlock.blockNumber
    }
    appendOnBlockItems(
      ~mutItems=buffer,
      ~onBlockRegistrations,
      ~indexerStartBlock=startBlock,
      ~fromBlock=progressBlockNumber,
      ~maxBlockNumber,
      ~maxOnBlockBufferSize,
    )
  } else {
    progressBlockNumber
  }

  let fetchState = {
    optimizedPartitions,
    contractConfigs,
    chainId,
    startBlock,
    endBlock,
    latestOnBlockBlockNumber,
    normalSelection,
    blockLag,
    onBlockRegistrations,
    maxOnBlockBufferSize,
    knownHeight,
    buffer,
    firstEventBlock,
  }

  Prometheus.IndexingPartitions.set(
    ~partitionsCount=optimizedPartitions->OptimizedPartitions.count,
    ~chainId,
  )
  Prometheus.IndexingBufferSize.set(~bufferSize=buffer->Array.length, ~chainId)
  Prometheus.IndexingBufferBlockNumber.set(~blockNumber=fetchState->bufferBlockNumber, ~chainId)
  switch endBlock {
  | Some(endBlock) => Prometheus.IndexingEndBlock.set(~endBlock, ~chainId)
  | None => ()
  }

  fetchState
}

let bufferSize = ({buffer}: t) => buffer->Array.length

let rollbackPendingQueries = (mutPendingQueries: array<pendingQuery>, ~targetBlockNumber) => {
  // - Remove queries where fromBlock > target
  // - Cap fetchedBlock at target where fetchedBlock > target
  let adjusted = []
  for qIdx in 0 to mutPendingQueries->Array.length - 1 {
    let pq = mutPendingQueries->Array.getUnsafe(qIdx)
    if pq.fromBlock <= targetBlockNumber {
      switch pq.fetchedBlock {
      | Some({blockNumber}) if blockNumber > targetBlockNumber =>
        adjusted
        ->Array.push({
          ...pq,
          fetchedBlock: Some({blockNumber: targetBlockNumber, blockTimestamp: 0}),
        })
        ->ignore
      | Some(_) => adjusted->Array.push(pq)->ignore
      | None =>
        JsError.throwWithMessage("Internal error: Must not have a fetching query during rollback")
      }
    }
  }
  adjusted
}

/**
Rolls back fetch state to the given valid block.
Always recreates optimized partitions to avoid duplicate addresses:
- Wildcard: only rollback latestFetchedBlock
- Non-wildcard with lfb <= target: keep, adjust pending queries and mergeBlock
- Non-wildcard with lfb > target: delete, track addresses for recreation
*/
let rollback = (fetchState: t, ~indexingAddresses: IndexingAddresses.t, ~targetBlockNumber) => {
  // Step 1: Prune addresses registered after the target block. The pruned index is
  // then the source of truth for partition cleanup below — an address survives iff
  // it's still in the index.
  indexingAddresses->IndexingAddresses.rollbackInPlace(~targetBlockNumber)

  // Step 2: Categorize partitions
  let keptPartitions = []
  let nextKeptIdRef = ref(0)
  let registeringContractsByContract: dict<dict<indexingAddress>> = Dict.make()

  let partitions = fetchState.optimizedPartitions.entities->Dict.valuesToArray
  for idx in 0 to partitions->Array.length - 1 {
    let p = partitions->Array.getUnsafe(idx)
    switch p {
    // Wildcard: rollback latestFetchedBlock and adjust pending queries
    | {selection: {dependsOnAddresses: false}} =>
      let id = nextKeptIdRef.contents->Int.toString
      nextKeptIdRef := nextKeptIdRef.contents + 1
      keptPartitions
      ->Array.push({
        ...p,
        id,
        latestFetchedBlock: p.latestFetchedBlock.blockNumber > targetBlockNumber
          ? {blockNumber: targetBlockNumber, blockTimestamp: 0}
          : p.latestFetchedBlock,
        mutPendingQueries: rollbackPendingQueries(p.mutPendingQueries, ~targetBlockNumber),
      })
      ->ignore

    // Non-wildcard with lfb > target: delete, collect addresses for recreation
    | _ if p.latestFetchedBlock.blockNumber > targetBlockNumber =>
      p.addressesByContractName->Utils.Dict.forEachWithKey((addresses, contractName) => {
        addresses->Array.forEach(address => {
          switch indexingAddresses->IndexingAddresses.get(address->Address.toString) {
          | Some(indexingContract) =>
            let registeringContracts =
              registeringContractsByContract->Utils.Dict.getOrInsertEmptyDict(contractName)
            registeringContracts->Dict.set(address->Address.toString, indexingContract)
          | None => ()
          }
        })
      })

    // Non-wildcard with lfb <= target: keep, adjust pending queries and mergeBlock
    | {addressesByContractName} => {
        // Cap mergeBlock at target
        let mergeBlock = switch p.mergeBlock {
        | Some(mergeBlock) if mergeBlock > targetBlockNumber => Some(targetBlockNumber)
        | other => other
        }

        // Drop addresses pruned from the index
        let rollbackedAddressesByContractName = Dict.make()
        addressesByContractName->Utils.Dict.forEachWithKey((addresses, contractName) => {
          let keptAddresses =
            addresses->Array.filter(address =>
              indexingAddresses->IndexingAddresses.get(address->Address.toString)->Option.isSome
            )
          if keptAddresses->Array.length > 0 {
            rollbackedAddressesByContractName->Dict.set(contractName, keptAddresses)
          }
        })

        if !(rollbackedAddressesByContractName->Utils.Dict.isEmpty) {
          let id = nextKeptIdRef.contents->Int.toString
          nextKeptIdRef := nextKeptIdRef.contents + 1
          keptPartitions
          ->Array.push({
            ...p,
            id,
            addressesByContractName: rollbackedAddressesByContractName,
            mutPendingQueries: rollbackPendingQueries(p.mutPendingQueries, ~targetBlockNumber),
            mergeBlock,
          })
          ->ignore
        }
      }
    }
  }

  // Step 3: Recreate partitions from deleted partition addresses
  let optimizedPartitions = createPartitionsFromIndexingAddresses(
    ~registeringContractsByContract,
    ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
    ~normalSelection=fetchState.normalSelection,
    ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
    ~nextPartitionIndex=nextKeptIdRef.contents,
    ~existingPartitions=keptPartitions,
    ~progressBlockNumber=targetBlockNumber,
  )

  // Step 4: Update state
  {
    ...fetchState,
    // TODO: Test this. Currently it's not tested.
    latestOnBlockBlockNumber: Pervasives.min(
      fetchState.latestOnBlockBlockNumber,
      targetBlockNumber,
    ),
  }->updateInternal(
    ~optimizedPartitions,
    ~mutItems=fetchState.buffer->Array.filter(item =>
      switch item {
      | Event({blockNumber})
      | Block({blockNumber}) => blockNumber
      } <=
      targetBlockNumber
    ),
  )
}

// Reset pending queries by removing in-flight queries (ones without fetchedBlock).
// Completed queries (with fetchedBlock) are kept so rollback can handle them.
// Since we can continue fetching partitions with holes, this works correctly.
let resetPendingQueries = (fetchState: t) => {
  let newEntities = fetchState.optimizedPartitions.entities->Utils.Dict.shallowCopy

  for idx in 0 to fetchState.optimizedPartitions.idsInAscOrder->Array.length - 1 {
    let partitionId = fetchState.optimizedPartitions.idsInAscOrder->Array.getUnsafe(idx)
    let partition = fetchState.optimizedPartitions.entities->Dict.getUnsafe(partitionId)

    if partition.mutPendingQueries->Array.length > 0 {
      // Keep only completed queries (with fetchedBlock)
      let kept = partition.mutPendingQueries->Array.filter(pq => pq.fetchedBlock !== None)
      newEntities->Dict.set(partitionId, {...partition, mutPendingQueries: kept})
    }
  }

  {
    ...fetchState,
    optimizedPartitions: {
      ...fetchState.optimizedPartitions,
      entities: newEntities,
    },
  }
}

/**
* Returns a boolean indicating whether the fetch state is actively indexing
* used for comparing event queues in the chain manager
*/
let isActivelyIndexing = ({endBlock} as fetchState: t) => {
  switch endBlock {
  | Some(endBlock) =>
    let isPastEndblock = fetchState->bufferBlockNumber >= endBlock
    if isPastEndblock {
      fetchState->bufferSize > 0
    } else {
      true
    }
  | None => true
  }
}

// True once the fetch frontier has reached the (lagged) head or endBlock,
// regardless of whether the buffer has been consumed yet. Unlike
// isReadyToEnterReorgThreshold, fetched-but-unprocessed items still count.
let isFetchingAtHead = ({endBlock, blockLag, knownHeight} as fetchState: t) => {
  let bufferBlockNumber = fetchState->bufferBlockNumber
  knownHeight !== 0 &&
    switch endBlock {
    | Some(endBlock) if bufferBlockNumber >= endBlock => true
    | _ => bufferBlockNumber >= knownHeight - blockLag
    }
}

let isReadyToEnterReorgThreshold = ({endBlock, blockLag, buffer, knownHeight} as fetchState: t) => {
  let bufferBlockNumber = fetchState->bufferBlockNumber
  knownHeight !== 0 &&
  switch endBlock {
  | Some(endBlock) if bufferBlockNumber >= endBlock => true
  | _ => bufferBlockNumber >= knownHeight - blockLag
  } &&
  buffer->Utils.Array.isEmpty
}

// Lower progress percentage = further behind = higher priority. Shared by the
// batch ordering and the cross-chain fetch priority.
let getProgressPercentage = (fetchState: t) => {
  switch fetchState.firstEventBlock {
  | None => 0.
  | Some(firstEventBlock) =>
    let totalRange = fetchState.knownHeight - firstEventBlock
    if totalRange <= 0 {
      0.
    } else {
      let progress = switch fetchState.buffer->Array.get(0) {
      | Some(item) => item->Internal.getItemBlockNumber - firstEventBlock
      | None => fetchState->bufferBlockNumber - firstEventBlock
      }
      progress->Int.toFloat /. totalRange->Int.toFloat
    }
  }
}

let sortForBatch = {
  let hasFullBatch = ({buffer} as fetchState: t, ~batchSizeTarget) => {
    switch buffer->Array.get(batchSizeTarget - 1) {
    | Some(item) => item->Internal.getItemBlockNumber <= fetchState->bufferBlockNumber
    | None => false
    }
  }

  (fetchStates: array<t>, ~batchSizeTarget: int) => {
    let copied = fetchStates->Array.copy
    copied->Array.sort((a: t, b: t) => {
      switch (a->hasFullBatch(~batchSizeTarget), b->hasFullBatch(~batchSizeTarget)) {
      | (true, true)
      | (false, false) => {
          let aProgress = a->getProgressPercentage
          let bProgress = b->getProgressPercentage
          if aProgress < bProgress {
            Ordering.less
          } else if aProgress > bProgress {
            Ordering.greater
          } else {
            Ordering.equal
          }
        }
      | (true, false) => Ordering.less
      | (false, true) => Ordering.greater
      }
    })
    copied
  }
}

let getProgressBlockNumberAt = ({buffer} as fetchState: t, ~index) => {
  let bufferBlockNumber = fetchState->bufferBlockNumber
  switch buffer->Array.get(index) {
  | Some(item) if bufferBlockNumber >= item->Internal.getItemBlockNumber =>
    item->Internal.getItemBlockNumber - 1
  | _ => bufferBlockNumber
  }
}

let updateKnownHeight = (fetchState: t, ~knownHeight) => {
  if knownHeight > fetchState.knownHeight {
    Prometheus.IndexingKnownHeight.set(~blockNumber=knownHeight, ~chainId=fetchState.chainId)
    fetchState->updateInternal(~knownHeight)
  } else {
    fetchState
  }
}
