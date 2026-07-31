type indexingAddress = Internal.indexingContract

type blockNumberAndTimestamp = {
  blockNumber: int,
  blockTimestamp: int,
}

type blockNumberAndLogIndex = {blockNumber: int, logIndex: int}

type selection = {
  onEventRegistrations: array<Internal.onEventRegistration>,
  // Whether the partition's queries are built from its own address list
  // (server-side address filtering). This is the *partition* property; not to
  // be confused with the per-registration `Internal.onEventRegistration.dependsOnAddresses`.
  dependsOnAddresses: bool,
  // Contract names this query fetches address-free even though their
  // registrations depend on addresses. The source passes these to the client so
  // their log selections carry no server-side address filter; the client then
  // gates each item against the chain's address store instead of the
  // partition's set. Absent for normal partitions.
  clientFilteredContracts?: array<string>,
  // The earliest block any of these registrations can produce an item at.
  // Derived once here, by `makeSelection`, because `getNextQuery` reads it for
  // every partition on every tick and a chain can hold hundreds of them.
  //
  // Absent when a registration is unrestricted and so can fire from the chain
  // start — which is also the only case where nothing can be skipped, so absent
  // and "block 0" are the same answer here. Build selections through
  // `makeSelection` rather than as literals, or this goes stale.
  startBlock?: int,
}

// The earliest block any of the registrations can produce an item at, or `None`
// when one of them is unrestricted. Nothing below it is worth querying.
let deriveSelectionStartBlock = (onEventRegistrations: array<Internal.onEventRegistration>) => {
  let earliest = ref(None)
  let idx = ref(0)
  let unrestricted = ref(onEventRegistrations->Utils.Array.isEmpty)
  while !unrestricted.contents && idx.contents < onEventRegistrations->Array.length {
    switch (onEventRegistrations->Array.getUnsafe(idx.contents)).startBlock {
    | None => unrestricted := true
    | Some(startBlock) =>
      switch earliest.contents {
      | Some(current) if current <= startBlock => ()
      | _ => earliest := Some(startBlock)
      }
    }
    idx := idx.contents + 1
  }
  unrestricted.contents ? None : earliest.contents
}

let makeSelection = (~onEventRegistrations, ~dependsOnAddresses, ~clientFilteredContracts=?) => {
  onEventRegistrations,
  dependsOnAddresses,
  ?clientFilteredContracts,
  startBlock: ?deriveSelectionStartBlock(onEventRegistrations),
}

type pendingQuery = {
  fromBlock: int,
  toBlock: option<int>,
  isChunk: bool,
  // Server maxNumLogs-style cap for this in-flight query. None for bounded
  // chunk/gap-fill queries, which send no cap (their toBlock is the bound).
  itemsTarget: option<int>,
  // Estimated items this in-flight query will return, carried from the query so
  // the shared buffer budget can account for what's already being fetched.
  itemsEst: int,
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
  // The partition's slice of the chain's address index. Ordered by
  // (effectiveStartBlock, address) inside Rust, so a partition layout is a pure
  // function of which addresses it holds — not of the order they arrived in.
  addresses: AddressSet.t,
  mergeBlock: option<int>,
  // When set, partition indexes a single dynamic contract type.
  // `addresses` must then contain only addresses for this contract.
  dynamicContract: option<string>,
  // Mutated in place and shared across fetchState versions (updateInternal
  // copies the record, not this array): startFetchingQueries inserts,
  // handleQueryResponse marks fetched and consumes, and the same array object
  // survives every copy. Invariant: any path that invalidates the fetch
  // frontier (reorg/rollback) must go through resetPendingQueries, otherwise a
  // stale version's in-flight bookkeeping leaks into the restored state.
  mutPendingQueries: array<pendingQuery>,
  // The last two ranges that measured how many blocks the source could return.
  // Both must be non-zero before the minimum is trusted for chunk sizing.
  sourceRangeCapacity: int,
  prevSourceRangeCapacity: int,
  // Smoothed items/block observed in responses. This is independent from the
  // source's range capacity: even a response truncated by our own itemsTarget
  // cap is useful density evidence while saying nothing about source capacity.
  // None distinguishes a new partition from a real zero-density observation.
  eventDensity: option<float>,
  // Tracks the latestFetchedBlock.blockNumber of the most recent response
  // that updated sourceRangeCapacity. Prevents degradation of the chunking
  // heuristic when parallel query responses arrive out of order.
  latestSourceRangeCapacityUpdateBlock: int,
}

type query = {
  partitionId: string,
  fromBlock: int,
  toBlock: option<int>,
  isChunk: bool,
  // Server-side maxNumLogs-style cap. Some only for open-ended probes, whose
  // range isn't otherwise bounded; None for bounded chunk/gap-fill queries,
  // whose toBlock already bounds the response so a cap would only self-truncate
  // (worse under client-side address filtering, which counts filtered-out items
  // toward the cap).
  itemsTarget: option<int>,
  // Density × the query's block range for a known-density partition, the
  // query's budget share otherwise. This is the unit the chain's per-tick
  // budget is reserved/consumed in and that sizes every query.
  itemsEst: int,
  selection: selection,
  addresses: AddressSet.t,
}

let withAddresses = (p: partition, addresses: AddressSet.t) => {...p, addresses}

// The selection a query over [fromBlock, toBlock] actually needs: a registration
// whose own start block sits past the range can't produce an item there, so
// leaving it out keeps the source from asking the server for its logs at all.
// The address gate can't express this — it's contract-wide, so an unrestricted
// sibling holds it open from the chain start for every registration alike.
//
// Returns the selection as-is when nothing is dropped (the common case), and
// for an open-ended query, which may reach any block and so can exclude nothing.
// Also when every registration would be dropped: `selectionStartBlock` keeps a
// partition's cursor at or above its earliest start block, so a query below all
// of them shouldn't exist — and an empty selection is one no source can build.
let narrowSelectionToRange = (selection: selection, ~toBlock) =>
  switch toBlock {
  | None => selection
  | Some(toBlock) =>
    let inRange = selection.onEventRegistrations->Array.filter(reg =>
      switch reg.startBlock {
      | Some(startBlock) => startBlock <= toBlock
      | None => true
      }
    )
    switch inRange->Array.length {
    // Every registration starts above the range. Narrowing to nothing would
    // build a selection with no log filters, which each source reads as
    // "select everything" — the opposite of the intent. The partition is
    // queried unnarrowed instead and the routers drop what hasn't started.
    | 0 => selection
    | length if length === selection.onEventRegistrations->Array.length => selection
    | _ =>
      makeSelection(
        ~onEventRegistrations=inRange,
        ~dependsOnAddresses=selection.dependsOnAddresses,
        ~clientFilteredContracts=?selection.clientFilteredContracts,
      )
    }
  }

// itemsEst for a query over [fromBlock, toBlock] at the given event density
// (items/block). toBlock None is the open-ended tail, capped at
// chainTargetBlock — the soft per-tick horizon the owning chain wants to reach
// (see getNextQuery).
let densityItemsTarget = (~density, ~fromBlock, ~toBlock, ~chainTargetBlock) => {
  // Floor at 1: this is the budget reservation, and for a probe also its server
  // cap — a 0 cap would ask the backend for nothing.
  Pervasives.max(
    1,
    ((toBlock->Option.getOr(chainTargetBlock) - fromBlock + 1)->Int.toFloat *. density)
    ->Math.ceil
    ->Float.toInt,
  )
}

// Calculate the chunk range from the last two source-capacity observations.
let getMinHistoryRange = (p: partition) => {
  switch (p.sourceRangeCapacity, p.prevSourceRangeCapacity) {
  | (0, _) | (_, 0) => None
  | (a, b) => Some(a < b ? a : b)
  }
}

// Density has its own initialization signal and is useful independently from
// source-capacity history, including when an itemsTarget cap truncates a response.
let getTrustedDensity = (p: partition) => p.eventDensity

// A response is still owed for this partition, so it owns range nothing else
// accounts for: removing it would let the frontier advance over blocks the
// response can still deliver items from, and orphan the response itself.
// Narrower than a non-empty queue on purpose — a settled query parked behind a
// gap is data already in hand, and waiting on it would wedge a partition that
// no longer queries.
let isFetching = (p: partition) => p.mutPendingQueries->Array.some(pq => pq.fetchedBlock === None)

