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
  prevPrevPrevQueryRange: int,
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

  @unboxed
  type mergeResult = Merged(partition) | FullFirstRestSecond((partition, partition))

  let mergeDynamicContractPartition = (
    p1: partition,
    ~p2Addresses,
    ~p2Id,
    ~contractName,
    ~maxAddrInPartition,
  ) => {
    let addresses =
      p1.addressesByContractName
      ->Js.Dict.unsafeGet(contractName)
      ->Js.Array2.concat(p2Addresses)

    if addresses->Js.Array2.length > maxAddrInPartition {
      let addressesFull = addresses->Js.Array2.slice(~start=0, ~end_=maxAddrInPartition)
      let addressesRest = addresses->Js.Array2.sliceFrom(maxAddrInPartition)

      let addressesByContractNameFull = Js.Dict.empty()
      addressesByContractNameFull->Js.Dict.set(contractName, addressesFull)
      let addressesByContractNameRest = Js.Dict.empty()
      addressesByContractNameRest->Js.Dict.set(contractName, addressesRest)
      FullFirstRestSecond(
        {
          id: p1.id,
          addressesByContractName: addressesByContractNameFull,
          dynamicContract: Some(contractName),
          selection: p1.selection, // We merge only partitions with normal selection
          latestFetchedBlock: p1.latestFetchedBlock, // We merge only partitions at the same block
          endBlock: None, // We don't merge partitions with endBlock
          mutPendingQueries: p1.mutPendingQueries,
          // Keep query range history from original partition
          prevQueryRange: p1.prevQueryRange,
          prevPrevQueryRange: p1.prevPrevQueryRange,
          prevPrevPrevQueryRange: p1.prevPrevPrevQueryRange,
        },
        {
          id: p2Id,
          addressesByContractName: addressesByContractNameRest,
          dynamicContract: Some(contractName),
          selection: p1.selection, // We merge only partitions with normal selection
          latestFetchedBlock: p1.latestFetchedBlock, // We merge only partitions at the same block
          endBlock: None, // We don't merge partitions with endBlock
          mutPendingQueries: [],
          // Keep query range history from original partition
          prevQueryRange: p1.prevQueryRange,
          prevPrevQueryRange: p1.prevPrevQueryRange,
          prevPrevPrevQueryRange: p1.prevPrevPrevQueryRange,
        },
      )
    } else {
      let addressesByContractName = Js.Dict.empty()
      addressesByContractName->Js.Dict.set(contractName, addresses)
      Merged({
        id: p1.id,
        addressesByContractName,
        dynamicContract: Some(contractName),
        selection: p1.selection, // We merge only partitions with normal selection
        latestFetchedBlock: p1.latestFetchedBlock, // We merge only partitions at the same block
        endBlock: None, // We don't merge partitions with endBlock
        mutPendingQueries: p1.mutPendingQueries,
        // Keep query range history from original partition
        prevQueryRange: p1.prevQueryRange,
        prevPrevQueryRange: p1.prevPrevQueryRange,
        prevPrevPrevQueryRange: p1.prevPrevPrevQueryRange,
      })
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
      // Optimize fetching partitions only after they finished fetching
      let isFetching = p.mutPendingQueries->Utils.Array.notEmpty
      switch p {
      // Since it's not a dynamic contract partition,
      // there's no need for merge logic
      | {dynamicContract: None}
      | // Wildcard doesn't need merging
      {selection: {dependsOnAddresses: false}}
      | // For now don't merge partitions with endBlock,
      // assuming they are already merged,
      // although there might be cases with too far away endBlock,
      // which is worth merging
      {endBlock: Some(_)} =>
        newPartitions->Js.Array2.push(p)->ignore
      | _ if isFetching => newPartitions->Js.Array2.push(p)->ignore
      | {dynamicContract: Some(contractName)} =>
        let pAddressesCount =
          p.addressesByContractName->Js.Dict.unsafeGet(contractName)->Js.Array2.length
        if pAddressesCount >= maxAddrInPartition {
          newPartitions->Js.Array2.push(p)->ignore
        } else {
          let contractPartitionAggregate =
            mergingPartitions->Utils.Dict.getOrInsertEmptyDict(contractName)
          switch contractPartitionAggregate->Utils.Dict.dangerouslyGetByIntNonOption(
            p.latestFetchedBlock.blockNumber,
          ) {
          | Some(existingPartitionAtTheBlock) =>
            let restP = switch mergeDynamicContractPartition(
              existingPartitionAtTheBlock,
              ~p2Addresses=p.addressesByContractName->Js.Dict.unsafeGet(contractName),
              ~p2Id=p.id,
              ~contractName,
              ~maxAddrInPartition,
            ) {
            | FullFirstRestSecond((fullP, restP)) => {
                newPartitions->Js.Array2.push(fullP)->ignore
                restP
              }
            | Merged(restP) => restP
            }
            contractPartitionAggregate->Utils.Dict.setByInt(p.latestFetchedBlock.blockNumber, restP)
          | None =>
            contractPartitionAggregate->Utils.Dict.setByInt(p.latestFetchedBlock.blockNumber, p)
          }
        }
      }
    }

    let merginDynamicContracts = mergingPartitions->Js.Dict.keys
    for idx in 0 to merginDynamicContracts->Array.length - 1 {
      let contractName = merginDynamicContracts->Js.Array2.unsafe_get(idx)
      let contractPartitionAggregate = mergingPartitions->Js.Dict.unsafeGet(contractName)
      // JS engine automatically sorts number keys in objects
      let ascPartitionKeys = contractPartitionAggregate->Js.Dict.keys
      let currentPRef = ref(
        contractPartitionAggregate->Js.Dict.unsafeGet(ascPartitionKeys->Js.Array2.unsafe_get(0)),
      )
      let nextJdx = ref(1)
      while nextJdx.contents < ascPartitionKeys->Array.length {
        let nextKey = ascPartitionKeys->Js.Array2.unsafe_get(nextJdx.contents)
        let currentP = currentPRef.contents
        let nextP = contractPartitionAggregate->Js.Dict.unsafeGet(nextKey)
        let nextPBlock = nextP.latestFetchedBlock.blockNumber

        let isTooFar = currentP.latestFetchedBlock.blockNumber + tooFarBlockRange < nextPBlock
        if isTooFar {
          newPartitions->Js.Array2.push(currentP)->ignore
          currentPRef := nextP
        } else {
          newPartitions
          ->Js.Array2.push({
            ...currentP,
            endBlock: Some(nextPBlock),
          })
          ->ignore

          let restP = switch mergeDynamicContractPartition(
            nextP,
            ~p2Addresses=currentP.addressesByContractName->Js.Dict.unsafeGet(contractName),
            ~p2Id=nextPartitionIndexRef.contents->Js.Int.toString,
            ~contractName,
            ~maxAddrInPartition,
          ) {
          | FullFirstRestSecond((fullP, restP)) => {
              // Means the index was used, so increment
              nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
              newPartitions->Js.Array2.push(fullP)->ignore
              restP
            }
          | Merged(restP) => restP
          }

          currentPRef := restP
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
  // Removes consecutive fetched queries and returns the last fetchedBlock
  @inline
  let consumeFetchedQueries = (
    mutPendingQueries: array<pendingQuery>,
    ~initialLatestFetchedBlock,
  ) => {
    let latestFetchedBlock = ref(initialLatestFetchedBlock)

    while (
      mutPendingQueries->Array.length > 0 &&
        (mutPendingQueries->Js.Array2.unsafe_get(0)).fetchedBlock !== None
    ) {
      let removedQuery = mutPendingQueries->Js.Array2.shift->Option.getUnsafe
      latestFetchedBlock := (
          removedQuery.isChunk
            ? {
                blockNumber: removedQuery.toBlock->Option.getUnsafe,
                blockTimestamp: 0,
              }
            : removedQuery.fetchedBlock->Option.getUnsafe
        )
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
    let nextPartitionIndexRef = ref(optimizedPartitions.nextPartitionIndex)
    let p = optimizedPartitions->getOrThrow(~partitionId=query.partitionId)
    let mutEntities = optimizedPartitions.entities->Utils.Dict.shallowCopy

    // Mark query as fetched
    let pendingQuery = getPendingQueryOrThrow(p, ~fromBlock=query.fromBlock)
    pendingQuery.fetchedBlock = Some(latestFetchedBlock)

    let blockRange = latestFetchedBlock.blockNumber - query.fromBlock + 1
    let shouldUpdateBlockRange = switch query.toBlock {
    | None => latestFetchedBlock.blockNumber < knownHeight - 10 // Don't update block range when very close to the head
    | Some(queryToBlock) => latestFetchedBlock.blockNumber < queryToBlock
    }
    let updatedPrevQueryRange = shouldUpdateBlockRange ? blockRange : p.prevQueryRange
    let updatedPrevPrevQueryRange = shouldUpdateBlockRange ? p.prevQueryRange : p.prevPrevQueryRange
    let updatedPrevPrevPrevQueryRange = shouldUpdateBlockRange
      ? p.prevPrevQueryRange
      : p.prevPrevPrevQueryRange

    // Create remaining partition only for chunks that didn't reach toBlock
    switch query.toBlock {
    | Some(queryToBlock) if query.isChunk && latestFetchedBlock.blockNumber < queryToBlock =>
      let newPartitionId = nextPartitionIndexRef.contents->Int.toString
      nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
      mutEntities->Js.Dict.set(
        newPartitionId,
        {
          id: newPartitionId,
          latestFetchedBlock,
          selection: p.selection,
          addressesByContractName: p.addressesByContractName,
          endBlock: Some(queryToBlock),
          dynamicContract: p.dynamicContract,
          mutPendingQueries: [],
          prevQueryRange: updatedPrevQueryRange,
          prevPrevQueryRange: updatedPrevPrevQueryRange,
          prevPrevPrevQueryRange: updatedPrevPrevPrevQueryRange,
        },
      )

    | _ => ()
    }

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
        prevPrevPrevQueryRange: updatedPrevPrevPrevQueryRange,
      }

      mutEntities->Js.Dict.set(p.id, updatedMainPartition)
    }

    // Re-optimize to maintain sorted order and apply optimizations
    make(
      ~partitions=mutEntities->Js.Dict.values,
      ~maxAddrInPartition=optimizedPartitions.maxAddrInPartition,
      ~nextPartitionIndex=nextPartitionIndexRef.contents,
      ~dynamicContracts=optimizedPartitions.dynamicContracts,
    )
  }

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
  // The block number of the latest block fetched
  // which added all its events to the queue
  latestFullyFetchedBlock: blockNumberAndTimestamp,
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
let bufferBlockNumber = ({latestFullyFetchedBlock, latestOnBlockBlockNumber}: t) => {
  latestOnBlockBlockNumber < latestFullyFetchedBlock.blockNumber
    ? latestOnBlockBlockNumber
    : latestFullyFetchedBlock.blockNumber
}

/**
* Returns the latest block which is ready to be consumed
*/
@inline
let bufferBlock = ({latestFullyFetchedBlock, latestOnBlockBlockNumber}: t) => {
  latestOnBlockBlockNumber < latestFullyFetchedBlock.blockNumber
    ? {
        blockNumber: latestOnBlockBlockNumber,
        blockTimestamp: 0,
      }
    : latestFullyFetchedBlock
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
  let latestFullyFetchedBlock = switch optimizedPartitions->OptimizedPartitions.getLatestFullyFetchedBlock {
  | Some(latestFullyFetchedBlock) => latestFullyFetchedBlock
  | None => {
      blockNumber: knownHeight,
      // The case is only possible when using only block handlers
      // so it's fine to have a zero timestamp
      // since we don't support ordered multichain mode anyways
      blockTimestamp: 0,
    }
  }

  let mutItemsRef = ref(mutItems)

  let latestOnBlockBlockNumber = switch fetchState.onBlockConfigs {
  | [] => latestFullyFetchedBlock.blockNumber
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
      | None => latestFullyFetchedBlock.blockNumber
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
    latestFullyFetchedBlock,
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
                        prevPrevPrevQueryRange: p.prevPrevPrevQueryRange,
                      })
                    }
                  }
                }
              }
            }
          }
        }

        let registeringContracts = registeringContractsByContract->Js.Dict.unsafeGet(contractName)
        let addresses =
          registeringContracts->Js.Dict.keys->(Utils.magic: array<string> => array<Address.t>)

        let _ = Utils.Dict.mergeInPlace(newIndexingContracts, registeringContracts)

        // Can unsafely get it, because we already filtered out the contracts
        // that don't have any events to fetch
        let contractConfig = fetchState.contractConfigs->Js.Dict.unsafeGet(contractName)

        let byStartBlock = Js.Dict.empty()

        // I use for loops instead of forEach, so ReScript better inlines ref access
        for jdx in 0 to addresses->Array.length - 1 {
          let address = addresses->Js.Array2.unsafe_get(jdx)
          let indexingContract = registeringContracts->Js.Dict.unsafeGet(address->Address.toString)

          byStartBlock->Utils.Dict.push(indexingContract.startBlock->Int.toString, address)
        }

        // Will be in the ASC order by Js spec
        let ascKeys = byStartBlock->Js.Dict.keys

        let initialKey = ascKeys->Js.Array2.unsafe_get(0)

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
              blockNumber: Pervasives.max(startBlockRef.contents - 1, 0),
              blockTimestamp: 0,
            }
            while addressesRef.contents->Array.length > 0 {
              let pAddresses =
                addressesRef.contents->Js.Array2.slice(
                  ~start=0,
                  ~end_=fetchState.optimizedPartitions.maxAddrInPartition,
                )
              addressesRef.contents =
                addressesRef.contents->Js.Array2.sliceFrom(
                  fetchState.optimizedPartitions.maxAddrInPartition,
                )

              let addressesByContractName = Js.Dict.empty()
              addressesByContractName->Js.Dict.set(contractName, pAddresses)
              newPartitions->Array.push({
                id: (fetchState.optimizedPartitions.nextPartitionIndex +
                newPartitions->Array.length)->Int.toString,
                latestFetchedBlock,
                selection: fetchState.normalSelection,
                dynamicContract: Some(contractName),
                addressesByContractName,
                endBlock: None,
                mutPendingQueries: [],
                prevQueryRange: 0,
                prevPrevQueryRange: 0,
                prevPrevPrevQueryRange: 0,
              })
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

      fetchState->updateInternal(
        ~optimizedPartitions=OptimizedPartitions.make(
          ~dynamicContracts=dynamicContractsRef.contents,
          ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
          ~nextPartitionIndex=fetchState.optimizedPartitions.nextPartitionIndex +
          newPartitions->Array.length,
          ~partitions=mutExistingPartitions->Js.Array2.concat(newPartitions),
        ),
        ~indexingContracts=newIndexingContracts,
      )
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
  queries->Array.forEach(q => {
    let p = optimizedPartitions->OptimizedPartitions.getOrThrow(~partitionId=q.partitionId)

    // Add query to mutPendingQueries - will be removed when response arrives
    p.mutPendingQueries
    ->Array.push({
      fromBlock: q.fromBlock,
      toBlock: q.toBlock,
      isChunk: q.isChunk,
      fetchedBlock: None,
    })
    ->ignore
  })
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

// Calculate the chunk range from history using min-of-last-3-ranges heuristic
let getChunkRangeFromHistory = (p: partition) => {
  switch (p.prevQueryRange, p.prevPrevQueryRange, p.prevPrevPrevQueryRange) {
  | (0, _, _) | (_, 0, _) => None
  | (a, b, 0) => Some(a < b ? a : b)
  | (a, b, c) => Some(Js.Math.minMany_int([a, b, c]))
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
    // If a partition fetched further than 3 * batchSize,
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
    while idxRef.contents < partitionsCount && queries->Js.Array2.length < concurrencyLimit {
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

      // Allow creating new queries even if fetching, as long as no open-ended query exists
      let nextFromBlock = switch p.mutPendingQueries->Utils.Array.last {
      | Some({toBlock: Some(lastChunkToBlock), isChunk: true}) => Some(lastChunkToBlock + 1)
      | Some({isChunk: false}) => None // Non-chunk query is open-ended, so we can't create new chunks for the partition
      | _ =>
        switch p.latestFetchedBlock.blockNumber {
        | 0 => Some(0)
        | latestFetchedBlockNumber => Some(latestFetchedBlockNumber + 1)
        }
      }

      switch nextFromBlock {
      | None => ()
      | Some(nextFromBlock) => {
          let queryEndBlock = Utils.Math.minOptInt(fetchState.endBlock, p.endBlock)
          let queryEndBlock = switch blockLag {
          | 0 => queryEndBlock
          | _ =>
            // Force head block as an endBlock when blockLag is set
            // because otherwise HyperSync might return bigger range
            Utils.Math.minOptInt(Some(headBlockNumber), queryEndBlock)
          }
          // Enforce the respose range up until target block
          // Otherwise for indexers with 100+ partitions
          // we might blow up the buffer size to more than 600k events
          // simply because of HyperSync returning extra blocks
          let queryEndBlock = switch (queryEndBlock, maxQueryBlockNumber < knownHeight) {
          | (Some(endBlock), true) => Some(Pervasives.min(maxQueryBlockNumber, endBlock))
          | (None, true) => Some(maxQueryBlockNumber)
          | (_, false) => queryEndBlock
          }

          switch queryEndBlock {
          | Some(endBlock)
            if nextFromBlock > endBlock => // The query should wait for the execution.
            // This is a valid case when endBlock is artifitially limited
            ()
          | _ =>
            // Calculate chunk range from history for multi-query creation
            let maybeChunkRange = getChunkRangeFromHistory(p)

            switch maybeChunkRange {
            | None =>
              // No chunking - create single query
              queries->Array.push({
                partitionId,
                fromBlock: nextFromBlock,
                toBlock: queryEndBlock,
                selection: p.selection,
                isChunk: false,
                addressesByContractName: p.addressesByContractName,
                indexingContracts,
              })
            | Some(chunkRange) =>
              // Create multiple queries for this partition based on chunk range
              let maxBlock = switch queryEndBlock {
              | Some(eb) => eb
              | None => maxQueryBlockNumber
              }
              let remainingBlocks = maxBlock - nextFromBlock + 1
              let chunksNeeded = Js.Math.ceil_int(
                remainingBlocks->Int.toFloat /. chunkRange->Int.toFloat,
              )
              // Don't create more than 3 queries for the same partition
              let chunksLimit = Pervasives.min(3, concurrencyLimit - queries->Js.Array2.length)

              let chunkIdx = ref(0)

              while chunkIdx.contents < chunksLimit && chunkIdx.contents < chunksNeeded {
                let fromBlock = nextFromBlock + chunkIdx.contents * chunkRange
                let nextChunkIdx = chunkIdx.contents + 1
                let isLastNeeded = nextChunkIdx === chunksNeeded
                let isLastAllowed = nextChunkIdx === chunksLimit

                let chunkToBlock = if isLastNeeded {
                  queryEndBlock
                } else if isLastAllowed {
                  // For the last allowed chunk, fetch double range,
                  // so we can reevaluate the chunk range in the next query
                  Some(Pervasives.min(fromBlock + chunkRange * 2 - 1, maxBlock))
                } else {
                  Some(fromBlock + chunkRange - 1)
                }

                queries->Array.push({
                  partitionId,
                  fromBlock,
                  toBlock: chunkToBlock,
                  isChunk: chunkToBlock !== None,
                  selection: p.selection,
                  addressesByContractName: p.addressesByContractName,
                  indexingContracts,
                })
                chunkIdx := nextChunkIdx
              }
            }
          }
        }
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
      // No need to sort - queries are generated in ascending order from idsInAscOrder
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
      prevPrevPrevQueryRange: 0,
    })
  }

  let normalSelection = {
    dependsOnAddresses: true,
    eventConfigs: normalEventConfigs,
  }

  switch normalEventConfigs {
  | [] => ()
  | _ => {
      let makePendingNormalPartition = () => {
        {
          id: partitions->Array.length->Int.toString,
          latestFetchedBlock,
          selection: normalSelection,
          addressesByContractName: Js.Dict.empty(),
          endBlock: None,
          dynamicContract: None,
          mutPendingQueries: [],
          prevQueryRange: 0,
          prevPrevQueryRange: 0,
          prevPrevPrevQueryRange: 0,
        }
      }

      let pendingNormalPartition = ref(makePendingNormalPartition())

      contracts->Array.forEach(contract => {
        let contractName = contract.contractName
        if contractNamesWithNormalEvents->Utils.Set.has(contractName) {
          let pendingPartition = pendingNormalPartition.contents
          pendingPartition.addressesByContractName->Utils.Dict.push(contractName, contract.address)
          indexingContracts->Js.Dict.set(contract.address->Address.toString, contract)
          if (
            pendingPartition.addressesByContractName->addressesByContractNameCount ===
              maxAddrInPartition
          ) {
            // FIXME: should split into separate partitions
            // depending on the start block
            partitions->Array.push(pendingPartition)
            pendingNormalPartition := makePendingNormalPartition()
          }
        }
      })

      if pendingNormalPartition.contents.addressesByContractName->addressesByContractNameCount > 0 {
        partitions->Array.push(pendingNormalPartition.contents)
      }
    }
  }

  if partitions->Utils.Array.isEmpty && onBlockConfigs->Utils.Array.isEmpty {
    Js.Exn.raiseError(
      "Invalid configuration: Nothing to fetch. Make sure that you provided at least one contract address to index, or have events with Wildcard mode enabled, or have onBlock handlers.",
    )
  }

  let numAddresses = indexingContracts->Js.Dict.keys->Array.length
  Prometheus.IndexingAddresses.set(~addressesCount=numAddresses, ~chainId)
  Prometheus.IndexingPartitions.set(~partitionsCount=partitions->Array.length, ~chainId)
  Prometheus.IndexingBufferSize.set(~bufferSize=0, ~chainId)
  Prometheus.IndexingBufferBlockNumber.set(~blockNumber=latestFetchedBlock.blockNumber, ~chainId)
  switch endBlock {
  | Some(endBlock) => Prometheus.IndexingEndBlock.set(~endBlock, ~chainId)
  | None => ()
  }

  {
    optimizedPartitions: OptimizedPartitions.make(
      ~partitions,
      ~maxAddrInPartition,
      ~nextPartitionIndex=partitions->Array.length,
      ~dynamicContracts=Utils.Set.make(),
    ),
    contractConfigs,
    chainId,
    startBlock,
    endBlock,
    latestFullyFetchedBlock: latestFetchedBlock,
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
        prevPrevPrevQueryRange: p.prevPrevPrevQueryRange,
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
    latestOnBlockBlockNumber: targetBlockNumber, // FIXME: This is not tested. I assume there might be a possible issue of it skipping some blocks
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
// rollback to the earliest such query's fromBlock - 1. Otherwise just clear mutPendingQueries.
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
  | Some(fromBlock) =>
    // Fetched queries in the middle - rollback to just before that query.
    // This is not the most efficient in terms of overfetching, but the simplest
    // to implement. Ideally we shouldn't stop handling queries on rollback.
    fetchState->rollback(~targetBlockNumber=fromBlock - 1)
  | None =>
    // No fetched queries in middle - just use cleared pending queries
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
