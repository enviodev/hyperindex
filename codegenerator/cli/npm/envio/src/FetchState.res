open Belt

type contractConfig = {filterByAddresses: bool}

type blockNumberAndTimestamp = {
  blockNumber: int,
  blockTimestamp: int,
}

type blockNumberAndLogIndex = {blockNumber: int, logIndex: int}

type selection = {eventConfigs: array<Internal.eventConfig>, dependsOnAddresses: bool}

type pendingQuery = {
  fromBlock: int,
  toBlock: option<int>,
  isChunk: bool,
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
  endBlock: option<int>,
  // When set, partition indexes a single dynamic contract type.
  // The addressesByContractName must contain only addresses for this contract.
  dynamicContract: option<string>,
  // Mutable array for SourceManager sync - queries exist only while being fetched
  mutPendingQueries: array<pendingQuery>,
  // Track last 3 successful query ranges for chunking heuristic (0 means no data)
  prevQueryRange: int,
  prevPrevQueryRange: int,
}

type query = {
  partitionId: string,
  fromBlock: int,
  toBlock: option<int>,
  isChunk: bool,
  selection: selection,
  addressesByContractName: dict<array<Address.t>>,
  indexingContracts: dict<Internal.indexingContract>,
}

// Calculate the chunk range from history using min-of-last-3-ranges heuristic
let getMinHistoryRange = (p: partition) => {
  switch (p.prevQueryRange, p.prevPrevQueryRange) {
  | (0, _) | (_, 0) => None
  | (a, b) => Some(a < b ? a : b)
  }
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
    switch optimizedPartitions.entities->Js.Dict.get(partitionId) {
    | Some(p) => p
    | None => Js.Exn.raiseError(`Unexpected case: Couldn't find partition ${partitionId}`)
    }
  }

  // Merges two partitions at a given mergeBlock.
  // Returns array<partition> where the last element is the continuing partition
  // and all preceding elements are completed (have endBlock set).
  // Handles address overflow splitting inline.
  let mergePartitionsAtBlock = (
    ~p1: partition,
    ~p2: partition,
    ~mergeBlock: int,
    ~contractName: string,
    ~maxAddrInPartition: int,
    ~nextPartitionIndexRef: ref<int>,
  ) => {
    let combinedAddresses =
      p1.addressesByContractName
      ->Js.Dict.unsafeGet(contractName)
      ->Js.Array2.concat(p2.addressesByContractName->Js.Dict.unsafeGet(contractName))

    let p1Below = p1.latestFetchedBlock.blockNumber < mergeBlock
    let p2Below = p2.latestFetchedBlock.blockNumber < mergeBlock

    // Build the continuing partition (at mergeBlock with combined addresses),
    // collecting completed partitions (with endBlock) along the way
    let completed = []
    let continuingBase = switch (p1Below, p2Below) {
    | (false, false) => p1
    | (false, true) =>
      completed->Js.Array2.push({...p2, endBlock: Some(mergeBlock)})->ignore
      p1
    | (true, false) =>
      completed->Js.Array2.push({...p1, endBlock: Some(mergeBlock)})->ignore
      p2
    | (true, true) =>
      completed->Js.Array2.push({...p1, endBlock: Some(mergeBlock)})->ignore
      completed->Js.Array2.push({...p2, endBlock: Some(mergeBlock)})->ignore
      let newId = nextPartitionIndexRef.contents->Js.Int.toString
      nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
      {
        id: newId,
        dynamicContract: Some(contractName),
        selection: p1.selection,
        latestFetchedBlock: {blockNumber: mergeBlock, blockTimestamp: 0},
        endBlock: None,
        addressesByContractName: Js.Dict.empty(), // set below
        mutPendingQueries: [],
        prevQueryRange: 0,
        prevPrevQueryRange: 0,
      }
    }

    // Apply address split on the continuing partition
    if combinedAddresses->Js.Array2.length > maxAddrInPartition {
      let addressesFull = combinedAddresses->Js.Array2.slice(~start=0, ~end_=maxAddrInPartition)
      let addressesRest = combinedAddresses->Js.Array2.sliceFrom(maxAddrInPartition)
      let abcFull = Js.Dict.empty()
      abcFull->Js.Dict.set(contractName, addressesFull)
      let abcRest = Js.Dict.empty()
      abcRest->Js.Dict.set(contractName, addressesRest)
      completed->Js.Array2.push({...continuingBase, addressesByContractName: abcFull})->ignore
      let restId = nextPartitionIndexRef.contents->Js.Int.toString
      nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
      completed
      ->Js.Array2.push({
        ...continuingBase,
        id: restId,
        addressesByContractName: abcRest,
        mutPendingQueries: [],
      })
      ->ignore
      completed
    } else {
      let abc = Js.Dict.empty()
      abc->Js.Dict.set(contractName, combinedAddresses)
      completed->Js.Array2.push({...continuingBase, addressesByContractName: abc})->ignore
      completed
    }
  }

  // Random number from my head
  // Not super critical if it's too big or too small
  // We optimize for fastest data which we get in any case.
  // If the value is off, it'll only result in
  // quering the same block range multiple times
  let tooFarBlockRange = 20_000

  let ascSortFn = (a, b) => a.latestFetchedBlock.blockNumber - b.latestFetchedBlock.blockNumber

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
    let mergingPartitions = Js.Dict.empty()
    let nextPartitionIndexRef = ref(nextPartitionIndex)

    for idx in 0 to partitions->Array.length - 1 {
      let p = partitions->Js.Array2.unsafe_get(idx)
      switch p {
      // Since it's not a dynamic contract partition,
      // there's no need for merge logic
      | {dynamicContract: None}
      | // Wildcard doesn't need merging
      {selection: {dependsOnAddresses: false}}
      | // For now don't merge partitions with endBlock,
      // assuming they are already merged,
      // TODO: Although there might be cases with too far away endBlock,
      // which is worth merging
      {endBlock: Some(_)} =>
        newPartitions->Js.Array2.push(p)->ignore
      | {dynamicContract: Some(contractName)} =>
        let pAddressesCount =
          p.addressesByContractName->Js.Dict.unsafeGet(contractName)->Js.Array2.length
        // Compute merge block: last pending query's toBlock, or lfb if idle
        let mergeBlock = switch p.mutPendingQueries->Utils.Array.last {
        | Some({isChunk: true, toBlock: Some(toBlock)}) => Some(toBlock)
        | Some(_) => None // unbounded query -- can't merge
        | None => Some(p.latestFetchedBlock.blockNumber)
        }
        switch mergeBlock {
        | None => newPartitions->Js.Array2.push(p)->ignore
        | Some(mergeBlock) =>
          if pAddressesCount >= maxAddrInPartition {
            newPartitions->Js.Array2.push(p)->ignore
          } else {
            let partitionsByMergeBlock =
              mergingPartitions->Utils.Dict.getOrInsertEmptyDict(contractName)
            switch partitionsByMergeBlock->Utils.Dict.dangerouslyGetByIntNonOption(mergeBlock) {
            | Some(existingPartition) =>
              let result = mergePartitionsAtBlock(
                ~p1=existingPartition,
                ~p2=p,
                ~mergeBlock,
                ~contractName,
                ~maxAddrInPartition,
                ~nextPartitionIndexRef,
              )
              for i in 0 to result->Array.length - 2 {
                newPartitions->Js.Array2.push(result->Js.Array2.unsafe_get(i))->ignore
              }
              partitionsByMergeBlock->Utils.Dict.setByInt(
                mergeBlock,
                result->Utils.Array.lastUnsafe,
              )
            | None => partitionsByMergeBlock->Utils.Dict.setByInt(mergeBlock, p)
            }
          }
        }
      }
    }

    let merginDynamicContracts = mergingPartitions->Js.Dict.keys
    for idx in 0 to merginDynamicContracts->Array.length - 1 {
      let contractName = merginDynamicContracts->Js.Array2.unsafe_get(idx)
      let partitionsByMergeBlock = mergingPartitions->Js.Dict.unsafeGet(contractName)
      // JS engine automatically sorts number keys in objects
      let ascPartitionKeys = partitionsByMergeBlock->Js.Dict.keys

      // But -1 is placed last...
      if ascPartitionKeys->Js.Array2.unsafe_get(ascPartitionKeys->Array.length - 1) === "-1" {
        ascPartitionKeys
        ->Js.Array2.unshift(ascPartitionKeys->Js.Array2.pop->Option.getUnsafe)
        ->ignore
      }
      let currentPRef = ref(
        partitionsByMergeBlock->Js.Dict.unsafeGet(ascPartitionKeys->Utils.Array.firstUnsafe),
      )
      let currentPMergeBlockRef = ref(
        ascPartitionKeys->Utils.Array.firstUnsafe->Int.fromString->Option.getUnsafe,
      )
      let nextJdx = ref(1)
      while nextJdx.contents < ascPartitionKeys->Array.length {
        let nextKey = ascPartitionKeys->Js.Array2.unsafe_get(nextJdx.contents)
        let currentP = currentPRef.contents
        let nextP = partitionsByMergeBlock->Js.Dict.unsafeGet(nextKey)
        let nextPMergeBlock = nextKey->Int.fromString->Option.getUnsafe
        let currentPMergeBlock = currentPMergeBlockRef.contents

        let isTooFar = currentPMergeBlock + tooFarBlockRange < nextPMergeBlock
        if isTooFar {
          newPartitions->Js.Array2.push(currentP)->ignore
          currentPRef := nextP
          currentPMergeBlockRef := nextPMergeBlock
        } else {
          let result = mergePartitionsAtBlock(
            ~p1=nextP,
            ~p2=currentP,
            ~mergeBlock=nextPMergeBlock,
            ~contractName,
            ~maxAddrInPartition,
            ~nextPartitionIndexRef,
          )
          for i in 0 to result->Array.length - 2 {
            newPartitions->Js.Array2.push(result->Js.Array2.unsafe_get(i))->ignore
          }
          currentPRef := result->Utils.Array.lastUnsafe
          currentPMergeBlockRef := nextPMergeBlock
        }

        nextJdx := nextJdx.contents + 1
      }

      newPartitions->Js.Array2.push(currentPRef.contents)->ignore
    }

    // Sort partitions by latestFetchedBlock ascending
    let _ = newPartitions->Js.Array2.sortInPlaceWith(ascSortFn)

    let partitionsCount = newPartitions->Array.length
    let idsInAscOrder = Belt.Array.makeUninitializedUnsafe(partitionsCount)
    let entities = Js.Dict.empty()
    for idx in 0 to partitionsCount - 1 {
      let p = newPartitions->Js.Array2.unsafe_get(idx)
      idsInAscOrder->Js.Array2.unsafe_set(idx, p.id)
      entities->Js.Dict.set(p.id, p)
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
      let removedQuery = mutPendingQueries->Js.Array2.shift->Option.getUnsafe
      latestFetchedBlock := removedQuery.fetchedBlock->Option.getUnsafe
    }

    latestFetchedBlock.contents
  }

  let getPendingQueryOrThrow = (p: partition, ~fromBlock) => {
    let idxRef = ref(0)
    let pendingQueryRef = ref(None)
    while idxRef.contents < p.mutPendingQueries->Array.length && pendingQueryRef.contents === None {
      let pq = p.mutPendingQueries->Js.Array2.unsafe_get(idxRef.contents)
      if pq.fromBlock === fromBlock {
        pendingQueryRef := Some(pq)
      }
      idxRef := idxRef.contents + 1
    }
    switch pendingQueryRef.contents {
    | Some(pq) => pq
    | None =>
      Js.Exn.raiseError(
        `Pending query not found for partition ${p.id} fromBlock ${fromBlock->Int.toString}`,
      )
    }
  }

  let handleQueryResponse = (
    optimizedPartitions: t,
    ~query,
    ~knownHeight,
    ~latestFetchedBlock: blockNumberAndTimestamp,
  ) => {
    let p = optimizedPartitions->getOrThrow(~partitionId=query.partitionId)
    let mutEntities = optimizedPartitions.entities->Utils.Dict.shallowCopy

    // Mark query as fetched
    let pendingQuery = getPendingQueryOrThrow(p, ~fromBlock=query.fromBlock)
    pendingQuery.fetchedBlock = Some(latestFetchedBlock)

    let blockRange = latestFetchedBlock.blockNumber - query.fromBlock + 1
    let shouldUpdateBlockRange = switch query.toBlock {
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

    // Process fetched queries from front of queue for main partition
    let updatedLatestFetchedBlock = consumeFetchedQueries(
      p.mutPendingQueries,
      ~initialLatestFetchedBlock=p.latestFetchedBlock,
    )

    // Check if partition reached its endBlock and should be removed
    let partitionReachedEndBlock = switch p.endBlock {
    | Some(endBlock) => updatedLatestFetchedBlock.blockNumber >= endBlock
    | None => false
    }

    if partitionReachedEndBlock {
      mutEntities->Utils.Dict.deleteInPlace(p.id)
    } else {
      let updatedMainPartition = {
        ...p,
        latestFetchedBlock: updatedLatestFetchedBlock,
        prevQueryRange: updatedPrevQueryRange,
        prevPrevQueryRange: updatedPrevPrevQueryRange,
      }

      mutEntities->Js.Dict.set(p.id, updatedMainPartition)
    }

    // Re-optimize to maintain sorted order and apply optimizations
    make(
      ~partitions=mutEntities->Js.Dict.values,
      ~maxAddrInPartition=optimizedPartitions.maxAddrInPartition,
      ~nextPartitionIndex=optimizedPartitions.nextPartitionIndex,
      ~dynamicContracts=optimizedPartitions.dynamicContracts,
    )
  }

  @inline
  let getLatestFullyFetchedBlock = (optimizedPartitions: t) => {
    switch optimizedPartitions.idsInAscOrder->Array.get(0) {
    | Some(id) => Some((optimizedPartitions.entities->Js.Dict.unsafeGet(id)).latestFetchedBlock)
    | None => None
    }
  }
}