let getMinQueryRange = (partitions: array<partition>) => {
  let min = ref(0)
  for i in 0 to partitions->Array.length - 1 {
    let p = partitions->Array.getUnsafe(i)

    // Even if it's fetching, set dynamicContract field
    let a = p.sourceRangeCapacity
    let b = p.prevSourceRangeCapacity
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
    // Contract names switched to client-side address filtering once their
    // registered address count crossed the server-side threshold. Sticky for
    // the run: their addresses live only in the index, their events are fetched
    // by the single address-free partition, and new dynamic addresses get a
    // bounded backfill up to its frontier instead of a standing partition.
    clientFilteredContracts: Utils.Set.t<string>,
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
    let combinedAddresses = p1.addresses->AddressSet.merge(p2.addresses)

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
      // event rate is the sum of their densities. If neither parent has a
      // trusted density, the merged partition probes for a fresh signal
      // instead of treating zero as an observed density.
      let inheritedDensity = switch (p1->getTrustedDensity, p2->getTrustedDensity) {
      | (Some(p1Density), Some(p2Density)) => Some(p1Density +. p2Density)
      | (Some(density), None) | (None, Some(density)) => Some(density)
      | (None, None) => None
      }
      {
        id: newId,
        dynamicContract: Some(contractName),
        selection: p1.selection,
        latestFetchedBlock: {blockNumber: potentialMergeBlock, blockTimestamp: 0},
        mergeBlock: None,
        addresses: p1.addresses, // replaced below
        mutPendingQueries: [],
        sourceRangeCapacity: minRange,
        prevSourceRangeCapacity: minRange,
        eventDensity: inheritedDensity,
        latestSourceRangeCapacityUpdateBlock: 0,
      }
    }

    // Apply address split on the continuing partition
    if combinedAddresses->AddressSet.size > maxAddrInPartition {
      completed
      ->Array.push(
        continuingBase->withAddresses(
          combinedAddresses->AddressSet.slice(~offset=0, ~limit=Some(maxAddrInPartition)),
        ),
      )
      ->ignore
      let restId = nextPartitionIndexRef.contents->Int.toString
      nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
      completed
      ->Array.push({
        ...continuingBase->withAddresses(
          combinedAddresses->AddressSet.slice(~offset=maxAddrInPartition, ~limit=None),
        ),
        id: restId,
        mutPendingQueries: [],
      })
      ->ignore
      completed
    } else {
      completed->Array.push(continuingBase->withAddresses(combinedAddresses))->ignore
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

  // Contracts a standing address-free partition already fetches client-side.
  // Addresses registered for them after that partition passed get a normal
  // address-bound partition which dies once it catches up (see make), instead
  // of being folded into the address-free one.
  let anchoredContracts = (partitions: array<partition>) => {
    let set = Utils.Set.make()
    partitions->Array.forEach(p =>
      switch (p.mergeBlock, p.selection.clientFilteredContracts) {
      | (None, Some(contractNames)) =>
        contractNames->Array.forEach(name => set->Utils.Set.add(name)->ignore)
      | _ => ()
      }
    )
    set
  }

  // The furthest block an address-free partition's already-dispatched queries
  // can deliver without the addresses registered from now on. A settled query
  // claims only what it actually fetched — the rest of its range is re-queried
  // later, by then against the updated address store — while an in-flight
  // bounded query claims its whole toBlock. An in-flight unbounded query has no
  // ceiling at all, so nothing is safe to stop a catch-up partition at yet.
  let getAnchorSafeBlock = (p: partition) => {
    let safeRef = ref(Some(p.latestFetchedBlock.blockNumber))
    p.mutPendingQueries->Array.forEach(pq =>
      switch (safeRef.contents, pq) {
      | (None, _) => ()
      | (Some(safe), {fetchedBlock: Some({blockNumber})}) =>
        if blockNumber > safe {
          safeRef := Some(blockNumber)
        }
      | (Some(safe), {toBlock: Some(toBlock)}) =>
        if toBlock > safe {
          safeRef := Some(toBlock)
        }
      | (Some(_), _) => safeRef := None
      }
    )
    safeRef.contents
  }

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
    ~clientFilteredContracts: Utils.Set.t<string>,
  ) => {
    let newPartitions = []
    let mergingPartitions = Dict.make()
    let nextPartitionIndexRef = ref(nextPartitionIndex)

    // Where a catch-up partition for a client-filtered contract may stop, keyed
    // by contract name. A contract absent from the dict while present in
    // anchoredContractsSet has an unbounded query in flight on its address-free
    // partition — its catch-up can't be bounded yet, and a later call will bound it.
    let anchorSafeBlocks = Dict.make()
    let anchoredContractsSet = Utils.Set.make()
    if clientFilteredContracts->Utils.Set.size > 0 {
      partitions->Array.forEach(p =>
        switch (p.mergeBlock, p.selection.clientFilteredContracts) {
        | (None, Some(contractNames)) =>
          let safeBlock = p->getAnchorSafeBlock
          contractNames->Array.forEach(name => {
            anchoredContractsSet->Utils.Set.add(name)->ignore
            switch safeBlock {
            | Some(safeBlock) => anchorSafeBlocks->Dict.set(name, safeBlock)
            | None => ()
            }
          })
        | _ => ()
        }
      )
    }

    for idx in 0 to partitions->Array.length - 1 {
      let p = partitions->Array.getUnsafe(idx)
      switch p {
      // For now don't merge partitions with mergeBlock,
      // assuming they are already merged,
      // TODO: Although there might be cases with too far away mergeBlock,
      // which is worth merging.
      // A partition already at or past its merge block is done — normally
      // handleQueryResponse removes it when the response lands, but a rollback
      // can cap the merge block at the rolled-back frontier, leaving no
      // response to ever remove it on. A retired partition still awaiting a
      // response stays until it lands.
      | {mergeBlock: Some(mergeBlock)} =>
        if p.latestFetchedBlock.blockNumber < mergeBlock || p->isFetching {
          newPartitions->Array.push(p)->ignore
        }
      // Since it's not a dynamic contract partition,
      // there's no need for merge logic
      | {dynamicContract: None}
      | // Wildcard doesn't need merging
      {selection: {dependsOnAddresses: false}} =>
        newPartitions->Array.push(p)->ignore
      | {dynamicContract: Some(contractName)} =>
        let pAddressesCount = p.addresses->AddressSet.countFor(contractName)
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

    // A dynamic partition for a contract the address-free partition already
    // fetches is a catch-up for addresses registered after that partition
    // passed them. It merges by disappearing once it reaches the last block
    // that partition's dispatched queries could have missed them on — its
    // addresses are in the chain's store, so there is nothing to hand over.
    let finalPartitions = if anchoredContractsSet->Utils.Set.size === 0 {
      newPartitions
    } else {
      let anchored = []
      newPartitions->Array.forEach(p =>
        switch p {
        | {dynamicContract: Some(contractName), mergeBlock: None}
          if anchoredContractsSet->Utils.Set.has(contractName) =>
          switch anchorSafeBlocks->Utils.Dict.dangerouslyGetNonOption(contractName) {
          | None => anchored->Array.push(p)->ignore
          | Some(anchorSafeBlock) =>
            if p.latestFetchedBlock.blockNumber < anchorSafeBlock {
              anchored->Array.push({...p, mergeBlock: Some(anchorSafeBlock)})->ignore
            } else if p->isFetching {
              // Caught up, but a response is still owed: keep it until that
              // lands rather than dropping the range it owns.
              anchored
              ->Array.push({...p, mergeBlock: Some(p.latestFetchedBlock.blockNumber)})
              ->ignore
            }
          }
        | _ => anchored->Array.push(p)->ignore
        }
      )
      anchored
    }

    // Sort partitions by latestFetchedBlock ascending
    let _ = finalPartitions->Array.sort(ascSortFn)

    let partitionsCount = finalPartitions->Array.length
    let idsInAscOrder = Utils.Array.jsArrayCreate(partitionsCount)
    let entities = Dict.make()
    for idx in 0 to partitionsCount - 1 {
      let p = finalPartitions->Array.getUnsafe(idx)
      idsInAscOrder->Array.setUnsafe(idx, p.id)
      entities->Dict.set(p.id, p)
    }

    {
      idsInAscOrder,
      entities,
      maxAddrInPartition,
      nextPartitionIndex: nextPartitionIndexRef.contents,
      dynamicContracts,
      clientFilteredContracts,
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

    let consumedCount = ref(0)
    let canContinue = ref(true)
    while canContinue.contents {
      switch mutPendingQueries->Array.get(consumedCount.contents) {
      | Some({fetchedBlock: Some(fetchedBlock), fromBlock})
        if fromBlock <= latestFetchedBlock.contents.blockNumber + 1 =>
        latestFetchedBlock := fetchedBlock
        consumedCount := consumedCount.contents + 1
      | _ => canContinue := false
      }
    }
    if consumedCount.contents > 0 {
      mutPendingQueries->Array.splice(~start=0, ~remove=consumedCount.contents, ~insert=[])->ignore
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

  // Every path that stops a partition from fetching keeps it until its last
  // response lands, so a response always has a partition to advance. A rollback
  // does delete partitions mid-run, but it bumps the indexer epoch and
  // ChainFetching drops older responses before they reach here.
  let rec handleQueryResponse = (
    optimizedPartitions: t,
    ~query,
    ~knownHeight,
    ~itemsCount,
    ~latestFetchedBlock: blockNumberAndTimestamp,
  ) =>
    optimizedPartitions->handleQueryResponseForPartition(
      ~p=optimizedPartitions->getOrThrow(~partitionId=query.partitionId),
      ~query,
      ~knownHeight,
      ~itemsCount,
      ~latestFetchedBlock,
    )

  and handleQueryResponseForPartition = (
    optimizedPartitions: t,
    ~p: partition,
    ~query,
    ~knownHeight,
    ~itemsCount,
    ~latestFetchedBlock: blockNumberAndTimestamp,
  ) => {
    let mutEntities = optimizedPartitions.entities->Utils.Dict.shallowCopy

    // Mark query as fetched
    let pendingQuery = getPendingQueryOrThrow(p, ~fromBlock=query.fromBlock)
    pendingQuery.fetchedBlock = Some(latestFetchedBlock)

    let blockRange = latestFetchedBlock.blockNumber - query.fromBlock + 1
    // Update density for every response, independently from whether this range
    // is valid evidence of source capacity. A cap hit is still useful density
    // evidence because it reports items returned across the scanned range.
    let observedEventDensity = itemsCount->Int.toFloat /. blockRange->Int.toFloat
    // Seed from the first observation, then smooth every later observation
    // with a 1:1 moving average. Keeping initialization explicit is important:
    // zero is valid density evidence and must participate in the next blend.
    let updatedEventDensity = switch p.eventDensity {
    | None => Some(observedEventDensity)
    | Some(eventDensity) => Some((eventDensity +. observedEventDensity) /. 2.)
    }

    // Skip updating source capacity if a later response already updated it.
    // Prevents degradation of the chunking heuristic when parallel query
    // responses arrive out of order (e.g. earlier query with smaller range
    // arriving after a later query with bigger range).
    let shouldUpdateSourceRangeCapacity =
      latestFetchedBlock.blockNumber > p.latestSourceRangeCapacityUpdateBlock &&
        switch query.toBlock {
        | None =>
          // Don't update source capacity when very close to the head.
          latestFetchedBlock.blockNumber < knownHeight - 10
        | Some(queryToBlock) =>
          if latestFetchedBlock.blockNumber < queryToBlock {
            // Partial response is direct capacity evidence — unless it was
            // truncated by our own itemsTarget cap: that reflects the
            // reservation we asked for, not what the server could return. A
            // capless bounded query can only have been truncated by the source.
            switch query.itemsTarget {
            | None => true
            | Some(itemsTarget) => itemsCount < itemsTarget
            }
          } else {
            // A full response updates only when the query's intended range
            // covers at least the partition's current chunk range — meaning it
            // was a capacity-based split chunk, not a small gap-fill whose
            // toBlock is an artificial boundary.
            switch getMinHistoryRange(p) {
            | None => false // Chunking not active yet, don't update
            | Some(minHistoryRange) => queryToBlock - query.fromBlock + 1 >= minHistoryRange
            }
          }
        }
    let updatedSourceRangeCapacity = shouldUpdateSourceRangeCapacity
      ? blockRange
      : p.sourceRangeCapacity
    let updatedPrevSourceRangeCapacity = shouldUpdateSourceRangeCapacity
      ? p.sourceRangeCapacity
      : p.prevSourceRangeCapacity

    // Process fetched queries from front of queue for main partition
    let updatedLatestFetchedBlock = consumeFetchedQueries(
      p.mutPendingQueries,
      ~initialLatestFetchedBlock=p.latestFetchedBlock,
    )

    // Check if partition reached its mergeBlock and should be removed. A
    // retired partition can hold several queries at once, so it goes only when
    // the last of them has landed.
    let partitionReachedMergeBlock =
      switch p.mergeBlock {
      | Some(mergeBlock) => updatedLatestFetchedBlock.blockNumber >= mergeBlock
      | None => false
      } &&
      !(p->isFetching)

    if partitionReachedMergeBlock {
      mutEntities->Utils.Dict.deleteInPlace(p.id)

      // Re-optimize to maintain sorted order and apply optimizations
      make(
        ~partitions=mutEntities->Dict.valuesToArray,
        ~maxAddrInPartition=optimizedPartitions.maxAddrInPartition,
        ~nextPartitionIndex=optimizedPartitions.nextPartitionIndex,
        ~dynamicContracts=optimizedPartitions.dynamicContracts,
        ~clientFilteredContracts=optimizedPartitions.clientFilteredContracts,
      )
    } else {
      let updatedMainPartition = {
        ...p,
        latestFetchedBlock: updatedLatestFetchedBlock,
        sourceRangeCapacity: updatedSourceRangeCapacity,
        prevSourceRangeCapacity: updatedPrevSourceRangeCapacity,
        eventDensity: updatedEventDensity,
        latestSourceRangeCapacityUpdateBlock: shouldUpdateSourceRangeCapacity
          ? latestFetchedBlock.blockNumber
          : p.latestSourceRangeCapacityUpdateBlock,
      }

      mutEntities->Dict.set(p.id, updatedMainPartition)

      if optimizedPartitions.dynamicContracts->Utils.Set.size === 0 {
        // Fast path: merging only ever applies to dynamic-contract partitions,
        // so with none registered a full make() would just re-sort. The updated
        // partition's frontier only advances (consumeFetchedQueries never moves
        // it back), so restoring idsInAscOrder is a single rightward walk of
        // its id — and usually a no-op.
        let ids = optimizedPartitions.idsInAscOrder
        let count = ids->Array.length
        let idx = ids->Array.indexOf(p.id)
        let isAfter = jdx =>
          jdx < count &&
            (
              mutEntities->Dict.getUnsafe(ids->Array.getUnsafe(jdx))
            ).latestFetchedBlock.blockNumber <
            updatedMainPartition.latestFetchedBlock.blockNumber
        if isAfter(idx + 1) {
          let reordered = ids->Array.copy
          let jdx = ref(idx)
          while isAfter(jdx.contents + 1) {
            reordered->Array.setUnsafe(jdx.contents, ids->Array.getUnsafe(jdx.contents + 1))
            jdx := jdx.contents + 1
          }
          reordered->Array.setUnsafe(jdx.contents, p.id)
          {...optimizedPartitions, entities: mutEntities, idsInAscOrder: reordered}
        } else {
          {...optimizedPartitions, entities: mutEntities}
        }
      } else {
        // Re-optimize to check for merge opportunities and maintain sorted order
        make(
          ~partitions=mutEntities->Dict.valuesToArray,
          ~maxAddrInPartition=optimizedPartitions.maxAddrInPartition,
          ~nextPartitionIndex=optimizedPartitions.nextPartitionIndex,
          ~dynamicContracts=optimizedPartitions.dynamicContracts,
          ~clientFilteredContracts=optimizedPartitions.clientFilteredContracts,
        )
      }
    }
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
  // Not used for logic - only metadata
  chainId: ChainId.t,
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
  // Per-contract registered-address count past which a dynamic contract is
  // switched to client-side filtering. None disables the switch, leaving every
  // contract filtered server-side.
  clientFilterAddressThreshold: option<int>,
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
let getRegistrationIndex = (item: Internal.item): int =>
  switch item {
  | Event({onEventRegistration}) => onEventRegistration.index
  | Block({onBlockRegistration}) => onBlockRegistration.index
  }

// Total order on buffer items: block, then logIndex, then registration index.
// Returns a plain int (-1/0/1) with explicit field comparisons so it can be
// called directly from the merge/insertion loops below — no Array.sort callback,
// no allocated key. `0` means a true duplicate: same log routed to the same
// registration (two registrations for one log differ by index and are kept).
let compareBufferItem = (a: Internal.item, b: Internal.item): int => {
  let ba = a->Internal.getItemBlockNumber
  let bb = b->Internal.getItemBlockNumber
  if ba != bb {
    ba < bb ? -1 : 1
  } else {
    let la = a->Internal.getItemLogIndex
    let lb = b->Internal.getItemLogIndex
    if la != lb {
      la < lb ? -1 : 1
    } else {
      let ia = a->getRegistrationIndex
      let ib = b->getRegistrationIndex
      ia < ib ? -1 : ia > ib ? 1 : 0
    }
  }
}

// Merge a maybe-unsorted `newItems` run into the already-sorted, already-deduped
// `buffer`, dropping items equal on (blockNumber, logIndex, registration index).
// Single linear pass over both runs after ordering `newItems` in place; every
// comparison is a direct `compareBufferItem` call (V8 inlines it) rather than a
// callback through `Array.sort`.
let mergeIntoBuffer = (buffer: array<Internal.item>, newItems: array<Internal.item>): array<
  Internal.item,
> => {
  let n = newItems->Array.length
  // Insertion sort: a source response is small and usually already ascending,
  // so this is ~O(n) here.
  for i in 1 to n - 1 {
    let x = newItems->Array.getUnsafe(i)
    let j = ref(i - 1)
    while j.contents >= 0 && compareBufferItem(newItems->Array.getUnsafe(j.contents), x) > 0 {
      newItems->Array.setUnsafe(j.contents + 1, newItems->Array.getUnsafe(j.contents))
      j := j.contents - 1
    }
    newItems->Array.setUnsafe(j.contents + 1, x)
  }

  let m = buffer->Array.length
  let merged = []
  let last = ref(None)
  let push = item =>
    switch last.contents {
    | Some(l) if compareBufferItem(l, item) === 0 => ()
    | _ => {
        merged->Array.push(item)
        last := Some(item)
      }
    }

  let i = ref(0)
  let j = ref(0)
  while i.contents < m && j.contents < n {
    let a = buffer->Array.getUnsafe(i.contents)
    let b = newItems->Array.getUnsafe(j.contents)
    if compareBufferItem(a, b) <= 0 {
      push(a)
      i := i.contents + 1
    } else {
      push(b)
      j := j.contents + 1
    }
  }
  while i.contents < m {
    push(buffer->Array.getUnsafe(i.contents))
    i := i.contents + 1
  }
  while j.contents < n {
    push(newItems->Array.getUnsafe(j.contents))
    j := j.contents + 1
  }
  merged
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
  // Set when the caller already passes a sorted, deduped buffer (hot paths merge
  // via mergeIntoBuffer or filter the sorted buffer). Otherwise mutItems is
  // normalized here, so callers can hand over items in any order.
  ~mutItemsSorted=false,
  ~blockLag=fetchState.blockLag,
  ~knownHeight=fetchState.knownHeight,
): t => {
  // The buffer to build on: the caller's items (normalized to sorted if needed),
  // or the current buffer when only onBlock items change.
  let base = switch mutItems {
  | Some(items) => mutItemsSorted ? items : []->mergeIntoBuffer(items)
  | None => fetchState.buffer
  }

  // onBlock items are generated as their own ascending (block, logIndex) run and
  // folded into `base` by the single merge below.
  let blockItems = []
  let latestOnBlockBlockNumber = switch fetchState.onBlockRegistrations {
  | [] => knownHeight
  | onBlockRegistrations =>
    // Calculate the max block number we are going to create items for
    // Use maxOnBlockBufferSize to get the last target item in the buffer
    // (sorted, so this is the highest-block item within the buffer cap).
    // All this needed to prevent OOM when adding too many block items to the queue
    let maxBlockNumber = switch base->Array.get(fetchState.maxOnBlockBufferSize - 1) {
    | Some(item) => item->Internal.getItemBlockNumber
    | None =>
      switch optimizedPartitions->OptimizedPartitions.getLatestFullyFetchedBlock {
      | None => knownHeight
      | Some(latestFullyFetchedBlock) => latestFullyFetchedBlock.blockNumber
      }
    }
    appendOnBlockItems(
      ~mutItems=blockItems,
      ~onBlockRegistrations,
      ~indexerStartBlock=fetchState.startBlock,
      ~fromBlock=fetchState.latestOnBlockBlockNumber,
      ~maxBlockNumber,
      ~maxOnBlockBufferSize=fetchState.maxOnBlockBufferSize,
    )
  }

  let updatedFetchState = {
    startBlock: fetchState.startBlock,
    endBlock: fetchState.endBlock,
    normalSelection: fetchState.normalSelection,
    chainId: fetchState.chainId,
    onBlockRegistrations: fetchState.onBlockRegistrations,
    maxOnBlockBufferSize: fetchState.maxOnBlockBufferSize,
    optimizedPartitions,
    latestOnBlockBlockNumber,
    blockLag,
    knownHeight,
    // Single merge point: fold any onBlock items into the sorted base buffer.
    buffer: switch blockItems {
    | [] => base
    | blockItems => base->mergeIntoBuffer(blockItems)
    },
    firstEventBlock: fetchState.firstEventBlock,
    clientFilterAddressThreshold: fetchState.clientFilterAddressThreshold,
  }

  updatedFetchState
}

// Move a contract to client-side address filtering, recording why.
let addClientFilteredContract = (
  clientFilteredContracts: Utils.Set.t<string>,
  ~contractName,
  ~chainId,
  ~addressCount,
  ~threshold,
  // A resumed fetch state re-derives the switch from the persisted addresses,
  // but it already happened - and was logged - in the run that crossed the
  // threshold.
  ~shouldLog=true,
) => {
  clientFilteredContracts->Utils.Set.add(contractName)->ignore
  if shouldLog {
    Logging.createChild(
      ~params={
        "chainId": chainId,
        "contractName": contractName,
        "addressCount": addressCount,
        "threshold": threshold,
      },
    )->Logging.childTrace(
      "Switching contract to client-side address filtering: registered address count crossed the server-side threshold.",
    )
  }
}

// The block a partition will have fetched to once everything on its pending
// queue lands — not the block it has fetched to now. A backfill has to reach it
// rather than the frontier: a query that was routed before this batch's
// addresses reached the address store carries no events for them, yet it still
// advances the frontier over its range on arrival, and nothing else would ever
// refetch it. An in-flight open-ended query has no toBlock of its own; it can't
// return past the chain's known height, so that bounds it.
let claimedFetchedBlock = (p: partition, ~knownHeight) =>
  p.mutPendingQueries->Array.reduce(p.latestFetchedBlock.blockNumber, (max, q) =>
    Pervasives.max(
      max,
      switch q.fetchedBlock {
      | Some({blockNumber}) => blockNumber
      | None => q.toBlock->Option.getOr(knownHeight)
      },
    )
  )

// Fold every client-filtered contract's server-side partitions into client-side
// fetching without tearing down established state:
// - The standing address-free partition (no mergeBlock) keeps its id, frontier,
//   in-flight queries and learned density. Only when a newly-switched contract
//   must be added does its selection change — under a fresh id, so responses
//   built from the old selection can't advance the frontier past ranges the new
//   contract wasn't fetched for. The old generation is retired beside it,
//   keeping the queue those responses belong to.
// - Partitions absorbed below the standing partition's claimed block
//   (single-contract dynamic partitions and config partitions all of whose
//   contracts are client-filtered, plus any prior backfill) become one bounded
//   backfill partition covering [their min frontier, that claimed block]:
//   getNextQuery caps its queries at mergeBlock and handleQueryResponse deletes
//   it on arrival. The overlap it re-delivers is deduped by mergeIntoBuffer, and
//   the re-fetch doubles as history for freshly registered addresses: events
//   dropped before the address was registered now pass the address gate.
// - A dynamic partition for a contract the standing partition already covers is
//   left alone: it is a catch-up for addresses registered after that partition
//   passed them, and OptimizedPartitions.make bounds it against the standing
//   partition's own claims instead.
// - A partition mixing client-filtered and server-side contracts stays,
//   stripped of the client-filtered contracts' addresses — the address-free
//   partition covers those logs, so fetching them server-side too would only
//   produce duplicates. Its frontier bounds the backfill from below so the
//   stripped contracts lose no range.
//
// Registrations come from the address-free partitions plus `normalSelection`
// filtered to client-filtered contracts, so coverage never depends on which
// partitions happened to be absorbed (a stripped contract may have no
// absorbable partition at all).
let collapseClientFilteredContracts = (
  partitions: array<partition>,
  ~clientFilteredContracts: Utils.Set.t<string>,
  ~normalSelection: selection,
  ~nextPartitionIndexRef: ref<int>,
  ~addressStore: AddressStore.t,
  // Frontiers of the addresses that were never given a server-side partition
  // because their contract is already client-filtered. They stand in for the
  // partitions that would otherwise have been created only to be absorbed here.
  ~clientFilteredFrontiers: array<blockNumberAndTimestamp>=[],
  ~knownHeight: int,
) => {
  if clientFilteredContracts->Utils.Set.size === 0 {
    partitions
  } else {
    let kept = []
    let standingRef = ref(None)
    let backfills = []
    let absorbedPartitions = []
    let strippedFrontiers = []
    let anchoredContracts = partitions->OptimizedPartitions.anchoredContracts

    // Retire a partition in place of removing it: same id and selection, same
    // pending queue, capped at its own frontier so it issues nothing more. It
    // holds the frontier down and owns its in-flight response until that lands,
    // then handleQueryResponse drops it.
    let retire = (p: partition) => {
      ...p,
      mergeBlock: Some(p.latestFetchedBlock.blockNumber),
    }
    let absorb = p => {
      absorbedPartitions->Array.push(p)->ignore
      if p->isFetching {
        kept->Array.push(p->retire)->ignore
      }
    }

    partitions->Array.forEach(p =>
      switch p {
      | {selection: {dependsOnAddresses: false}, mergeBlock: None}
        if standingRef.contents->Option.isNone =>
        standingRef := Some(p)
      | {selection: {dependsOnAddresses: false}, mergeBlock: Some(_)} =>
        backfills->Array.push(p)->ignore

        // The backfill this call builds covers its remaining range from the
        // same min frontier, so it is superseded — but not before the response
        // it is waiting on lands.
        if p->isFetching {
          kept->Array.push(p->retire)->ignore
        }
      | {selection: {dependsOnAddresses: false}} => p->absorb
      | _ =>
        let contractNames = p.addresses->AddressSet.contractNames
        let serverSideNames =
          contractNames->Array.filter(c => !(clientFilteredContracts->Utils.Set.has(c)))
        if serverSideNames->Array.length === contractNames->Array.length {
          kept->Array.push(p)->ignore
        } else if (
          switch p.dynamicContract {
          | Some(contractName) => anchoredContracts->Utils.Set.has(contractName)
          | None => false
          }
        ) {
          // A catch-up partition for addresses registered after the address-free
          // partition already covered their contract. It is the correctness
          // barrier for those addresses until it catches up — absorbing it would
          // hand that job back to a guessed ceiling.
          kept->Array.push(p)->ignore
        } else if serverSideNames->Utils.Array.isEmpty {
          p->absorb
        } else {
          strippedFrontiers->Array.push(p.latestFetchedBlock)->ignore
          kept
          ->Array.push(p->withAddresses(p.addresses->AddressSet.filterByContracts(serverSideNames)))
          ->ignore
        }
      }
    )

    let selectionChanged = switch standingRef.contents {
    | Some(standing) =>
      standing.selection.clientFilteredContracts->Option.mapOr(0, Array.length) !==
        clientFilteredContracts->Utils.Set.size
    | None => true
    }

    if (
      absorbedPartitions->Utils.Array.isEmpty &&
      strippedFrontiers->Utils.Array.isEmpty &&
      clientFilteredFrontiers->Utils.Array.isEmpty &&
      !selectionChanged
    ) {
      // Nothing to fold in and no newly-switched contract: leave the standing
      // partition (and any in-progress backfill) untouched.
      partitions
    } else {
      let minFrontierRef: ref<option<blockNumberAndTimestamp>> = ref(None)
      let considerFrontier = (b: blockNumberAndTimestamp) =>
        switch minFrontierRef.contents {
        | Some(m) if m.blockNumber <= b.blockNumber => ()
        | _ => minFrontierRef := Some(b)
        }
      absorbedPartitions->Array.forEach(p => considerFrontier(p.latestFetchedBlock))
      backfills->Array.forEach(p => considerFrontier(p.latestFetchedBlock))
      strippedFrontiers->Array.forEach(considerFrontier)
      clientFilteredFrontiers->Array.forEach(considerFrontier)

      let regByIndex = Dict.make()
      let addRegs = (regs: array<Internal.onEventRegistration>) =>
        regs->Array.forEach(reg => regByIndex->Dict.set(reg.index->Int.toString, reg))
      switch standingRef.contents {
      | Some(standing) => addRegs(standing.selection.onEventRegistrations)
      | None => ()
      }
      absorbedPartitions->Array.forEach(p =>
        if !p.selection.dependsOnAddresses {
          addRegs(p.selection.onEventRegistrations)
        }
      )
      addRegs(
        normalSelection.onEventRegistrations->Array.filter(reg =>
          clientFilteredContracts->Utils.Set.has(reg.eventConfig.contractName)
        ),
      )
      let newSelection = makeSelection(
        ~dependsOnAddresses=false,
        ~onEventRegistrations=regByIndex->Dict.valuesToArray,
        ~clientFilteredContracts=clientFilteredContracts->Utils.Set.toArray,
      )

      switch standingRef.contents {
      | None =>
        // First switch: no standing partition to preserve, so create it at the
        // min frontier directly — the whole range above is unfetched for the
        // client-filtered side anyway.
        switch minFrontierRef.contents {
        | None => kept
        | Some(minFrontier) =>
          let minRange = getMinQueryRange(absorbedPartitions)
          let id = nextPartitionIndexRef.contents->Int.toString
          nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
          kept
          ->Array.push({
            id,
            latestFetchedBlock: minFrontier,
            selection: newSelection,
            addresses: addressStore->AddressStore.emptySet,
            mergeBlock: None,
            dynamicContract: None,
            mutPendingQueries: [],
            sourceRangeCapacity: minRange,
            prevSourceRangeCapacity: minRange,
            eventDensity: None,
            latestSourceRangeCapacityUpdateBlock: 0,
          })
          ->ignore
          kept
        }
      | Some(standing) =>
        let standingOut = if selectionChanged {
          let id = nextPartitionIndexRef.contents->Int.toString
          nextPartitionIndexRef := nextPartitionIndexRef.contents + 1

          // A response built from the old selection must not advance the new
          // one's frontier over ranges the newly-switched contract wasn't
          // fetched for, so the continuing partition takes a fresh id and an
          // empty queue. The old generation is retired beside it rather than
          // dropped: it keeps the queue those responses belong to.
          if standing->isFetching {
            kept->Array.push(standing->retire)->ignore
          }
          {...standing, id, selection: newSelection, mutPendingQueries: []}
        } else {
          standing
        }
        kept->Array.push(standingOut)->ignore
        // Read off standingOut, not standing: a selection change orphans the
        // in-flight queries (fresh id, empty queue), so there the frontier is
        // all the partition will ever claim.
        let catchUpToBlock = standingOut->claimedFetchedBlock(~knownHeight)
        switch minFrontierRef.contents {
        | Some(minFrontier) if minFrontier.blockNumber < catchUpToBlock =>
          let id = nextPartitionIndexRef.contents->Int.toString
          nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
          kept
          ->Array.push({
            id,
            latestFetchedBlock: minFrontier,
            selection: newSelection,
            addresses: addressStore->AddressStore.emptySet,
            mergeBlock: Some(catchUpToBlock),
            dynamicContract: None,
            mutPendingQueries: [],
            // Same query shape as the standing partition, so inherit its
            // learned range and density instead of probing from scratch.
            sourceRangeCapacity: standing.sourceRangeCapacity,
            prevSourceRangeCapacity: standing.prevSourceRangeCapacity,
            eventDensity: standing.eventDensity,
            latestSourceRangeCapacityUpdateBlock: 0,
          })
          ->ignore
        // An absorbed frontier at/above the claimed block needs no backfill:
        // nothing has fetched past there yet, so the standing partition still
        // covers it going forward.
        | _ => ()
        }
        kept
      }
    }
  }
}

let warnAddressRegistration = (
  ~chainId: ChainId.t,
  ~contractAddress: Address.t,
  ~params,
  message,
) =>
  Logging.createChild(
    ~params={
      "chainId": chainId,
      "contractAddress": contractAddress->Address.toString,
      "details": params,
    },
  )->Logging.childWarn(message)

// A rejected registration is simply absent from every partition, so without a
// warning the user sees a contract that never indexes and nothing saying why.
// Shared by config-time registration in `make` and by dynamic registration.
let warnRejectedRegistration = (
  verdict: AddressStore.verdict,
  ~chainId: ChainId.t,
  ~contractAddress: Address.t,
  ~contractName: string,
) =>
  switch verdict {
  | Conflict({existingContractName}) =>
    warnAddressRegistration(
      ~chainId,
      ~contractAddress,
      ~params={
        "existingContractType": existingContractName,
        "newContractType": contractName,
      },
      `Skipping contract registration: Contract address is already registered for one contract and cannot be registered for another contract.`,
    )
  | Duplicate({effectiveStartBlock, existingEffectiveStartBlock}) =>
    // FIXME: Instead of filtering out duplicates, we should check the block
    // number first. If a new registration has an earlier block number we
    // should register it for the missing block range.
    if existingEffectiveStartBlock > effectiveStartBlock {
      warnAddressRegistration(
        ~chainId,
        ~contractAddress,
        ~params={
          "existingBlockNumber": existingEffectiveStartBlock,
          "newBlockNumber": effectiveStartBlock,
        },
        `Skipping contract registration: Contract address is already registered at a later block number. Currently registration of the same contract address is not supported by Envio. Reach out to us if it's a problem for you.`,
      )
    }
  | Invalid =>
    warnAddressRegistration(
      ~chainId,
      ~contractAddress,
      ~params={"contractName": contractName},
      `Skipping contract registration: Not a valid address for this chain's ecosystem.`,
    )
  | Added(_) => ()
  }

/**
Creates partitions from indexing addresses with two phases:
Phase 1: Create per-contract-name partitions (smart grouping by startBlock)
Phase 2: Merge non-dynamic partitions together to reduce unnecessary concurrency
Returns OptimizedPartitions.t directly.
(Dynamic partitions are merged by OptimizedPartitions.make automatically)
*/
let createPartitions = (
  // One set per contract, holding the addresses that still need a partition:
  // a batch's fresh registrations, or the survivors of a rolled-back partition.
  ~registeringSetsByContract: dict<AddressSet.t>,
  ~addressStore: AddressStore.t,
  ~dynamicContracts: Utils.Set.t<string>,
  ~clientFilteredContracts: Utils.Set.t<string>,
  ~normalSelection: selection,
  ~maxAddrInPartition: int,
  ~nextPartitionIndex: int,
  ~existingPartitions: array<partition>,
  ~progressBlockNumber: int,
  ~knownHeight: int,
): // Floor for latestFetchedBlock (use progressBlockNumber from make, or 0 for registerDynamicContracts)
OptimizedPartitions.t => {
  let nextPartitionIndexRef = ref(nextPartitionIndex)

  // ── Phase 1: Create per-contract-name partitions ──
  let dynamicPartitions = []
  let nonDynamicPartitions = []
  let clientFilteredFrontiers = []

  // Contracts an address-free partition already fetches. Their new addresses
  // need a partition of their own: the address-free partition passed the blocks
  // they were registered at without them in the store.
  let anchoredContracts = existingPartitions->OptimizedPartitions.anchoredContracts

  let contractNames = registeringSetsByContract->Dict.keysToArray
  for cIdx in 0 to contractNames->Array.length - 1 {
    let contractName = contractNames->Array.getUnsafe(cIdx)
    let contractSet = registeringSetsByContract->Dict.getUnsafe(contractName)

    let isAnchored = anchoredContracts->Utils.Set.has(contractName)
    // A catch-up partition must go through the dynamic merge logic — that's
    // what bounds it against its anchor and removes it once it catches up.
    let isDynamic = dynamicContracts->Utils.Set.has(contractName) || isAnchored
    let partitions = isDynamic ? dynamicPartitions : nonDynamicPartitions

    // A set is ordered by effectiveStartBlock, so its start-block groups are
    // ascending and each group's addresses are a contiguous slice.
    let groups = contractSet->AddressSet.startBlockGroups

    if clientFilteredContracts->Utils.Set.has(contractName) && !isAnchored {
      // The contract is switching to client-side filtering in this very call, so
      // the collapse below folds everything it has into the address-free
      // partition anyway. Chunking these addresses by maxAddrInPartition would
      // only build partitions for it to absorb - hundreds of them for a contract
      // big enough to be client-filtered in the first place. All the collapse
      // needs is the earliest block the addresses aren't covered from, which is
      // the first group's since groups are ascending.
      switch groups->Array.get(0) {
      | Some({startBlock}) =>
        clientFilteredFrontiers->Array.push({
          blockNumber: Pervasives.max(startBlock - 1, progressBlockNumber),
          blockTimestamp: 0,
        })
      | None => ()
      }
    } else {
      let offsetRef = ref(0)
      let groupIdx = ref(0)
      while groupIdx.contents < groups->Array.length {
        let startBlock = (groups->Array.getUnsafe(groupIdx.contents)).startBlock
        // Addresses with different start blocks within range share a partition;
        // events before each address's effectiveStartBlock are dropped by the
        // source's address gate.
        let countRef = ref(0)
        let nextIdx = ref(groupIdx.contents)
        let joining = ref(true)
        while joining.contents && nextIdx.contents < groups->Array.length {
          let group = groups->Array.getUnsafe(nextIdx.contents)
          if group.startBlock - startBlock < OptimizedPartitions.tooFarBlockRange {
            countRef := countRef.contents + group.count
            nextIdx := nextIdx.contents + 1
          } else {
            joining := false
          }
        }

        let latestFetchedBlock = {
          blockNumber: Pervasives.max(startBlock - 1, progressBlockNumber),
          blockTimestamp: 0,
        }
        let remainingRef = ref(countRef.contents)
        let chunkOffsetRef = ref(offsetRef.contents)
        while remainingRef.contents > 0 {
          let take = Pervasives.min(remainingRef.contents, maxAddrInPartition)
          let pAddresses =
            contractSet->AddressSet.slice(~offset=chunkOffsetRef.contents, ~limit=Some(take))
          partitions->Array.push({
            id: nextPartitionIndexRef.contents->Int.toString,
            latestFetchedBlock,
            selection: normalSelection,
            dynamicContract: isDynamic ? Some(contractName) : None,
            addresses: pAddresses,
            mergeBlock: None,
            mutPendingQueries: [],
            sourceRangeCapacity: 0,
            prevSourceRangeCapacity: 0,
            eventDensity: None,
            latestSourceRangeCapacityUpdateBlock: 0,
          })
          nextPartitionIndexRef := nextPartitionIndexRef.contents + 1
          chunkOffsetRef := chunkOffsetRef.contents + take
          remainingRef := remainingRef.contents - take
        }

        offsetRef := offsetRef.contents + countRef.contents
        groupIdx := nextIdx.contents
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

      let totalCount = currentP.addresses->AddressSet.size + nextP.addresses->AddressSet.size

      if totalCount > maxAddrInPartition {
        // Exceeds address limit - don't merge, keep partitions separate
        mergedNonDynamic->Array.push(currentP)->ignore
        currentPRef := nextP
      } else {
        let mergedAddresses = nextP.addresses->AddressSet.merge(currentP.addresses)

        let isTooFar = currentPBlock + OptimizedPartitions.tooFarBlockRange < nextPBlock

        if isTooFar {
          // Too far: mergeBlock on current, merge addresses into next
          mergedNonDynamic
          ->Array.push({
            ...currentP,
            mergeBlock: currentPBlock < nextPBlock ? Some(nextPBlock) : None,
          })
          ->ignore
          currentPRef := nextP->withAddresses(mergedAddresses)
        } else {
          // Close: push next's addresses into current
          currentPRef := currentP->withAddresses(mergedAddresses)
        }
      }

      nextIdx := nextIdx.contents + 1
    }

    mergedNonDynamic->Array.push(currentPRef.contents)->ignore
  }

  let mergedPartitions = mergedNonDynamic->Array.concat(dynamicPartitions)

  // Final step: concat existing partitions with phase 1+2 result, collapse any
  // client-filtered contracts into the single address-free partition, and optimize.
  let allPartitions =
    existingPartitions
    ->Array.concat(mergedPartitions)
    ->collapseClientFilteredContracts(
      ~clientFilteredContracts,
      ~normalSelection,
      ~nextPartitionIndexRef,
      ~addressStore,
      ~clientFilteredFrontiers,
      ~knownHeight,
    )
  OptimizedPartitions.make(
    ~partitions=allPartitions,
    ~maxAddrInPartition,
    ~nextPartitionIndex=nextPartitionIndexRef.contents,
    ~dynamicContracts,
    ~clientFilteredContracts,
  )
}

let registerDynamicContracts = (
  fetchState: t,
  ~addressStore: AddressStore.t,
  // How far an in-flight open-ended query may end up claiming. These
  // registrations usually come out of a response that is applied right after
  // this call, and an unbounded query can reach past the height known when it
  // was dispatched — so the caller folds that response's own frontier and
  // height in here. Defaults to what the fetch state knows, which is all
  // there is to go on when no response is being applied.
  ~claimCeiling=fetchState.knownHeight,
  // Registrations collected from contractRegister calls, in the order the
  // handlers made them. May contain duplicates, which the store filters out.
  registrations: array<AddressStore.registration>,
) => {
  if fetchState.normalSelection.onEventRegistrations->Utils.Array.isEmpty {
    // Can the normalSelection be empty?
    JsError.throwWithMessage(
      "Invalid configuration. No events to fetch for the dynamic contract registration.",
    )
  }

  // Ids are handed out in registration order, so a cursor taken now selects
  // exactly what this batch adds.
  let idCursor = addressStore->AddressStore.nextId
  // The store resolves each address against both what it already holds and the
  // batch's own earlier entries, so two contracts claiming one address inside a
  // single batch conflict the same way as across batches. It also decides which
  // additions this chain fetches for, since it's what holds the contract list.
  let verdicts = addressStore->AddressStore.registerBatch(registrations)

  let registeringContractNames = []
  for idx in 0 to verdicts->Array.length - 1 {
    let registration = registrations->Array.getUnsafe(idx)
    let verdict = verdicts->Array.getUnsafe(idx)
    switch verdict {
    | Added({fetchable: true}) =>
      if !(registeringContractNames->Array.includes(registration.contractName)) {
        registeringContractNames->Array.push(registration.contractName)->ignore
      }
    // Nothing on this chain is fetched by address for the contract, so there's
    // no partition to build. The address is still stored and persisted, so a
    // config that later adds address-dependent events picks it up on restart.
    | Added({fetchable: false}) => ()
    | Conflict(_) | Duplicate(_) | Invalid =>
      verdict->warnRejectedRegistration(
        ~chainId=fetchState.chainId,
        ~contractAddress=registration.address,
        ~contractName=registration.contractName,
      )
    }
  }

  switch registeringContractNames {
  // Nothing to fetch: everything was rejected, or registered for contracts
  // this chain has no address-dependent events for.
  | [] => fetchState
  | _ => {
      let newPartitions = []
      let dynamicContractsRef = ref(fetchState.optimizedPartitions.dynamicContracts)
      let mutExistingPartitions = fetchState.optimizedPartitions.entities->Dict.valuesToArray

      for idx in 0 to registeringContractNames->Array.length - 1 {
        let contractName = registeringContractNames->Array.getUnsafe(idx)

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
            switch p.addresses->AddressSet.countFor(contractName) {
            | 0 => () // Skip partitions which don't have our contract
            | _ =>
              // Also filter out partitions which are 100% not mergable
              if p.selection.dependsOnAddresses && p.mergeBlock === None {
                let allPartitionContractNames = p.addresses->AddressSet.contractNames
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

                      let restNames =
                        allPartitionContractNames->Array.filter(name => name !== contractName)
                      mutExistingPartitions->Array.setUnsafe(
                        idx,
                        p->withAddresses(p.addresses->AddressSet.filterByContracts(restNames)),
                      )

                      let splitAddresses = p.addresses->AddressSet.filterByContracts([contractName])
                      newPartitions->Array.push({
                        id: newPartitionId,
                        latestFetchedBlock: p.latestFetchedBlock,
                        selection: fetchState.normalSelection,
                        dynamicContract: Some(contractName),
                        addresses: splitAddresses,
                        mergeBlock: None,
                        mutPendingQueries: p.mutPendingQueries,
                        sourceRangeCapacity: p.sourceRangeCapacity,
                        prevSourceRangeCapacity: p.prevSourceRangeCapacity,
                        eventDensity: p.eventDensity,
                        latestSourceRangeCapacityUpdateBlock: p.latestSourceRangeCapacityUpdateBlock,
                      })
                    }
                  }
                }
              }
            }
          }
        }
      }

      // Switch any dynamic contract that has just crossed the server-side
      // address threshold to client-side filtering. Sticky: the set only grows, and
      // collapse in createPartitions folds the contract's
      // partitions into the single address-free partition.
      // Clone the sticky set before mutating so this update owns its copy and
      // older fetchState snapshots keep theirs (Utils.Set.add mutates in place).
      let clientFilteredContracts = switch fetchState.clientFilterAddressThreshold {
      | Some(threshold) =>
        let clientFilteredContracts =
          fetchState.optimizedPartitions.clientFilteredContracts
          ->Utils.Set.toArray
          ->Utils.Set.fromArray
        dynamicContractsRef.contents
        ->Utils.Set.toArray
        ->Array.forEach(contractName => {
          let addressCount = addressStore->AddressStore.contractCount(contractName)
          if !(clientFilteredContracts->Utils.Set.has(contractName)) && addressCount > threshold {
            clientFilteredContracts->addClientFilteredContract(
              ~contractName,
              ~chainId=fetchState.chainId,
              ~addressCount,
              ~threshold,
            )
          }
        })
        clientFilteredContracts
      | None => fetchState.optimizedPartitions.clientFilteredContracts
      }

      // Only this batch's additions need partitions; everything already
      // registered has one.
      let registeringSetsByContract = Dict.make()
      registeringContractNames->Array.forEach(contractName => {
        registeringSetsByContract->Dict.set(
          contractName,
          addressStore->AddressStore.makeSet(~contractName, ~options={minId: idCursor}),
        )
      })

      let optimizedPartitions = createPartitions(
        ~registeringSetsByContract,
        ~addressStore,
        ~dynamicContracts=dynamicContractsRef.contents,
        ~clientFilteredContracts,
        ~normalSelection=fetchState.normalSelection,
        ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
        ~nextPartitionIndex=fetchState.optimizedPartitions.nextPartitionIndex +
        newPartitions->Array.length,
        ~existingPartitions=mutExistingPartitions->Array.concat(newPartitions),
        ~progressBlockNumber=0,
        ~knownHeight=Pervasives.max(claimCeiling, fetchState.knownHeight),
      )

      fetchState->updateInternal(~optimizedPartitions)
    }
  }
}

/*
Updates fetchState with a response for a given query.
Throws if the partition with given query cannot be found (unexpected)

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
      ~itemsCount=newItems->Array.length,
      ~latestFetchedBlock,
    ),
    // Merge the response into the sorted buffer, dropping duplicates an
    // overlapping query may re-deliver (e.g. an over-fetched log matched by two
    // partitions). Absorbs sorting too, so updateInternal doesn't re-sort.
    ~mutItemsSorted=true,
    ~mutItems=?{
      switch newItems {
      | [] => None
      | _ => Some(fetchState.buffer->mergeIntoBuffer(newItems))
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
      itemsEst: q.itemsEst,
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
// Only queries still being fetched count — a fetched chunk parked behind a gap
// doesn't hold a slot, so a slow query at the queue head can't starve the
// partition's pipeline.
let maxInFlightChunksPerPartition = 12

// Most parallel in-flight queries a single chain may have at once, across all
// its partitions. Bounds source load on chains with many partitions, where the
// per-partition cap alone would admit thousands of concurrent queries.
let maxChainConcurrency = Env.maxChainConcurrency

// Chunk spans grow by this factor over the smallest recently observed source
// range, so the pipeline keeps probing for more capacity instead of locking in
// the first measurement.
let chunkRangeGrowthFactor = 1.8

// Push one density-priced query and return its itemsEst, the density estimate
// that sizes the query and the chain's budget reservation. These queries are
// chunks and gap-fills: their toBlock is a tight bound sized to the source's
// range capacity, so they send no server cap (itemsTarget None) — a cap would
// only self-truncate the bounded range, worse under client-side address
// filtering. A rare unbounded call caps at the estimate as its only bound.
let pushDensityPricedQuery = (
  queries: array<query>,
  ~partitionId,
  ~fromBlock,
  ~toBlock,
  ~isChunk,
  ~density,
  ~chainTargetBlock,
  ~selection,
  ~addresses,
) => {
  let itemsEst = densityItemsTarget(~density, ~fromBlock, ~toBlock, ~chainTargetBlock)
  queries
  ->Array.push({
    partitionId,
    fromBlock,
    toBlock,
    selection,
    isChunk,
    itemsTarget: switch toBlock {
    | Some(_) => None
    | None => Some(itemsEst)
    },
    itemsEst,
    addresses,
  })
  ->ignore
  itemsEst
}

// Generates candidate queries for a gap range (a hole left between
// completed/pending chunks, e.g. from an out-of-order partial response). Gaps
// carry the range's low fromBlock, so the acceptance pass takes them before
// forward progress. Chunks only on a trusted POSITIVE density; a positive
// density without capacity history prices a single query. Zero or unknown
// density falls back to the "available density" — the partition's equal-divide
// budget spread over its remaining range this tick. That fallback should be
// unreachable (a gap implies pipelined chunks, which imply a positive observed
// density), but if chunking preconditions ever change it must not price by a
// zero density: that would produce an itemsTarget-1 query crawling a dense gap
// one item per response.
let pushGapFillQueries = (
  queries: array<query>,
  ~partitionId: string,
  ~rangeFromBlock: int,
  ~rangeEndBlock: option<int>,
  ~headBlockNumber: int,
  ~chainTargetBlock: int,
  ~maybeChunkRange: option<int>,
  ~maxChunks: int,
  ~partition: partition,
  ~partitionBudget: float,
  ~selection: selection,
  ~addresses: AddressSet.t,
) => {
  // Gaps past the chain's target block wait: they regenerate from the
  // pending-walk each tick and fill once the target reaches them. The lagged
  // head is the fetchable ceiling — blocks past knownHeight - blockLag can't
  // be queried yet.
  if rangeFromBlock <= Pervasives.min(headBlockNumber, chainTargetBlock) && maxChunks > 0 {
    switch rangeEndBlock {
    | Some(endBlock) if rangeFromBlock > endBlock => ()
    | _ =>
      let maxBlock = switch rangeEndBlock {
      | Some(eb) => eb
      | None => chainTargetBlock
      }
      let pushSingleQuery = (~density, ~isChunk) =>
        queries
        ->pushDensityPricedQuery(
          ~partitionId,
          ~fromBlock=rangeFromBlock,
          ~toBlock=rangeEndBlock,
          ~isChunk,
          ~density,
          ~chainTargetBlock,
          ~selection,
          ~addresses,
        )
        ->ignore
      switch (partition->getTrustedDensity, maybeChunkRange) {
      | (Some(density), Some(chunkRange)) if density > 0. =>
        let chunkSize = Js.Math.ceil_int(chunkRange->Int.toFloat *. chunkRangeGrowthFactor)
        if rangeFromBlock + chunkSize * 2 - 1 <= maxBlock {
          let chunkFromBlock = ref(rangeFromBlock)
          let chunkIdx = ref(0)
          while (
            chunkIdx.contents < maxChunks && chunkFromBlock.contents + chunkSize - 1 <= maxBlock
          ) {
            let chunkToBlock = chunkFromBlock.contents + chunkSize - 1
            queries
            ->pushDensityPricedQuery(
              ~partitionId,
              ~fromBlock=chunkFromBlock.contents,
              ~toBlock=Some(chunkToBlock),
              ~isChunk=true,
              ~density,
              ~chainTargetBlock,
              ~selection,
              ~addresses,
            )
            ->ignore
            chunkFromBlock := chunkToBlock + 1
            chunkIdx := chunkIdx.contents + 1
          }
        } else {
          // Not enough room for 2 chunks, fall back to a single query
          pushSingleQuery(~density, ~isChunk=rangeEndBlock !== None)
        }
      | (Some(density), None) if density > 0. => pushSingleQuery(~density, ~isChunk=false)
      | _ =>
        let remainingRange = Pervasives.max(1, chainTargetBlock - rangeFromBlock + 1)
        pushSingleQuery(~density=partitionBudget /. remainingRange->Int.toFloat, ~isChunk=false)
      }
    }
  }
}

// Per-partition state carried from the gap-fill/cursor walk to candidate
// generation.
type partitionFillState = {
  partitionId: string,
  p: partition,
  cursor: int,
  // Chunks already generated for this partition during gap-fill — used with
  // inFlightCount against maxInFlightChunksPerPartition.
  chunksUsedThisCall: int,
  // Still-being-fetched pending queries before this call — fixed for the call.
  // A fetched chunk parked behind a gap doesn't hold a pipeline slot.
  inFlightCount: int,
  queryEndBlock: option<int>,
  maybeChunkRange: option<int>,
}

// Gap-fill: walk one partition's pending queries, generating a candidate for
// any hole (e.g. from an out-of-order partial chunk response). Returns the
// partition's post-gap fill state — its cursor for forward work — or None when
// the partition is blocked on an unresolved single-shot query.
let walkPartitionPending = (
  p: partition,
  ~partitionId: string,
  ~inFlightCount: int,
  ~candidates: array<query>,
  ~headBlockNumber: int,
  ~chainTargetBlock: int,
  ~partitionBudget: float,
  ~queryEndBlock: option<int>,
): option<partitionFillState> => {
  let maybeChunkRange = getMinHistoryRange(p)
  let pendingCount = p.mutPendingQueries->Array.length

  let cursor = ref(p.latestFetchedBlock.blockNumber + 1)
  let canContinue = ref(true)
  let chunksUsedThisCall = ref(0)
  let pqIdx = ref(0)
  while pqIdx.contents < pendingCount && canContinue.contents {
    let pq = p.mutPendingQueries->Array.getUnsafe(pqIdx.contents)

    if pq.fromBlock > cursor.contents {
      let beforeLen = candidates->Array.length
      pushGapFillQueries(
        candidates,
        ~partitionId,
        ~rangeFromBlock=cursor.contents,
        ~rangeEndBlock=Utils.Math.minOptInt(Some(pq.fromBlock - 1), queryEndBlock),
        ~headBlockNumber,
        ~chainTargetBlock,
        ~maybeChunkRange,
        ~maxChunks=maxInFlightChunksPerPartition - inFlightCount - chunksUsedThisCall.contents,
        ~partition=p,
        ~partitionBudget,
        ~selection=p.selection,
        ~addresses=p.addresses,
      )
      chunksUsedThisCall := chunksUsedThisCall.contents + (candidates->Array.length - beforeLen)
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

  // Nothing in this partition's selection can match below its earliest start
  // block, so forward work skips straight to it instead of scanning up to it and
  // discarding whole pages. Only the cursor moves — `latestFetchedBlock` still
  // advances solely on a response, so no block is ever reported fetched that
  // wasn't. Bounded by the head and the query end block: past either, the
  // partition would offer no candidate at all, so it queries as before rather
  // than going quiet until the chain reaches its start block.
  let cursor = switch p.selection.startBlock {
  | Some(startBlock) if startBlock > cursor.contents =>
    switch Utils.Math.minOptInt(Some(headBlockNumber), queryEndBlock) {
    | Some(reachable) if startBlock <= reachable => startBlock
    | _ => cursor.contents
    }
  | _ => cursor.contents
  }

  canContinue.contents
    ? Some({
        partitionId,
        p,
        cursor,
        chunksUsedThisCall: chunksUsedThisCall.contents,
        inFlightCount,
        queryEndBlock,
        maybeChunkRange,
      })
    : None
}

// Forward work: generate each in-range partition's candidates — strict chunks
// when both source-capacity history and density are known, or an open-ended
// budget probe otherwise. No budget check here; the acceptance pass decides
// which candidates make the cut.
//
// Chunks require a POSITIVE trusted density: density 0 prices every chunk at
// ~nothing, so an open-ended probe (full server scan range in one response)
// beats a pipeline of hard-bounded chunks that crawl chunkRangeGrowthFactor×
// per two responses.
let pushForwardCandidates = (
  candidates: array<query>,
  // May be truncated to the chain's free concurrency slots — a pure generation
  // bound, see getNextQuery.
  ~inRangeStates: array<partitionFillState>,
  // The full in-range partition count, pre-truncation. Probe sizing divides by
  // this so each probe's itemsEst stays the honest per-partition share for
  // budget control — sizing by the (fewer) admittable queries would let every
  // accepted probe over-fetch its share.
  ~inRangeCount: int,
  ~chainTargetBlock: int,
  ~freshBudget: float,
) => {
  // Even share of the fresh budget across the partitions actually fetching
  // this tick (not every partition — so budget isn't stranded on ones below
  // the head, waiting, or already done). The fallback when there's no range to
  // the target.
  let probeShare = inRangeCount == 0 ? 0. : freshBudget /. inRangeCount->Int.toFloat
  // Items/block the budget implies over the range those partitions cover this
  // tick — from the furthest-behind in-range cursor to the target. A probe
  // covering less of that range (its partition sits further ahead) gets
  // proportionally fewer items; one starting at the frontier gets the full
  // even share.
  let frontierCursor =
    inRangeStates->Array.reduce(chainTargetBlock, (min, fs) => fs.cursor < min ? fs.cursor : min)
  let rangeToTarget = chainTargetBlock - frontierCursor + 1
  let rangeTargetDensity =
    inRangeCount > 0 && rangeToTarget > 0 ? freshBudget /. rangeToTarget->Int.toFloat : 0.

  inRangeStates->Array.forEach(fs => {
    let p = fs.p
    let maxBlock = switch fs.queryEndBlock {
    | Some(eb) => eb
    | None => chainTargetBlock
    }
    switch (fs.maybeChunkRange, p->getTrustedDensity) {
    | (Some(minHistoryRange), Some(density)) if density > 0. =>
      let chunkSize = Js.Math.ceil_int(minHistoryRange->Int.toFloat *. chunkRangeGrowthFactor)
      let maxChunksRemaining =
        maxInFlightChunksPerPartition - fs.inFlightCount - fs.chunksUsedThisCall
      // No chunk starts past chainTargetBlock; an emitted chunk still keeps
      // its full span (chunkToBlock may exceed the target — only
      // endBlock/mergeBlock are hard bounds).
      let chunkStartCeiling = Pervasives.min(maxBlock, chainTargetBlock)
      let created = ref(0)
      let chunkFromBlock = ref(fs.cursor)
      // Stop once this partition alone has generated more than the whole fresh
      // budget: the acceptance pass can hand a single partition at most the
      // budget plus one overshoot query, so further chunks could never be
      // accepted. Bounds generation (and the candidate sort) when the budget
      // is small relative to the pipeline cap.
      let generatedItems = ref(0.)
      while (
        created.contents < maxChunksRemaining &&
        chunkFromBlock.contents <= chunkStartCeiling &&
        generatedItems.contents <= freshBudget
      ) {
        let chunkToBlock = Pervasives.min(chunkFromBlock.contents + chunkSize - 1, maxBlock)
        let itemsEst =
          candidates->pushDensityPricedQuery(
            ~partitionId=fs.partitionId,
            ~fromBlock=chunkFromBlock.contents,
            ~toBlock=Some(chunkToBlock),
            ~isChunk=true,
            ~density,
            ~chainTargetBlock,
            ~selection=p.selection,
            ~addresses=p.addresses,
          )
        generatedItems := generatedItems.contents +. itemsEst->Int.toFloat
        chunkFromBlock := chunkToBlock + 1
        created := created.contents + 1
      }
    | _ =>
      // Size the probe by the events its range to the target is expected to
      // hold — rangeTargetDensity × (chainTargetBlock − fromBlock + 1), split
      // across the partitions fetching this tick. With no range to the target
      // fall back to an even share of the fresh budget, so cold chains and
      // caught-up partitions still probe.
      let itemsEst = if rangeToTarget > 0 {
        Pervasives.max(
          1,
          Math.round(
            rangeTargetDensity *.
            (chainTargetBlock - fs.cursor + 1)->Int.toFloat /.
            inRangeCount->Int.toFloat,
          )->Float.toInt,
        )
      } else {
        Pervasives.max(1, Math.round(probeShare)->Float.toInt)
      }
      candidates
      ->Array.push({
        partitionId: fs.partitionId,
        fromBlock: fs.cursor,
        toBlock: fs.queryEndBlock,
        isChunk: false,
        selection: p.selection,
        // An open-ended probe's range isn't bounded to source capacity, so it
        // keeps a server cap at its estimate to protect the shared buffer.
        itemsTarget: Some(itemsEst),
        itemsEst,
        addresses: p.addresses,
      })
      ->ignore
    }
  })
}

// Acceptance: merge fresh candidates (Some) with the in-flight reservations
// (None) and walk them in fromBlock order, starting from the full
// chainTargetItems. A reservation just draws down the budget — its query is
// already sent — while a candidate draws down the budget and is emitted.
// Because a gap-fill's fromBlock precedes the in-flight query it unblocks,
// it claims budget ahead of that reservation, so the buffer never deadlocks
// waiting on a hole it can't fund. The candidate that tips the budget
// negative is still emitted (a single overshoot); everything after it waits
// for a tick with more budget. Accepted queries route back to their
// partition bucket, so the output stays in idsInAscOrder with each
// partition's queries in fromBlock order.
let acceptCandidates = (
  ~candidates: array<query>,
  ~reservations: array<(int, int)>,
  ~chainTargetItems: float,
  ~partitionIndexById: dict<int>,
  ~queriesByPartitionIndex: array<array<query>>,
) => {
  let acceptanceStream = []
  candidates->Array.forEach(query =>
    acceptanceStream->Array.push((query.fromBlock, query.itemsEst, Some(query)))->ignore
  )
  reservations->Array.forEach(((fromBlock, itemsEst)) =>
    acceptanceStream->Array.push((fromBlock, itemsEst, None))->ignore
  )
  // Sort by fromBlock; on a tie charge the in-flight reservation (None) before
  // a fresh candidate (Some), so a same-block candidate can't overshoot the
  // target buffer. Only a strictly-earlier candidate — a gap-fill, whose
  // fromBlock precedes the query it unblocks — borrows ahead of a reservation.
  acceptanceStream->Array.sort(((aFrom, _, aQuery), (bFrom, _, bQuery)) =>
    if aFrom !== bFrom {
      Int.compare(aFrom, bFrom)
    } else {
      switch (aQuery, bQuery) {
      | (None, Some(_)) => Ordering.less
      | (Some(_), None) => Ordering.greater
      | (None, None) | (Some(_), Some(_)) => Ordering.equal
      }
    }
  )
  let streamCount = acceptanceStream->Array.length
  let remainingBudget = ref(chainTargetItems)
  let acceptIdx = ref(0)
  // In-flight queries count against the chain's concurrency cap alongside the
  // ones accepted this tick; once the cap is reached no later candidate can be
  // accepted (they're only later in fromBlock order), so the walk stops.
  let usedConcurrency = ref(reservations->Array.length)
  while (
    remainingBudget.contents > 0. &&
    acceptIdx.contents < streamCount &&
    usedConcurrency.contents < maxChainConcurrency
  ) {
    let (_, itemsEst, maybeQuery) = acceptanceStream->Array.getUnsafe(acceptIdx.contents)
    switch maybeQuery {
    | Some(query) =>
      let partitionIdx = partitionIndexById->Dict.getUnsafe(query.partitionId)
      queriesByPartitionIndex->Array.getUnsafe(partitionIdx)->Array.push(query)->ignore
      usedConcurrency := usedConcurrency.contents + 1
    | None => ()
    }
    remainingBudget := remainingBudget.contents -. itemsEst->Int.toFloat
    acceptIdx := acceptIdx.contents + 1
  }
}

// Candidate queries are sized against chainTargetBlock, the soft querying
// horizon the owning chain wants to reach this tick — derived by ChainState
// from its share of the indexer-wide buffer budget and its chain-level event
// density. chainTargetBlock is never used as a hard query end, only to (a)
// select which partitions are "in range" this tick and (b) size an open-ended
// query with no other ceiling: the true hard bounds stay
// endBlock/mergeBlock/the lagged head.
//
// The tick's budget is chainTargetItems minus what's already in flight. A
// non-positive budget only resolves the wait action and generates no query
// candidates. With a positive budget, every candidate query — gap-fill holes,
// plus each in-range partition's chunks or open-ended probe toward the target —
// is generated with no budget check, then the candidates are sorted by
// fromBlock and accepted in that order while the budget stays positive. The
// query that tips it negative is still accepted (a single overshoot);
// everything after it waits for a tick with more budget.
// Sorting by fromBlock spends the budget on the earliest blocks across all
// partitions first, so no partition is starved by generation order and the
// frontier advances evenly. In-flight reservations release as responses land,
// so acceptance redistributes across ticks.
//
// A partition with source-capacity history and a positive density generates
// density-sized chunks toward the target. Any other partition (no signal, no
// capacity history, or a density-0 estimate) generates one open-ended probe
// sized to the events its range to the target is expected to hold —
// rangeTargetDensity × (chainTargetBlock − fromBlock + 1) / inRangeCount — so
// unknown-density partitions probe in parallel within one budget.
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

    // Single scan over every partition, regardless of this tick's budget:
    // waiting-for-new-block bookkeeping, in-flight accounting, and the
    // id → index routing the acceptance pass uses.
    //
    // In-flight means fetchedBlock === None: a query whose response already
    // landed has had its reservation released by ChainState even while it
    // lingers in mutPendingQueries behind an unfilled gap, so counting it would
    // understate the budget and hold a concurrency slot it no longer uses.
    let inFlightCounts = Utils.Array.jsArrayCreate(partitionsCount)
    // (fromBlock, itemsEst) of each still-in-flight query. The acceptance pass
    // merges these into the candidate stream and draws them down in fromBlock
    // order, so a gap-fill sitting before an in-flight query claims budget ahead
    // of it and the buffer unblocks without waiting for that query to return.
    let reservations = []
    // In-flight itemsEst summed over the reservations. Sizes fresh forward
    // work below.
    let chainReserved = ref(0.)
    // Position of each partition in idsInAscOrder, so an accepted query routes
    // back to its bucket and the output stays in idsInAscOrder.
    let partitionIndexById = Dict.make()
    for idx in 0 to partitionsCount - 1 {
      let partitionId = optimizedPartitions.idsInAscOrder->Array.getUnsafe(idx)
      let p = optimizedPartitions.entities->Dict.getUnsafe(partitionId)
      partitionIndexById->Dict.set(partitionId, idx)
      let inFlightCount = ref(0)
      for pqIdx in 0 to p.mutPendingQueries->Array.length - 1 {
        let pq = p.mutPendingQueries->Array.getUnsafe(pqIdx)
        if pq.fetchedBlock === None {
          inFlightCount := inFlightCount.contents + 1
          chainReserved := chainReserved.contents +. pq.itemsEst->Int.toFloat
          reservations->Array.push((pq.fromBlock, pq.itemsEst))->ignore
        }
      }
      inFlightCounts->Array.setUnsafe(idx, inFlightCount.contents)
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

    // Fresh queries the acceptance pass can still admit this tick.
    let availableConcurrency = maxChainConcurrency - reservations->Array.length

    // A zero budget is an admission check: preserve the wait-state scan above,
    // but make every query-generation pass below empty. Caught-up chains also
    // skip those passes because their action is already known. Same when the
    // chain is at its concurrency cap — no candidate could be accepted.
    let partitionsCount =
      chainTargetItems <= 0. || shouldWaitForNewBlock.contents || availableConcurrency <= 0
        ? 0
        : partitionsCount

    // One bucket per partition, in idsInAscOrder order — gap-fill and the
    // budget pass both push into a partition's own bucket, so flattening at
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

    // Every candidate query for this tick — gap-fill holes plus each in-range
    // partition's chunks/probe toward the target — generated with no budget
    // check, then merged with the in-flight reservations, sorted by fromBlock,
    // and accepted while the budget lasts (acceptCandidates). Selecting by
    // fromBlock spends the budget on the earliest blocks across all partitions
    // first, so no partition is starved by iteration order and the frontier
    // advances evenly.
    let candidates = []

    // Each partition's equal-divide share of the tick's budget, used to price
    // unknown-density gap probes.
    let partitionBudget =
      partitionsCount == 0 ? 0. : chainTargetItems /. partitionsCount->Int.toFloat

    let fillStates = []
    for idx in 0 to partitionsCount - 1 {
      let partitionId = optimizedPartitions.idsInAscOrder->Array.getUnsafe(idx)
      let p = optimizedPartitions.entities->Dict.getUnsafe(partitionId)
      switch p->walkPartitionPending(
        ~partitionId,
        ~inFlightCount=inFlightCounts->Array.getUnsafe(idx),
        ~candidates,
        ~headBlockNumber,
        ~chainTargetBlock,
        ~partitionBudget,
        ~queryEndBlock=computeQueryEndBlock(p),
      ) {
      | Some(fillState) => fillStates->Array.push(fillState)->ignore
      | None => ()
      }
    }

    // Budget for fresh forward work: chainTargetItems minus what's still in
    // flight. Sizes probes and bounds chunk generation; the acceptance pass
    // does the final budgeting against the full chainTargetItems.
    let freshBudget = Pervasives.max(0., chainTargetItems -. chainReserved.contents)

    let isInRange = (fs: partitionFillState) =>
      fs.cursor <= chainTargetBlock &&
      switch fs.queryEndBlock {
      | Some(eb) => fs.cursor <= eb
      | None => true
      } &&
      fs.inFlightCount + fs.chunksUsedThisCall < maxInFlightChunksPerPartition

    let inRangeStates = fillStates->Array.filter(isInRange)
    let inRangeCount = inRangeStates->Array.length
    // The acceptance pass admits at most availableConcurrency fresh queries, in
    // fromBlock order, and every kept partition contributes a candidate at its
    // own cursor — so a partition past the first availableConcurrency in cursor
    // order could only offer candidates behind at least that many earlier ones,
    // which the concurrency cap stops the walk from ever reaching. Dropping
    // those partitions up front skips pointless candidate generation. A pure
    // generation bound: sizing still divides by the full inRangeCount, so each
    // probe keeps its honest per-partition share of the budget.
    let inRangeStates = if inRangeCount > availableConcurrency {
      inRangeStates->Array.sort((a, b) => Int.compare(a.cursor, b.cursor))
      inRangeStates->Array.slice(~start=0, ~end=availableConcurrency)
    } else {
      inRangeStates
    }

    candidates->pushForwardCandidates(
      ~inRangeStates,
      ~inRangeCount,
      ~chainTargetBlock,
      ~freshBudget,
    )

    acceptCandidates(
      ~candidates,
      ~reservations,
      ~chainTargetItems,
      ~partitionIndexById,
      ~queriesByPartitionIndex,
    )

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
  ~addressStore: AddressStore.t,
  ~addresses: array<Internal.indexingAddress>,
  ~maxAddrInPartition,
  ~chainId: ChainId.t,
  ~maxOnBlockBufferSize,
  ~knownHeight,
  ~progressBlockNumber=startBlock - 1,
  ~onBlockRegistrations=[],
  ~blockLag=0,
  ~firstEventBlock=None,
  ~clientFilterAddressThreshold=None,
  ~isResumed=false,
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
      selection: makeSelection(
        ~dependsOnAddresses=false,
        ~onEventRegistrations=notDependingOnAddresses,
      ),
      addresses: addressStore->AddressStore.emptySet,
      mergeBlock: None,
      dynamicContract: None,
      mutPendingQueries: [],
      sourceRangeCapacity: 0,
      prevSourceRangeCapacity: 0,
      eventDensity: None,
      latestSourceRangeCapacityUpdateBlock: 0,
    })
  }

  let normalSelection = makeSelection(
    ~dependsOnAddresses=true,
    ~onEventRegistrations=normalRegistrations,
  )

  // Every address the chain indexes goes into the store — including ones whose
  // contract has no address-dependent events, so a later registration of the
  // same address still conflicts and the address is still persisted.
  addressStore
  // These come from the config or from a resume, so they're already stored and
  // must never be drained back into a write.
  ->AddressStore.seedBatch(
    addresses->Array.map((contract): AddressStore.registration => {
      address: contract.address,
      contractName: contract.contractName,
      registrationBlock: contract.registrationBlock,
    }),
  )
  // Verdicts are in the batch's order, so they line up with `addresses`. A
  // config address the store rejects is dropped exactly like a dynamic one, and
  // needs the same warning — restored dynamic addresses come through here too.
  ->Array.forEachWithIndex((verdict, idx) => {
    let contract = addresses->Array.getUnsafe(idx)
    verdict->warnRejectedRegistration(
      ~chainId,
      ~contractAddress=contract.address,
      ~contractName=contract.contractName,
    )
  })

  let dynamicContracts = Utils.Set.make()
  let clientFilteredContracts = Utils.Set.make()
  let registeringSetsByContract = Dict.make()

  addresses->Array.forEach(contract => {
    let contractName = contract.contractName

    // Only addresses whose contract has events that depend on addresses get
    // registered for active fetching via partitions.
    if contractNamesWithNormalEvents->Utils.Set.has(contractName) {
      if !(registeringSetsByContract->Dict.has(contractName)) {
        registeringSetsByContract->Dict.set(
          contractName,
          addressStore->AddressStore.makeSet(~contractName),
        )
      }

      // Detect dynamic contracts by registrationBlock
      if contract.registrationBlock !== -1 {
        dynamicContracts->Utils.Set.add(contractName)->ignore
      }
    }
  })

  // Switch any contract already over the server-side address threshold to
  // client-side filtering at creation — a config contract with a large static
  // address list, or a dynamic contract restored from a large persisted set.
  switch clientFilterAddressThreshold {
  | Some(threshold) =>
    registeringSetsByContract->Utils.Dict.forEachWithKey((set, contractName) => {
      let addressCount = set->AddressSet.size
      if addressCount > threshold {
        clientFilteredContracts->addClientFilteredContract(
          ~contractName,
          ~chainId,
          ~addressCount,
          ~threshold,
          ~shouldLog=!isResumed,
        )
      }
    })
  | None => ()
  }

  let optimizedPartitions = createPartitions(
    ~registeringSetsByContract,
    ~addressStore,
    ~dynamicContracts,
    ~clientFilteredContracts,
    ~normalSelection,
    ~maxAddrInPartition,
    ~nextPartitionIndex=partitions->Array.length,
    ~existingPartitions=partitions, // wildcard partition(s) if any
    ~progressBlockNumber,
    ~knownHeight,
  )

  if (
    optimizedPartitions->OptimizedPartitions.count === 0 &&
      onBlockRegistrations->Utils.Array.isEmpty
  ) {
    JsError.throwWithMessage(
      `Invalid configuration: Nothing to fetch on chain ${chainId->ChainId.toString}. ` ++
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
    clientFilterAddressThreshold,
  }

  fetchState
}

let bufferSize = ({buffer}: t) => buffer->Array.length

let partitionsCount = ({optimizedPartitions}: t) => optimizedPartitions->OptimizedPartitions.count

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
let rollback = (fetchState: t, ~addressStore: AddressStore.t, ~targetBlockNumber) => {
  // Step 1: Prune addresses registered after the target block. The pruned store
  // is then the source of truth for partition cleanup below — an address
  // survives iff `filterByRegistrationBlock` keeps it.
  addressStore->AddressStore.rollback(targetBlockNumber)->ignore

  // Step 2: Categorize partitions
  let keptPartitions = []
  let nextKeptIdRef = ref(0)
  let registeringSetsByContract: dict<AddressSet.t> = Dict.make()
  let collectForRecreation = (set: AddressSet.t) =>
    set
    ->AddressSet.contractNames
    ->Array.forEach(contractName => {
      let contractSet = set->AddressSet.filterByContracts([contractName])
      registeringSetsByContract->Dict.set(
        contractName,
        switch registeringSetsByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
        | Some(existing) => existing->AddressSet.merge(contractSet)
        | None => contractSet
        },
      )
    })

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
        // Everything above the target is refetched by whichever partition this
        // one was catching up to, so there is nothing left to catch up on past
        // it. createPartitions drops the partition outright when the capped
        // block is already reached.
        mergeBlock: switch p.mergeBlock {
        | Some(mergeBlock) if mergeBlock > targetBlockNumber => Some(targetBlockNumber)
        | other => other
        },
        mutPendingQueries: rollbackPendingQueries(p.mutPendingQueries, ~targetBlockNumber),
      })
      ->ignore

    // Non-wildcard with lfb > target: delete, collect addresses for recreation
    | _ if p.latestFetchedBlock.blockNumber > targetBlockNumber =>
      collectForRecreation(p.addresses->AddressSet.filterByRegistrationBlock(targetBlockNumber))

    // Non-wildcard with lfb <= target: keep, adjust pending queries and mergeBlock
    | _ => {
        // Cap mergeBlock at target
        let mergeBlock = switch p.mergeBlock {
        | Some(mergeBlock) if mergeBlock > targetBlockNumber => Some(targetBlockNumber)
        | other => other
        }

        // Drop addresses pruned from the store
        let rollbackedAddresses =
          p.addresses->AddressSet.filterByRegistrationBlock(targetBlockNumber)

        if !(rollbackedAddresses->AddressSet.isEmpty) {
          let id = nextKeptIdRef.contents->Int.toString
          nextKeptIdRef := nextKeptIdRef.contents + 1
          keptPartitions
          ->Array.push({
            ...p->withAddresses(rollbackedAddresses),
            id,
            mutPendingQueries: rollbackPendingQueries(p.mutPendingQueries, ~targetBlockNumber),
            mergeBlock,
          })
          ->ignore
        }
      }
    }
  }

  // Step 3: Recreate partitions from deleted partition addresses
  let optimizedPartitions = createPartitions(
    ~registeringSetsByContract,
    ~addressStore,
    ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
    ~clientFilteredContracts=fetchState.optimizedPartitions.clientFilteredContracts,
    ~normalSelection=fetchState.normalSelection,
    ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
    ~nextPartitionIndex=nextKeptIdRef.contents,
    ~existingPartitions=keptPartitions,
    ~progressBlockNumber=targetBlockNumber,
    ~knownHeight=fetchState.knownHeight,
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
    // Filtering the sorted buffer keeps it sorted and deduped.
    ~mutItemsSorted=true,
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

// Frontier at (or within `tolerance` of) the lagged head with no processable
// items left — the moment the chain can cross into the reorg threshold.
// `tolerance` absorbs the head advancing between a chain catching up and this
// check, so it applies only when the (moving) head is the target: a finite
// endBlock at or below the lagged head is an exact target and is reached without
// tolerance. Uses bufferReadyCount, not an empty buffer: items stuck above the
// frontier behind a lagging partition's gap are reorg-safe (all <= head -
// blockLag) and must not defer entry, or a many-partition chain never enters.
let isReadyToEnterReorgThreshold = (
  ~tolerance,
  {endBlock, blockLag, knownHeight} as fetchState: t,
) => {
  let bufferBlockNumber = fetchState->bufferBlockNumber
  let laggedHead = knownHeight - blockLag
  knownHeight !== 0 &&
  switch endBlock {
  | Some(endBlock) if endBlock <= laggedHead => bufferBlockNumber >= endBlock
  | _ => bufferBlockNumber >= laggedHead - tolerance
  } &&
  fetchState->bufferReadyCount == 0
}

// Lower progress percentage = further behind = higher priority. Progress is
// relative to the head this chain can actually fetch, so a chain at its lagged
// head does not look behind relative to unavailable blocks. Shared by the batch
// ordering and the cross-chain fetch priority.
let getProgressPercentage = (fetchState: t) => {
  switch fetchState.firstEventBlock {
  | None => 0.
  | Some(firstEventBlock) =>
    let totalRange = fetchState.knownHeight - fetchState.blockLag - firstEventBlock
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
    fetchState->updateInternal(~knownHeight)
  } else {
    fetchState
  }
}