type t = {
  optimizedPartitions: OptimizedPartitions.t,
  startBlock: int,
  endBlock: option<int>,
  normalSelection: selection,
  // By address
  indexingContracts: dict<Internal.indexingContract>,
  // By contract name
  contractConfigs: dict<contractConfig>,
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
  // How many items we should aim to have in the buffer
  // ready for processing
  targetBufferSize: int,
  onBlockConfigs: array<Internal.onBlockConfig>,
  knownHeight: int,
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

/*
Comparitor for two events from the same chain. No need for chain id or timestamp
*/
let compareBufferItem = (a: Internal.item, b: Internal.item) => {
  let blockDiff = a->Internal.getItemBlockNumber - b->Internal.getItemBlockNumber
  if blockDiff === 0 {
    a->Internal.getItemLogIndex - b->Internal.getItemLogIndex
  } else {
    blockDiff
  }
}

// Some big number which should be bigger than any log index
let blockItemLogIndex = 16777216

let numAddresses = fetchState => fetchState.indexingContracts->Js.Dict.keys->Array.length

/*
Update fetchState, merge registers and recompute derived values.
Runs partition optimization when partitions change.
*/
let updateInternal = (
  fetchState: t,
  ~optimizedPartitions=fetchState.optimizedPartitions,
  ~indexingContracts=fetchState.indexingContracts,
  ~mutItems=?,
  ~blockLag=fetchState.blockLag,
  ~knownHeight=fetchState.knownHeight,
): t => {
  let mutItemsRef = ref(mutItems)

  let latestOnBlockBlockNumber = switch fetchState.onBlockConfigs {
  | [] => knownHeight
  | onBlockConfigs => {
      // Calculate the max block number we are going to create items for
      // Use targetBufferSize to get the last target item in the buffer
      //
      // mutItems is not very reliable, since it might not be sorted,
      // but the chances for it happen are very low and not critical
      //
      // All this needed to prevent OOM when adding too many block items to the queue
      let maxBlockNumber = switch switch mutItemsRef.contents {
      | Some(mutItems) => mutItems
      | None => fetchState.buffer
      }->Belt.Array.get(fetchState.targetBufferSize - 1) {
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

      let newItemsCounter = ref(0)
      let latestOnBlockBlockNumber = ref(fetchState.latestOnBlockBlockNumber)

      // Simply iterate over every block
      // could have a better algorithm to iterate over blocks in a more efficient way
      // but raw loops are fast enough
      while (
        latestOnBlockBlockNumber.contents < maxBlockNumber &&
          // Additional safeguard to prevent OOM
          newItemsCounter.contents <= fetchState.targetBufferSize
      ) {
        let blockNumber = latestOnBlockBlockNumber.contents + 1
        latestOnBlockBlockNumber := blockNumber

        for configIdx in 0 to onBlockConfigs->Array.length - 1 {
          let onBlockConfig = onBlockConfigs->Js.Array2.unsafe_get(configIdx)

          let handlerStartBlock = switch onBlockConfig.startBlock {
          | Some(startBlock) => startBlock
          | None => fetchState.startBlock
          }

          if (
            blockNumber >= handlerStartBlock &&
            switch onBlockConfig.endBlock {
            | Some(endBlock) => blockNumber <= endBlock
            | None => true
            } &&
            (blockNumber - handlerStartBlock)->Pervasives.mod(onBlockConfig.interval) === 0
          ) {
            mutItems->Array.push(
              Block({
                onBlockConfig,
                blockNumber,
                logIndex: blockItemLogIndex + onBlockConfig.index,
              }),
            )
            newItemsCounter := newItemsCounter.contents + 1
          }
        }
      }

      latestOnBlockBlockNumber.contents
    }
  }

  let updatedFetchState = {
    startBlock: fetchState.startBlock,
    endBlock: fetchState.endBlock,
    contractConfigs: fetchState.contractConfigs,
    normalSelection: fetchState.normalSelection,
    chainId: fetchState.chainId,
    onBlockConfigs: fetchState.onBlockConfigs,
    targetBufferSize: fetchState.targetBufferSize,
    optimizedPartitions,
    latestOnBlockBlockNumber,
    indexingContracts,
    blockLag,
    knownHeight,
    buffer: switch mutItemsRef.contents {
    // Theoretically it could be faster to asume that
    // the items are sorted, but there are cases
    // when the data source returns them unsorted
    | Some(mutItems) => mutItems->Js.Array2.sortInPlaceWith(compareBufferItem)
    | None => fetchState.buffer
    },
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
  if indexingContracts !== fetchState.indexingContracts {
    Prometheus.IndexingAddresses.set(
      ~addressesCount=updatedFetchState->numAddresses,
      ~chainId=fetchState.chainId,
    )
  }

  updatedFetchState
}

let warnDifferentContractType = (
  fetchState,
  ~existingContract: Internal.indexingContract,
  ~dc: Internal.indexingContract,
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
  let contractNames = addressesByContractName->Js.Dict.keys
  for idx in 0 to contractNames->Array.length - 1 {
    let contractName = contractNames->Js.Array2.unsafe_get(idx)
    numAddresses :=
      numAddresses.contents + addressesByContractName->Js.Dict.unsafeGet(contractName)->Array.length
  }
  numAddresses.contents
}

let addressesByContractNameGetAll = (addressesByContractName: dict<array<Address.t>>) => {
  let all = ref([])
  let contractNames = addressesByContractName->Js.Dict.keys
  for idx in 0 to contractNames->Array.length - 1 {
    let contractName = contractNames->Js.Array2.unsafe_get(idx)
    all := all.contents->Array.concat(addressesByContractName->Js.Dict.unsafeGet(contractName))
  }
  all.contents
}

/**
Creates partitions from indexing addresses with two phases:
Phase 1: Create per-contract-name partitions (smart grouping by startBlock)
Phase 2: Merge non-dynamic partitions together to reduce unnecessary concurrency
Returns OptimizedPartitions.t directly.
(Dynamic partitions are merged by OptimizedPartitions.make automatically)
*/
let createPartitionsFromIndexingAddresses = (
  ~registeringContractsByContract: dict<dict<Internal.indexingContract>>,
  ~contractConfigs: dict<contractConfig>,
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

  let contractNames = registeringContractsByContract->Js.Dict.keys
  for cIdx in 0 to contractNames->Js.Array2.length - 1 {
    let contractName = contractNames->Js.Array2.unsafe_get(cIdx)
    let registeringContracts = registeringContractsByContract->Js.Dict.unsafeGet(contractName)
    let addresses =
      registeringContracts->Js.Dict.keys->(Utils.magic: array<string> => array<Address.t>)

    // Can unsafely get it, because we already filtered out the contracts
    // that don't have any events to fetch
    let contractConfig = contractConfigs->Js.Dict.unsafeGet(contractName)
    let isDynamic = dynamicContracts->Utils.Set.has(contractName)
    let partitions = isDynamic ? dynamicPartitions : nonDynamicPartitions

    let byStartBlock = Js.Dict.empty()
    for jdx in 0 to addresses->Array.length - 1 {
      let address = addresses->Js.Array2.unsafe_get(jdx)
      let indexingContract = registeringContracts->Js.Dict.unsafeGet(address->Address.toString)
      byStartBlock->Utils.Dict.push(indexingContract.startBlock->Int.toString, address)
    }

    // Will be in ASC order by JS spec
    let ascKeys = byStartBlock->Js.Dict.keys
    let initialKey = ascKeys->Utils.Array.firstUnsafe

    let startBlockRef = ref(initialKey->Int.fromString->Option.getUnsafe)
    let addressesRef = ref(byStartBlock->Js.Dict.unsafeGet(initialKey))

    for idx in 0 to ascKeys->Js.Array2.length - 1 {
      let maybeNextStartBlockKey =
        ascKeys->Js.Array2.unsafe_get(idx + 1)->(Utils.magic: string => option<string>)

      // For this case we can't filter out events earlier than contract registration
      // on the client side, so we need to keep the old logic of creating
      // a partition for every block range, so there are no irrelevant events
      let shouldAllocateNewPartition = if contractConfig.filterByAddresses {
        true
      } else {
        switch maybeNextStartBlockKey {
        | None => true
        | Some(nextStartBlockKey) => {
            let nextStartBlock = nextStartBlockKey->Int.fromString->Option.getUnsafe
            let shouldJoinCurrentStartBlock =
              nextStartBlock - startBlockRef.contents < OptimizedPartitions.tooFarBlockRange

            // If dynamic contract registration are close to eachother
            // and it's possible to use dc.startBlock to filter out events on client side
            // then we can optimize the number of partitions,
            // by putting dcs with different startBlocks in the same partition
            if shouldJoinCurrentStartBlock {
              addressesRef :=
                addressesRef.contents->Array.concat(
                  byStartBlock->Js.Dict.unsafeGet(nextStartBlockKey),
                )
              false
            } else {
              true
            }
          }
        }
      }

      if shouldAllocateNewPartition {
        let latestFetchedBlock = {
          blockNumber: Pervasives.max(startBlockRef.contents - 1, progressBlockNumber),
          blockTimestamp: 0,
        }
        while addressesRef.contents->Array.length > 0 {
          let pAddresses =
            addressesRef.contents->Js.Array2.slice(~start=0, ~end_=maxAddrInPartition)
          addressesRef.contents = addressesRef.contents->Js.Array2.sliceFrom(maxAddrInPartition)

          let addressesByContractName = Js.Dict.empty()
          addressesByContractName->Js.Dict.set(contractName, pAddresses)
          partitions->Array.push({
            id: nextPartitionIndexRef.contents->Int.toString,
            latestFetchedBlock,
            selection: normalSelection,
            dynamicContract: isDynamic ? Some(contractName) : None,
            addressesByContractName,
            endBlock: None,
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
          })
          nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
        }

        switch maybeNextStartBlockKey {
        | None => ()
        | Some(nextStartBlockKey) => {
            startBlockRef := nextStartBlockKey->Int.fromString->Option.getUnsafe
            addressesRef := byStartBlock->Js.Dict.unsafeGet(nextStartBlockKey)
          }
        }
      }
    }
  }

  // ── Phase 2: Merge non-dynamic partitions ──
  let mergedNonDynamic = []

  if nonDynamicPartitions->Array.length > 0 {
    // Sort non-dynamic partitions by latestFetchedBlock ascending
    let _ = nonDynamicPartitions->Js.Array2.sortInPlaceWith(OptimizedPartitions.ascSortFn)

    let currentPRef = ref(nonDynamicPartitions->Js.Array2.unsafe_get(0))
    let nextIdx = ref(1)

    while nextIdx.contents < nonDynamicPartitions->Array.length {
      let nextP = nonDynamicPartitions->Js.Array2.unsafe_get(nextIdx.contents)
      let currentP = currentPRef.contents
      let currentPBlock = currentP.latestFetchedBlock.blockNumber
      let nextPBlock = nextP.latestFetchedBlock.blockNumber

      // Compute total count WITHOUT mutating any arrays
      let totalCount =
        currentP.addressesByContractName->addressesByContractNameCount +
          nextP.addressesByContractName->addressesByContractNameCount

      if totalCount > maxAddrInPartition {
        // Exceeds address limit - don't merge, keep partitions separate
        mergedNonDynamic->Js.Array2.push(currentP)->ignore
        currentPRef := nextP
      } else {
        // Build merged addresses using Array.concat (non-mutating)
        let mergedAddresses = nextP.addressesByContractName->Utils.Dict.shallowCopy
        let currentContractNames = currentP.addressesByContractName->Js.Dict.keys
        for jdx in 0 to currentContractNames->Js.Array2.length - 1 {
          let cn = currentContractNames->Js.Array2.unsafe_get(jdx)
          let currentAddrs = currentP.addressesByContractName->Js.Dict.unsafeGet(cn)
          switch mergedAddresses->Utils.Dict.dangerouslyGetNonOption(cn) {
          | Some(existingAddrs) =>
            // Use concat (non-mutating) to avoid corrupting nextP's arrays
            mergedAddresses->Js.Dict.set(cn, existingAddrs->Array.concat(currentAddrs))
          | None => mergedAddresses->Js.Dict.set(cn, currentAddrs)
          }
        }

        let nextContractName = nextP.addressesByContractName->Js.Dict.keys->Utils.Array.firstUnsafe
        let hasFilterByAddresses = (
          contractConfigs->Js.Dict.unsafeGet(nextContractName)
        ).filterByAddresses
        let isTooFar = currentPBlock + OptimizedPartitions.tooFarBlockRange < nextPBlock

        if isTooFar || hasFilterByAddresses {
          // Too far or address-filtered: endBlock on current, merge addresses into next
          mergedNonDynamic
          ->Js.Array2.push({
            ...currentP,
            endBlock: currentPBlock < nextPBlock ? Some(nextPBlock) : None,
          })
          ->ignore
          currentPRef := {
              ...nextP,
              addressesByContractName: mergedAddresses,
            }
        } else {
          // Close and not address-filtered: push next's addresses into current
          currentPRef := {
              ...currentP,
              addressesByContractName: mergedAddresses,
            }
        }
      }

      nextIdx := nextIdx.contents + 1
    }

    mergedNonDynamic->Js.Array2.push(currentPRef.contents)->ignore
  }

  let mergedPartitions = mergedNonDynamic->Js.Array2.concat(dynamicPartitions)

  // Final step: concat existing partitions with phase 1+2 result and call OptimizedPartitions.make
  OptimizedPartitions.make(
    ~partitions=existingPartitions->Js.Array2.concat(mergedPartitions),
    ~maxAddrInPartition,
    ~nextPartitionIndex=nextPartitionIndexRef.contents,
    ~dynamicContracts,
  )
}

let registerDynamicContracts = (
  fetchState: t,
  // These are raw items which might have dynamic contracts received from contractRegister call.
  // Might contain duplicates which we should filter out
  items: array<Internal.item>,
) => {
  if fetchState.normalSelection.eventConfigs->Utils.Array.isEmpty {
    // Can the normalSelection be empty?
    Js.Exn.raiseError(
      "Invalid configuration. No events to fetch for the dynamic contract registration.",
    )
  }

  let indexingContracts = fetchState.indexingContracts
  let registeringContractsByContract: dict<dict<Internal.indexingContract>> = Js.Dict.empty()
  let earliestRegisteringEventBlockNumber = ref(%raw(`Infinity`))
  let hasDCWithFilterByAddresses = ref(false)

  for itemIdx in 0 to items->Array.length - 1 {
    let item = items->Js.Array2.unsafe_get(itemIdx)
    switch item->Internal.getItemDcs {
    | None => ()
    | Some(dcs) =>
      let idx = ref(0)
      while idx.contents < dcs->Array.length {
        let dc = dcs->Js.Array2.unsafe_get(idx.contents)

        let shouldRemove = ref(false)

        switch fetchState.contractConfigs->Utils.Dict.dangerouslyGetNonOption(dc.contractName) {
        | Some({filterByAddresses}) =>
          // Prevent registering already indexing contracts
          switch indexingContracts->Utils.Dict.dangerouslyGetNonOption(
            dc.address->Address.toString,
          ) {
          | Some(existingContract) =>
            // FIXME: Instead of filtering out duplicates,
            // we should check the block number first.
            // If new registration with earlier block number
            // we should register it for the missing block range
            if existingContract.contractName != dc.contractName {
              fetchState->warnDifferentContractType(~existingContract, ~dc)
            } else if existingContract.startBlock > dc.startBlock {
              let logger = Logging.createChild(
                ~params={
                  "chainId": fetchState.chainId,
                  "contractAddress": dc.address->Address.toString,
                  "existingBlockNumber": existingContract.startBlock,
                  "newBlockNumber": dc.startBlock,
                },
              )
              logger->Logging.childWarn(`Skipping contract registration: Contract address is already registered at a later block number. Currently registration of the same contract address is not supported by Envio. Reach out to us if it's a problem for you.`)
            }
            shouldRemove := true
          | None =>
            let registeringContracts =
              registeringContractsByContract->Utils.Dict.getOrInsertEmptyDict(dc.contractName)
            let shouldUpdate = switch registeringContracts->Utils.Dict.dangerouslyGetNonOption(
              dc.address->Address.toString,
            ) {
            | Some(registeringContract) if registeringContract.contractName != dc.contractName =>
              fetchState->warnDifferentContractType(~existingContract=registeringContract, ~dc)
              false
            | Some(_) => // Since the DC is registered by an earlier item in the query
              // FIXME: This unsafely relies on the asc order of the items
              // which is 99% true, but there were cases when the source ordering was wrong
              false
            | None =>
              hasDCWithFilterByAddresses := hasDCWithFilterByAddresses.contents || filterByAddresses
              true
            }
            if shouldUpdate {
              earliestRegisteringEventBlockNumber :=
                Pervasives.min(earliestRegisteringEventBlockNumber.contents, dc.startBlock)
              registeringContracts->Js.Dict.set(dc.address->Address.toString, dc)
            } else {
              shouldRemove := true
            }
          }
        | None => {
            let logger = Logging.createChild(
              ~params={
                "chainId": fetchState.chainId,
                "contractAddress": dc.address->Address.toString,
                "contractName": dc.contractName,
              },
            )
            logger->Logging.childWarn(`Skipping contract registration: Contract doesn't have any events to fetch.`)
            shouldRemove := true
          }
        }

        if shouldRemove.contents {
          // Remove the DC from item to prevent it from saving to the db
          let _ = dcs->Js.Array2.removeCountInPlace(~count=1, ~pos=idx.contents)
          // Don't increment idx - next element shifted into current position
        } else {
          idx := idx.contents + 1
        }
      }
    }
  }

  let dcContractNamesToStore = registeringContractsByContract->Js.Dict.keys
  switch dcContractNamesToStore {
  // Dont update anything when everything was filter out
  | [] => fetchState
  | _ => {
      let newPartitions = []
      let newIndexingContracts = indexingContracts->Utils.Dict.shallowCopy
      let dynamicContractsRef = ref(fetchState.optimizedPartitions.dynamicContracts)
      let mutExistingPartitions = fetchState.optimizedPartitions.entities->Js.Dict.values

      for idx in 0 to dcContractNamesToStore->Js.Array2.length - 1 {
        let contractName = dcContractNamesToStore->Js.Array2.unsafe_get(idx)

        // When a new contract name is added as a dynamic contract for the first time (not in dynamicContracts set):
        // Walks through existing partitions that have addresses for this contract name
        // - If partition has ONLY this contract's addresses -> sets dynamicContract field
        // - If partition has this contract's addresses AND other contracts -> splits them
        // For the sake of merging simplicity we want to make sure that
        // partition has addresses of only one contract
        if !(dynamicContractsRef.contents->Utils.Set.has(contractName)) {
          dynamicContractsRef := dynamicContractsRef.contents->Utils.Set.immutableAdd(contractName)

          for idx in 0 to mutExistingPartitions->Js.Array2.length - 1 {
            let p = mutExistingPartitions->Js.Array2.unsafe_get(idx)
            switch p.addressesByContractName->Utils.Dict.dangerouslyGetNonOption(contractName) {
            | None => () // Skip partitions which don't have our contract
            | Some(addresses) =>
              // Also filter out partitions which are 100% not mergable
              if p.selection.dependsOnAddresses && p.endBlock === None {
                let allPartitionContractNames = p.addressesByContractName->Js.Dict.keys
                switch allPartitionContractNames {
                | [_] =>
                  mutExistingPartitions->Js.Array2.unsafe_set(
                    idx,
                    // Even if it's fetching, set dynamicContract field
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

                      mutExistingPartitions->Js.Array2.unsafe_set(
                        idx,
                        {
                          ...p,
                          addressesByContractName: restAddressesByContractName,
                        },
                      )

                      let addressesByContractName = Js.Dict.empty()
                      addressesByContractName->Js.Dict.set(contractName, addresses)
                      newPartitions->Array.push({
                        id: newPartitionId,
                        latestFetchedBlock: p.latestFetchedBlock,
                        selection: fetchState.normalSelection,
                        dynamicContract: Some(contractName),
                        addressesByContractName,
                        endBlock: None,
                        mutPendingQueries: p.mutPendingQueries,
                        prevQueryRange: p.prevQueryRange,
                        prevPrevQueryRange: p.prevPrevQueryRange,
                      })
                    }
                  }
                }
              }
            }
          }
        }

        let registeringContracts = registeringContractsByContract->Js.Dict.unsafeGet(contractName)
        let _ = Utils.Dict.mergeInPlace(newIndexingContracts, registeringContracts)
      }

      let optimizedPartitions = createPartitionsFromIndexingAddresses(
        ~registeringContractsByContract,
        ~contractConfigs=fetchState.contractConfigs,
        ~dynamicContracts=dynamicContractsRef.contents,
        ~normalSelection=fetchState.normalSelection,
        ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
        ~nextPartitionIndex=fetchState.optimizedPartitions.nextPartitionIndex +
        newPartitions->Array.length,
        ~existingPartitions=mutExistingPartitions->Js.Array2.concat(newPartitions),
        ~progressBlockNumber=0,
      )

      fetchState->updateInternal(~optimizedPartitions, ~indexingContracts=newIndexingContracts)
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
  ~query: query,
  ~latestFetchedBlock: blockNumberAndTimestamp,
  ~newItems,
): t => {
  fetchState->updateInternal(
    ~optimizedPartitions=fetchState.optimizedPartitions->OptimizedPartitions.handleQueryResponse(
      ~query,
      ~knownHeight=fetchState.knownHeight,
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
  | ReachedMaxConcurrency
  | WaitingForNewBlock
  | NothingToQuery
  | Ready(array<query>)

let startFetchingQueries = ({optimizedPartitions}: t, ~queries: array<query>) => {
  for qIdx in 0 to queries->Array.length - 1 {
    let q = queries->Js.Array2.unsafe_get(qIdx)
    let p = optimizedPartitions->OptimizedPartitions.getOrThrow(~partitionId=q.partitionId)

    let pq = {
      fromBlock: q.fromBlock,
      toBlock: q.toBlock,
      isChunk: q.isChunk,
      fetchedBlock: None,
    }

    // Insert in sorted order by fromBlock to maintain queue invariant.
    // Gap-fill queries may have lower fromBlock than existing pending queries.
    let inserted = ref(false)
    let i = ref(0)
    while i.contents < p.mutPendingQueries->Array.length && !inserted.contents {
      if (p.mutPendingQueries->Js.Array2.unsafe_get(i.contents)).fromBlock > q.fromBlock {
        p.mutPendingQueries->Js.Array2.spliceInPlace(~pos=i.contents, ~remove=0, ~add=[pq])->ignore
        inserted := true
      }
      i := i.contents + 1
    }
    if !inserted.contents {
      p.mutPendingQueries->Array.push(pq)->ignore
    }
  }
}

@inline
let pushQueriesForRange = (
  queries: array<query>,
  ~partitionId: string,
  ~rangeFromBlock: int,
  ~rangeEndBlock: option<int>,
  ~maxQueryBlockNumber: int,
  ~maybeChunkRange: option<int>,
  ~selection: selection,
  ~addressesByContractName: dict<array<Address.t>>,
  ~indexingContracts: dict<Internal.indexingContract>,
) => {
  if rangeFromBlock <= maxQueryBlockNumber {
    switch rangeEndBlock {
    | Some(endBlock) if rangeFromBlock > endBlock => ()
    | _ =>
      switch maybeChunkRange {
      | None =>
        queries->Array.push({
          partitionId,
          fromBlock: rangeFromBlock,
          toBlock: rangeEndBlock,
          selection,
          isChunk: false,
          addressesByContractName,
          indexingContracts,
        })
      | Some(chunkRange) =>
        let maxBlock = switch rangeEndBlock {
        | Some(eb) => eb
        | None => maxQueryBlockNumber
        }
        let chunkSize = Js.Math.ceil_int(chunkRange->Int.toFloat *. 1.8)
        if rangeFromBlock + 2 * chunkSize - 1 <= maxBlock {
          // Create 2 chunks of ceil(1.8 * chunkRange) each
          queries->Array.push({
            partitionId,
            fromBlock: rangeFromBlock,
            toBlock: Some(rangeFromBlock + chunkSize - 1),
            isChunk: true,
            selection,
            addressesByContractName,
            indexingContracts,
          })
          queries->Array.push({
            partitionId,
            fromBlock: rangeFromBlock + chunkSize,
            toBlock: Some(rangeFromBlock + 2 * chunkSize - 1),
            isChunk: true,
            selection,
            addressesByContractName,
            indexingContracts,
          })
        } else {
          // Not enough room for 2 chunks, fall back to a single query
          queries->Array.push({
            partitionId,
            fromBlock: rangeFromBlock,
            toBlock: rangeEndBlock,
            selection,
            isChunk: rangeEndBlock !== None,
            addressesByContractName,
            indexingContracts,
          })
        }
      }
    }
  }
}

let getNextQuery = (
  {
    buffer,
    optimizedPartitions,
    targetBufferSize,
    indexingContracts,
    blockLag,
    latestOnBlockBlockNumber,
    knownHeight,
  } as fetchState: t,
  ~concurrencyLimit,
) => {
  let headBlockNumber = knownHeight - blockLag
  if headBlockNumber <= 0 {
    WaitingForNewBlock
  } else if concurrencyLimit === 0 {
    ReachedMaxConcurrency
  } else {
    let isOnBlockBehindTheHead = latestOnBlockBlockNumber < headBlockNumber
    let shouldWaitForNewBlock = ref(
      switch fetchState.endBlock {
      | Some(endBlock) => headBlockNumber < endBlock
      | None => true
      } &&
      !isOnBlockBehindTheHead,
    )

    // We want to limit the buffer size to targetBufferSize (usually 3 * batchSize)
    // To make sure the processing always has some buffer
    // and not increase the memory usage too much
    // If a partition fetched further
    // it should be skipped until the buffer is consumed
    let maxQueryBlockNumber = {
      switch buffer->Array.get(targetBufferSize - 1) {
      | Some(item) =>
        // Just in case check that we don't query beyond the current block
        Pervasives.min(item->Internal.getItemBlockNumber, knownHeight)
      | None => knownHeight
      }
    }

    let queries = []

    let partitionsCount = optimizedPartitions.idsInAscOrder->Js.Array2.length
    let idxRef = ref(0)
    while idxRef.contents < partitionsCount {
      let idx = idxRef.contents
      let partitionId = optimizedPartitions.idsInAscOrder->Js.Array2.unsafe_get(idx)
      let p = optimizedPartitions.entities->Js.Dict.unsafeGet(partitionId)

      let isBehindTheHead = p.latestFetchedBlock.blockNumber < headBlockNumber
      let hasPendingQueries = p.mutPendingQueries->Utils.Array.notEmpty

      if hasPendingQueries || isBehindTheHead {
        // Even if there are some partitions waiting for the new block
        // We still want to wait for all partitions reaching the head
        // because they might update knownHeight in their response
        // Also, there are cases when some partitions fetching at 50% of the chain
        // and we don't want to poll the head for a few small partitions
        shouldWaitForNewBlock := false
      }

      // Compute queryEndBlock for this partition
      let queryEndBlock = Utils.Math.minOptInt(fetchState.endBlock, p.endBlock)
      let queryEndBlock = switch blockLag {
      | 0 => queryEndBlock
      | _ =>
        // Force head block as an endBlock when blockLag is set
        // because otherwise HyperSync might return bigger range
        Utils.Math.minOptInt(Some(headBlockNumber), queryEndBlock)
      }
      // Enforce the response range up until target block
      // Otherwise for indexers with 100+ partitions
      // we might blow up the buffer size to more than 600k events
      // simply because of HyperSync returning extra blocks
      let queryEndBlock = switch (queryEndBlock, maxQueryBlockNumber < knownHeight) {
      | (Some(endBlock), true) => Some(Pervasives.min(maxQueryBlockNumber, endBlock))
      | (None, true) => Some(maxQueryBlockNumber)
      | (_, false) => queryEndBlock
      }

      let maybeChunkRange = getMinHistoryRange(p)

      // Walk pending queries to find open ranges and create queries for each
      let cursor = ref(
        p.latestFetchedBlock.blockNumber === 0 ? 0 : p.latestFetchedBlock.blockNumber + 1,
      )
      let canContinue = ref(true)
      let pqIdx = ref(0)
      while pqIdx.contents < p.mutPendingQueries->Array.length && canContinue.contents {
        let pq = p.mutPendingQueries->Js.Array2.unsafe_get(pqIdx.contents)

        // Gap before this pending query → create queries for the gap range
        if pq.fromBlock > cursor.contents {
          pushQueriesForRange(
            queries,
            ~partitionId,
            ~rangeFromBlock=cursor.contents,
            ~rangeEndBlock=Utils.Math.minOptInt(Some(pq.fromBlock - 1), queryEndBlock),
            ~maxQueryBlockNumber,
            ~maybeChunkRange,
            ~selection=p.selection,
            ~addressesByContractName=p.addressesByContractName,
            ~indexingContracts,
          )
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

      // Tail range after all pending queries
      if canContinue.contents {
        pushQueriesForRange(
          queries,
          ~partitionId,
          ~rangeFromBlock=cursor.contents,
          ~rangeEndBlock=queryEndBlock,
          ~maxQueryBlockNumber,
          ~maybeChunkRange,
          ~selection=p.selection,
          ~addressesByContractName=p.addressesByContractName,
          ~indexingContracts,
        )
      }

      idxRef := idxRef.contents + 1
    }

    if queries->Utils.Array.isEmpty {
      if shouldWaitForNewBlock.contents {
        WaitingForNewBlock
      } else {
        NothingToQuery
      }
    } else {
      // Enforce concurrency limit: sort by fromBlock and take the first concurrencyLimit
      let queries = if queries->Array.length > concurrencyLimit {
        queries->Js.Array2.sortInPlaceWith((a, b) => a.fromBlock - b.fromBlock)->ignore
        queries->Js.Array2.slice(~start=0, ~end_=concurrencyLimit)
      } else {
        queries
      }
      Ready(queries)
    }
  }
}

let getTimestampAt = (fetchState: t, ~index) => {
  switch fetchState.buffer->Belt.Array.get(index) {
  | Some(Event({timestamp})) => timestamp
  | Some(Block(_)) =>
    Js.Exn.raiseError("Block handlers are not supported for ordered multichain mode.")
  | None => (fetchState->bufferBlock).blockTimestamp
  }
}

let hasReadyItem = ({buffer} as fetchState: t) => {
  switch buffer->Belt.Array.get(0) {
  | Some(item) => item->Internal.getItemBlockNumber <= fetchState->bufferBlockNumber
  | None => false
  }
}

let getReadyItemsCount = (fetchState: t, ~targetSize: int, ~fromItem) => {
  let readyBlockNumber = ref(fetchState->bufferBlockNumber)
  let acc = ref(0)
  let isFinished = ref(false)
  while !isFinished.contents {
    switch fetchState.buffer->Belt.Array.get(fromItem + acc.contents) {
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
  ~eventConfigs: array<Internal.eventConfig>,
  ~contracts: array<Internal.indexingContract>,
  ~maxAddrInPartition,
  ~chainId,
  ~targetBufferSize,
  ~knownHeight,
  ~progressBlockNumber=startBlock - 1,
  ~onBlockConfigs=[],
  ~blockLag=0,
): t => {
  let latestFetchedBlock = {
    blockTimestamp: 0,
    blockNumber: progressBlockNumber,
  }

  let notDependingOnAddresses = []
  let normalEventConfigs = []
  let contractNamesWithNormalEvents = Utils.Set.make()
  let indexingContracts = Js.Dict.empty()
  let contractConfigs = Js.Dict.empty()

  eventConfigs->Array.forEach(ec => {
    switch contractConfigs->Utils.Dict.dangerouslyGetNonOption(ec.contractName) {
    | Some({filterByAddresses}) =>
      contractConfigs->Js.Dict.set(
        ec.contractName,
        {filterByAddresses: filterByAddresses || ec.filterByAddresses},
      )
    | None =>
      contractConfigs->Js.Dict.set(ec.contractName, {filterByAddresses: ec.filterByAddresses})
    }

    if ec.dependsOnAddresses {
      normalEventConfigs->Array.push(ec)
      contractNamesWithNormalEvents->Utils.Set.add(ec.contractName)->ignore
    } else {
      notDependingOnAddresses->Array.push(ec)
    }
  })

  let partitions = []

  if notDependingOnAddresses->Array.length > 0 {
    partitions->Array.push({
      id: partitions->Array.length->Int.toString,
      latestFetchedBlock,
      selection: {
        dependsOnAddresses: false,
        eventConfigs: notDependingOnAddresses,
      },
      addressesByContractName: Js.Dict.empty(),
      endBlock: None,
      dynamicContract: None,
      mutPendingQueries: [],
      prevQueryRange: 0,
      prevPrevQueryRange: 0,
    })
  }

  let normalSelection = {
    dependsOnAddresses: true,
    eventConfigs: normalEventConfigs,
  }

  let registeringContractsByContract: dict<dict<Internal.indexingContract>> = Js.Dict.empty()
  let dynamicContracts = Utils.Set.make()

  switch normalEventConfigs {
  | [] => ()
  | _ =>
    contracts->Array.forEach(contract => {
      let contractName = contract.contractName
      if contractNamesWithNormalEvents->Utils.Set.has(contractName) {
        let registeringContracts =
          registeringContractsByContract->Utils.Dict.getOrInsertEmptyDict(contractName)
        registeringContracts->Js.Dict.set(contract.address->Address.toString, contract)
        indexingContracts->Js.Dict.set(contract.address->Address.toString, contract)

        // Detect dynamic contracts by registrationBlock
        if contract.registrationBlock !== None {
          dynamicContracts->Utils.Set.add(contractName)->ignore
        }
      }
    })
  }

  let optimizedPartitions = createPartitionsFromIndexingAddresses(
    ~registeringContractsByContract,
    ~contractConfigs,
    ~dynamicContracts,
    ~normalSelection,
    ~maxAddrInPartition,
    ~nextPartitionIndex=partitions->Array.length,
    ~existingPartitions=partitions, // wildcard partition(s) if any
    ~progressBlockNumber,
  )

  if optimizedPartitions->OptimizedPartitions.count === 0 && onBlockConfigs->Utils.Array.isEmpty {
    Js.Exn.raiseError(
      "Invalid configuration: Nothing to fetch. Make sure that you provided at least one contract address to index, or have events with Wildcard mode enabled, or have onBlock handlers.",
    )
  }

  let numAddresses = indexingContracts->Js.Dict.keys->Array.length
  Prometheus.IndexingAddresses.set(~addressesCount=numAddresses, ~chainId)
  Prometheus.IndexingPartitions.set(
    ~partitionsCount=optimizedPartitions->OptimizedPartitions.count,
    ~chainId,
  )
  Prometheus.IndexingBufferSize.set(~bufferSize=0, ~chainId)
  Prometheus.IndexingBufferBlockNumber.set(~blockNumber=latestFetchedBlock.blockNumber, ~chainId)
  switch endBlock {
  | Some(endBlock) => Prometheus.IndexingEndBlock.set(~endBlock, ~chainId)
  | None => ()
  }

  {
    optimizedPartitions,
    contractConfigs,
    chainId,
    startBlock,
    endBlock,
    latestOnBlockBlockNumber: progressBlockNumber,
    normalSelection,
    indexingContracts,
    blockLag,
    onBlockConfigs,
    targetBufferSize,
    knownHeight,
    buffer: [],
  }
}

let bufferSize = ({buffer}: t) => buffer->Array.length

/**
Rolls back partitions to the given valid block
*/
let rollbackPartition = (p: partition, ~targetBlockNumber, ~addressesToRemove) => {
  let shouldRollbackFetched = p.latestFetchedBlock.blockNumber > targetBlockNumber
  let latestFetchedBlock = shouldRollbackFetched
    ? {
        blockNumber: targetBlockNumber,
        blockTimestamp: 0,
      }
    : p.latestFetchedBlock

  // FIXME: Check it
  // Clear endBlock when rolling back below it
  let endBlock = switch p.endBlock {
  | Some(endBlock) if targetBlockNumber < endBlock => None
  | other => other
  }
  switch p {
  | {selection: {dependsOnAddresses: false}} =>
    Some({
      ...p,
      latestFetchedBlock,
      endBlock,
      mutPendingQueries: [],
    })
  | {addressesByContractName} =>
    let rollbackedAddressesByContractName = Js.Dict.empty()
    addressesByContractName->Utils.Dict.forEachWithKey((addresses, contractName) => {
      let keptAddresses =
        addresses->Array.keep(address => !(addressesToRemove->Utils.Set.has(address)))
      if keptAddresses->Array.length > 0 {
        rollbackedAddressesByContractName->Js.Dict.set(contractName, keptAddresses)
      }
    })

    if rollbackedAddressesByContractName->Js.Dict.keys->Array.length === 0 {
      None
    } else {
      Some({
        id: p.id,
        selection: p.selection,
        addressesByContractName: rollbackedAddressesByContractName,
        latestFetchedBlock,
        endBlock,
        dynamicContract: p.dynamicContract,
        mutPendingQueries: [],
        prevQueryRange: p.prevQueryRange,
        prevPrevQueryRange: p.prevPrevQueryRange,
      })
    }
  }
}

let rollback = (fetchState: t, ~targetBlockNumber) => {
  let addressesToRemove = Utils.Set.make()
  let indexingContracts = Js.Dict.empty()

  fetchState.indexingContracts
  ->Js.Dict.keys
  ->Array.forEach(address => {
    let indexingContract = fetchState.indexingContracts->Js.Dict.unsafeGet(address)
    switch indexingContract.registrationBlock {
    | Some(registrationBlock) if registrationBlock > targetBlockNumber => {
        //If the registration block is later than the first change event,
        //Do not keep it and add to the removed addresses
        let _ = addressesToRemove->Utils.Set.add(address->Address.unsafeFromString)
      }
    | _ => indexingContracts->Js.Dict.set(address, indexingContract)
    }
  })

  let optimizedPartitions = OptimizedPartitions.make(
    ~partitions=fetchState.optimizedPartitions.entities
    ->Js.Dict.values
    ->Array.keepMap(p => p->rollbackPartition(~targetBlockNumber, ~addressesToRemove)),
    ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
    ~nextPartitionIndex=fetchState.optimizedPartitions.nextPartitionIndex,
    ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
  )

  {
    ...fetchState,
    latestOnBlockBlockNumber: Pervasives.min(
      fetchState.latestOnBlockBlockNumber,
      targetBlockNumber,
    ), // TODO: Test this. Currently it's not tested.
  }->updateInternal(
    ~optimizedPartitions,
    ~indexingContracts,
    ~mutItems=fetchState.buffer->Array.keep(item =>
      switch item {
      | Event({blockNumber})
      | Block({blockNumber}) => blockNumber
      } <=
      targetBlockNumber
    ),
  )
}

// Reset pending queries. If there are fetched queries in the middle (out-of-order completion),
// it means we already have the events for those ranges, so we don't need to fetch them again.
// We rollback to the earliest such query's fromBlock - 1. Otherwise just clear mutPendingQueries.
// This is not the most efficient in terms of overfetching, but the simplest to implement.
// Ideally we shouldn't stop handling queries on rollback.
let resetPendingQueries = (fetchState: t) => {
  // Track earliest "fetched in middle" query's fromBlock for potential rollback
  let earliestFetchedInMiddleFromBlock = ref(None)
  let newEntities = fetchState.optimizedPartitions.entities->Utils.Dict.shallowCopy

  for idx in 0 to fetchState.optimizedPartitions.idsInAscOrder->Array.length - 1 {
    let partitionId = fetchState.optimizedPartitions.idsInAscOrder->Js.Array2.unsafe_get(idx)
    let partition = fetchState.optimizedPartitions.entities->Js.Dict.unsafeGet(partitionId)

    if partition.mutPendingQueries->Array.length > 0 {
      // Look for pattern: [fetching, fetched, ...] and track earliest fromBlock
      let sawUnfetched = ref(false)
      for qIdx in 0 to partition.mutPendingQueries->Array.length - 1 {
        let pq = partition.mutPendingQueries->Js.Array2.unsafe_get(qIdx)
        switch pq.fetchedBlock {
        | None => sawUnfetched := true
        | Some(_) if sawUnfetched.contents =>
          earliestFetchedInMiddleFromBlock :=
            Some(
              switch earliestFetchedInMiddleFromBlock.contents {
              | None => pq.fromBlock
              | Some(existing) => Pervasives.min(existing, pq.fromBlock)
              },
            )
        | Some(_) => ()
        }
      }

      newEntities->Js.Dict.set(
        partitionId,
        {
          ...partition,
          mutPendingQueries: [],
        },
      )
    }
  }

  switch earliestFetchedInMiddleFromBlock.contents {
  | Some(fromBlock) => fetchState->rollback(~targetBlockNumber=fromBlock - 1)
  | None => // No fetched queries in middle - just use cleared pending queries
    {
      ...fetchState,
      optimizedPartitions: {
        ...fetchState.optimizedPartitions,
        entities: newEntities,
      },
    }
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

let isReadyToEnterReorgThreshold = ({endBlock, blockLag, buffer, knownHeight} as fetchState: t) => {
  let bufferBlockNumber = fetchState->bufferBlockNumber
  knownHeight !== 0 &&
  switch endBlock {
  | Some(endBlock) if bufferBlockNumber >= endBlock => true
  | _ => bufferBlockNumber >= knownHeight - blockLag
  } &&
  buffer->Utils.Array.isEmpty
}

let sortForUnorderedBatch = {
  let hasFullBatch = ({buffer} as fetchState: t, ~batchSizeTarget) => {
    switch buffer->Belt.Array.get(batchSizeTarget - 1) {
    | Some(item) => item->Internal.getItemBlockNumber <= fetchState->bufferBlockNumber
    | None => false
    }
  }

  (fetchStates: array<t>, ~batchSizeTarget: int) => {
    fetchStates
    ->Array.copy
    ->Js.Array2.sortInPlaceWith((a: t, b: t) => {
      switch (a->hasFullBatch(~batchSizeTarget), b->hasFullBatch(~batchSizeTarget)) {
      | (true, true)
      | (false, false) =>
        switch (a.buffer->Belt.Array.get(0), b.buffer->Belt.Array.get(0)) {
        | (Some(Event({timestamp: aTimestamp})), Some(Event({timestamp: bTimestamp}))) =>
          aTimestamp - bTimestamp
        | (Some(Block(_)), _)
        | (_, Some(Block(_))) =>
          // Currently block items don't have a timestamp,
          // so we sort chains with them in a random order
          Js.Math.random_int(-1, 1)
        // We don't care about the order of chains with no items
        // Just keep them to increase the progress block number when relevant
        | (Some(_), None) => -1
        | (None, Some(_)) => 1
        | (None, None) => 0
        }
      | (true, false) => -1
      | (false, true) => 1
      }
    })
  }
}

// Ordered multichain mode can't skip blocks, even if there are no items.
let getUnorderedMultichainProgressBlockNumberAt = ({buffer} as fetchState: t, ~index) => {
  let bufferBlockNumber = fetchState->bufferBlockNumber
  switch buffer->Belt.Array.get(index) {
  | Some(item) if bufferBlockNumber >= item->Internal.getItemBlockNumber =>
    item->Internal.getItemBlockNumber - 1
  | _ => bufferBlockNumber
  }
}

let updateKnownHeight = (fetchState: t, ~knownHeight) => {
  if knownHeight > fetchState.knownHeight {
    Prometheus.setKnownHeight(~blockNumber=knownHeight, ~chainId=fetchState.chainId)
    fetchState->updateInternal(~knownHeight)
  } else {
    fetchState
  }
}
