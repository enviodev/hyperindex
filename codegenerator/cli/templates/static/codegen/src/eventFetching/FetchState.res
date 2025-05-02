open Belt

/**
The block number and log index of the event that registered a
dynamic contract
*/
type dynamicContractId = EventUtils.eventIndex

@unboxed
type contractRegister =
  | Config
  | DC({
      id: dynamicContractId,
      startBlockTimestamp: int,
      registeringEventContractName: string,
      registeringEventName: string,
      registeringEventSrcAddress: Address.t,
    })
type indexingContract = {
  address: Address.t,
  contractName: string,
  startBlockNumber: int,
  startLogIndex: int,
  register: contractRegister,
}

type blockNumberAndTimestamp = {
  blockNumber: int,
  blockTimestamp: int,
}

type blockNumberAndLogIndex = {blockNumber: int, logIndex: int}

type selection = {eventConfigs: array<Internal.eventConfig>, dependsOnAddresses: bool}

type status = {mutable fetchingStateId: option<int>}

/**
A state that holds a queue of events and data regarding what to fetch next
for specific contract events with a given contract address.
When partitions for the same events are caught up to each other
the are getting merged until the maxAddrInPartition is reached.
*/
type partition = {
  id: string,
  status: status,
  latestFetchedBlock: blockNumberAndTimestamp,
  selection: selection,
  contractAddressMapping: ContractAddressingMap.mapping,
  //Events ordered from latest to earliest
  fetchedEventQueue: array<Internal.eventItem>,
}

type t = {
  partitions: array<partition>,
  // Used for the incremental partition id. Can't use the partitions length,
  // since partitions might be deleted on merge or cleaned up
  nextPartitionIndex: int,
  isFetchingAtHead: bool,
  endBlock: option<int>,
  maxAddrInPartition: int,
  firstEventBlockNumber: option<int>,
  normalSelection: selection,
  // By address
  indexingContracts: dict<indexingContract>,
  // Registered dynamic contracts that need to be stored in the db
  // Should read them at the same time when getting items for the batch
  dcsToStore?: array<TablesStatic.DynamicContractRegistry.t>,
  // Not used for logic - only metadata
  chainId: int,
  // Fields computed by updateInternal
  latestFullyFetchedBlock: blockNumberAndTimestamp,
  queueSize: int,
}

let shallowCopyPartition = (p: partition) => {
  ...p,
  fetchedEventQueue: p.fetchedEventQueue->Array.copy,
}

let copy = (fetchState: t) => {
  let partitions = fetchState.partitions->Js.Array2.map(shallowCopyPartition)
  {
    maxAddrInPartition: fetchState.maxAddrInPartition,
    partitions,
    endBlock: fetchState.endBlock,
    nextPartitionIndex: fetchState.nextPartitionIndex,
    isFetchingAtHead: fetchState.isFetchingAtHead,
    latestFullyFetchedBlock: fetchState.latestFullyFetchedBlock,
    queueSize: fetchState.queueSize,
    normalSelection: fetchState.normalSelection,
    firstEventBlockNumber: fetchState.firstEventBlockNumber,
    chainId: fetchState.chainId,
    indexingContracts: fetchState.indexingContracts,
    dcsToStore: ?fetchState.dcsToStore,
  }
}

/*
Comapritor for two events from the same chain. No need for chain id or timestamp
*/
let eventItemGt = (a: Internal.eventItem, b: Internal.eventItem) =>
  if a.blockNumber > b.blockNumber {
    true
  } else if a.blockNumber === b.blockNumber {
    a.logIndex > b.logIndex
  } else {
    false
  }

/*
Merges two event queues on a single event fetcher

Pass the shorter list into A for better performance
*/
let mergeSortedEventList = (a, b) => Utils.Array.mergeSorted(eventItemGt, a, b)

let mergeIntoPartition = (p: partition, ~target: partition, ~maxAddrInPartition) => {
  switch (p, target) {
  | ({selection: {dependsOnAddresses: true}}, {selection: {dependsOnAddresses: true}}) => {
      let latestFetchedBlock = target.latestFetchedBlock
      let targetContractAddressMapping = target.contractAddressMapping
      let mergingContractAddressMapping = p.contractAddressMapping

      let mergedContractAddressMapping = targetContractAddressMapping->ContractAddressingMap.copy

      let restDcsCount =
        targetContractAddressMapping->ContractAddressingMap.addressCount +
        mergingContractAddressMapping->ContractAddressingMap.addressCount -
        maxAddrInPartition

      let rest = if restDcsCount > 0 {
        let restAddresses = Utils.Set.make()

        let restContractAddressMapping = ContractAddressingMap.make()

        mergingContractAddressMapping.nameByAddress
        ->Js.Dict.keys
        ->Belt.Array.forEach(key => {
          let name = mergingContractAddressMapping.nameByAddress->Js.Dict.unsafeGet(key)
          let address = key->Address.unsafeFromString
          let map =
            restAddresses->Utils.Set.has(address)
              ? restContractAddressMapping
              : mergedContractAddressMapping
          map->ContractAddressingMap.addAddress(~address, ~name)
        })

        Some({
          id: p.id,
          status: {
            fetchingStateId: None,
          },
          fetchedEventQueue: [],
          selection: target.selection,
          contractAddressMapping: restContractAddressMapping,
          latestFetchedBlock,
        })
      } else {
        mergingContractAddressMapping->ContractAddressingMap.mergeInPlace(
          ~target=mergedContractAddressMapping,
        )
        None
      }

      (
        {
          id: target.id,
          status: {
            fetchingStateId: None,
          },
          selection: target.selection,
          contractAddressMapping: mergedContractAddressMapping,
          fetchedEventQueue: mergeSortedEventList(p.fetchedEventQueue, target.fetchedEventQueue),
          latestFetchedBlock,
        },
        rest,
      )
    }
  | ({selection: {dependsOnAddresses: false}}, _)
  | (_, {selection: {dependsOnAddresses: false}}) => (p, Some(target))
  }
}

/**
Updates a given partition with new latest block values and new fetched
events.
*/
let addItemsToPartition = (
  p: partition,
  ~latestFetchedBlock,
  //Events ordered latest to earliest
  ~reversedNewItems: array<Internal.eventItem>,
) => {
  {
    ...p,
    status: {
      fetchingStateId: None,
    },
    latestFetchedBlock,
    fetchedEventQueue: Array.concat(reversedNewItems, p.fetchedEventQueue),
  }
}

/* strategy for TUI synced status:
 * Firstly -> only update synced status after batch is processed (not on batch creation). But also set when a batch tries to be created and there is no batch
 *
 * Secondly -> reset timestampCaughtUpToHead and isFetching at head when dynamic contracts get registered to a chain if they are not within 0.001 percent of the current block height
 *
 * New conditions for valid synced:
 *
 * CASE 1 (chains are being synchronised at the head)
 *
 * All chain fetchers are fetching at the head AND
 * No events that can be processed on the queue (even if events still exist on the individual queues)
 * CASE 2 (chain finishes earlier than any other chain)
 *
 * CASE 3 endblock has been reached and latest processed block is greater than or equal to endblock (both fields must be Some)
 *
 * The given chain fetcher is fetching at the head or latest processed block >= endblock
 * The given chain has processed all events on the queue
 * see https://github.com/Float-Capital/indexer/pull/1388 */

/* Dynamic contracts pose a unique case when calculated whether a chain is synced or not.
 * Specifically, in the initial syncing state from SearchingForEvents -> Synced, where although a chain has technically processed up to all blocks
 * for a contract that emits events with dynamic contracts, it is possible that those dynamic contracts will need to be indexed from blocks way before
 * the current block height. This is a toleration check where if there are dynamic contracts within a batch, check how far are they from the currentblock height.
 * If it is less than 1 thousandth of a percent, then we deem that contract to be within the synced range, and therefore do not reset the synced status of the chain */
let checkIsWithinSyncRange = (~latestFetchedBlock: blockNumberAndTimestamp, ~currentBlockHeight) =>
  (currentBlockHeight->Int.toFloat -. latestFetchedBlock.blockNumber->Int.toFloat) /.
    currentBlockHeight->Int.toFloat <= 0.001

/*
 Update fetchState, merge registers and recompute derived values
 */
let updateInternal = (
  fetchState: t,
  ~partitions=fetchState.partitions,
  ~nextPartitionIndex=fetchState.nextPartitionIndex,
  ~firstEventBlockNumber=fetchState.firstEventBlockNumber,
  ~indexingContracts=fetchState.indexingContracts,
  ~currentBlockHeight=?,
  ~dcsToStore=?,
): t => {
  let firstPartition = partitions->Js.Array2.unsafe_get(0)

  let queueSize = ref(0)
  let latestFullyFetchedBlock = ref(firstPartition.latestFetchedBlock)

  for idx in 0 to partitions->Array.length - 1 {
    let p = partitions->Js.Array2.unsafe_get(idx)

    let partitionQueueSize = p.fetchedEventQueue->Array.length

    queueSize := queueSize.contents + partitionQueueSize

    if latestFullyFetchedBlock.contents.blockNumber > p.latestFetchedBlock.blockNumber {
      latestFullyFetchedBlock := p.latestFetchedBlock
    }
  }

  if (
    Env.Benchmark.shouldSaveData && fetchState.partitions->Array.length !== partitions->Array.length
  ) {
    Benchmark.addSummaryData(
      ~group="Other",
      ~label="Num partitions",
      ~value=partitions->Array.length->Int.toFloat,
    )
  }

  let latestFullyFetchedBlock = latestFullyFetchedBlock.contents

  let isFetchingAtHead = switch currentBlockHeight {
  | None => fetchState.isFetchingAtHead
  | Some(currentBlockHeight) =>
    // Sync isFetchingAtHead when currentBlockHeight is provided
    if latestFullyFetchedBlock.blockNumber >= currentBlockHeight {
      true
    } else if (
      // For dc registration reset the state only when dcs are not in the sync range
      fetchState.isFetchingAtHead &&
      checkIsWithinSyncRange(~latestFetchedBlock=latestFullyFetchedBlock, ~currentBlockHeight)
    ) {
      true
    } else {
      false
    }
  }

  {
    maxAddrInPartition: fetchState.maxAddrInPartition,
    endBlock: fetchState.endBlock,
    normalSelection: fetchState.normalSelection,
    chainId: fetchState.chainId,
    nextPartitionIndex,
    firstEventBlockNumber,
    partitions,
    isFetchingAtHead,
    latestFullyFetchedBlock,
    queueSize: queueSize.contents,
    indexingContracts,
    dcsToStore: ?switch (fetchState.dcsToStore, dcsToStore) {
    | (Some(existingDcs), Some(newDcs)) => Some(Array.concat(existingDcs, newDcs))
    | (Some(existingDcs), None) => Some(existingDcs)
    | (None, Some(newDcs)) => Some(newDcs)
    | (None, None) => None
    },
  }
}

let makeDcPartition = (
  ~partitionIndex,
  ~latestFetchedBlock,
  ~dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>=[],
  ~selection,
) => {
  let contractAddressMapping = ContractAddressingMap.make()

  dynamicContracts->Array.forEach(dc => {
    contractAddressMapping->ContractAddressingMap.addAddress(
      ~name=(dc.contractType :> string),
      ~address=dc.contractAddress,
    )
  })

  {
    id: partitionIndex->Int.toString,
    status: {
      fetchingStateId: None,
    },
    latestFetchedBlock,
    selection,
    contractAddressMapping,
    fetchedEventQueue: [],
  }
}

let numAddresses = fetchState => fetchState.indexingContracts->Js.Dict.keys->Array.length

let warnIfAttemptedAddressRegisterOnDifferentContracts = (
  ~contractAddress,
  ~contractName,
  ~existingContractName,
  ~chainId,
) => {
  if existingContractName != contractName {
    let logger = Logging.createChild(
      ~params={
        "chainId": chainId,
        "contractAddress": contractAddress->Address.toString,
        "existingContractType": existingContractName,
        "newContractType": contractName,
      },
    )
    logger->Logging.childWarn(
      `Contract address ${contractAddress->Address.toString} is already registered as contract ${existingContractName} and cannot also be registered as ${(contractName :> string)}`,
    )
  }
}

let registerDynamicContracts = (
  fetchState: t,
  // These are raw dynamic contracts received from contractRegister call.
  // Might contain duplicates which we should filter out
  dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>,
  ~currentBlockHeight,
) => {
  if fetchState.normalSelection.eventConfigs->Utils.Array.isEmpty {
    // Can the normalSelection be empty?
    // Probably only on pre-registration, but we don't
    // register dynamic contracts during it
    Js.Exn.raiseError(
      "Invalid configuration. No events to fetch for the dynamic contract registration.",
    )
  }

  let indexingContracts = fetchState.indexingContracts->Utils.Dict.shallowCopy
  let dcsToStore = []

  let dcsByStartBlock = Js.Dict.empty()
  dynamicContracts->Array.forEach(dc => {
    // Prevent registering already indexing contracts
    switch indexingContracts->Utils.Dict.dangerouslyGetNonOption(
      dc.contractAddress->Address.toString,
    ) {
    | Some(existingContract) =>
      // FIXME: Instead of filtering out duplicates,
      // we should check the block number first.
      // If new registration with earlier block number
      // we should register it for the missing block range
      warnIfAttemptedAddressRegisterOnDifferentContracts(
        ~contractAddress=dc.contractAddress,
        ~contractName=(dc.contractType :> string),
        ~existingContractName=existingContract.contractName,
        ~chainId=fetchState.chainId,
      )
      ()
    | None => {
        indexingContracts->Js.Dict.set(
          dc.contractAddress->Address.toString,
          {
            address: dc.contractAddress,
            contractName: (dc.contractType :> string),
            startBlockNumber: dc.registeringEventBlockNumber,
            startLogIndex: dc.registeringEventLogIndex,
            register: DC({
              id: dc.id->Utils.magic,
              startBlockTimestamp: dc.registeringEventBlockTimestamp,
              registeringEventContractName: dc.registeringEventContractName,
              registeringEventName: dc.registeringEventName,
              registeringEventSrcAddress: dc.registeringEventSrcAddress,
            }),
          },
        )

        let _ = dcsToStore->Array.push(dc)

        let key = dc.registeringEventBlockNumber->Int.toString
        let dcs = switch dcsByStartBlock->Utils.Dict.dangerouslyGetNonOption(key) {
        | Some(dcs) => dcs
        | None => {
            let dcs = []
            dcsByStartBlock->Js.Dict.set(key, dcs)
            dcs
          }
        }
        dcs->Array.push(dc)
      }
    }
  })

  let blockNumbers = dcsByStartBlock->Js.Dict.keys
  switch blockNumbers {
  // The case when everything was filter out
  | [] => fetchState
  | _ => {
      // Will be in the ASC order by Js spec
      let newPartitions = blockNumbers->Array.mapWithIndex((index, startBlockKey) => {
        let dcs = dcsByStartBlock->Js.Dict.unsafeGet(startBlockKey)
        makeDcPartition(
          ~partitionIndex=fetchState.nextPartitionIndex + index,
          ~dynamicContracts=dcs,
          ~latestFetchedBlock={
            blockNumber: Pervasives.max(startBlockKey->Int.fromString->Option.getExn - 1, 0),
            blockTimestamp: 0,
          },
          ~selection=fetchState.normalSelection,
        )
      })

      Prometheus.IndexingAddresses.set(
        ~addressesCount=fetchState->numAddresses + dynamicContracts->Array.length,
        ~chainId=fetchState.chainId,
      )

      fetchState->updateInternal(
        ~partitions=fetchState.partitions->Js.Array2.concat(newPartitions),
        ~currentBlockHeight,
        ~dcsToStore,
        ~indexingContracts,
        ~nextPartitionIndex=fetchState.nextPartitionIndex + newPartitions->Array.length,
      )
    }
  }
}

type queryTarget =
  | Head
  | EndBlock({toBlock: int})
  | Merge({
      // The partition we are going to merge into
      // It shouldn't be fetching during the query
      intoPartitionId: string,
      toBlock: int,
    })

type query = {
  partitionId: string,
  fromBlock: int,
  selection: selection,
  contractAddressMapping: ContractAddressingMap.mapping,
  target: queryTarget,
}

exception UnexpectedPartitionNotFound({partitionId: string})
exception UnexpectedMergeQueryResponse({message: string})

/*
Updates fetchState with a response for a given query.
Returns Error if the partition with given query cannot be found (unexpected)
If MergeQuery caught up to the target partition, it triggers the merge of the partitions.

newItems are ordered earliest to latest (as they are returned from the worker)
*/
let handleQueryResult = (
  {partitions} as fetchState: t,
  ~query: query,
  ~latestFetchedBlock: blockNumberAndTimestamp,
  ~reversedNewItems,
  ~currentBlockHeight,
): result<t, exn> =>
  {
    let partitionId = query.partitionId

    switch partitions->Array.getIndexBy(p => p.id === partitionId) {
    | Some(pIndex) =>
      let p = partitions->Js.Array2.unsafe_get(pIndex)
      let updatedPartition = p->addItemsToPartition(~latestFetchedBlock, ~reversedNewItems)

      switch query.target {
      | Head
      | EndBlock(_) =>
        Ok(partitions->Utils.Array.setIndexImmutable(pIndex, updatedPartition))
      | Merge({intoPartitionId}) =>
        switch partitions->Array.getIndexBy(p => p.id === intoPartitionId) {
        | Some(targetIndex)
          if (partitions->Js.Array2.unsafe_get(targetIndex)).latestFetchedBlock.blockNumber ===
            latestFetchedBlock.blockNumber => {
            let target = partitions->Js.Array2.unsafe_get(targetIndex)
            let (merged, rest) =
              updatedPartition->mergeIntoPartition(
                ~target,
                ~maxAddrInPartition=fetchState.maxAddrInPartition,
              )

            let updatedPartitions = partitions->Utils.Array.setIndexImmutable(targetIndex, merged)
            let updatedPartitions = switch rest {
            | Some(rest) => {
                updatedPartitions->Js.Array2.unsafe_set(pIndex, rest)
                updatedPartitions
              }
            | None => updatedPartitions->Utils.Array.removeAtIndex(pIndex)
            }
            Ok(updatedPartitions)
          }
        | _ => Ok(partitions->Utils.Array.setIndexImmutable(pIndex, updatedPartition))
        }
      }
    | None =>
      Error(
        UnexpectedPartitionNotFound({
          partitionId: partitionId,
        }),
      )
    }
  }->Result.map(partitions => {
    fetchState->updateInternal(
      ~partitions,
      ~currentBlockHeight,
      ~firstEventBlockNumber=switch reversedNewItems->Utils.Array.last {
      | Some(newFirstItem) =>
        Utils.Math.minOptInt(fetchState.firstEventBlockNumber, Some(newFirstItem.blockNumber))
      | None => fetchState.firstEventBlockNumber
      },
    )
  })

let makePartitionQuery = (p: partition, ~endBlock, ~mergeTarget) => {
  let fromBlock = switch p.latestFetchedBlock.blockNumber {
  | 0 => 0
  | latestFetchedBlockNumber => latestFetchedBlockNumber + 1
  }
  switch (endBlock, mergeTarget) {
  | (Some(endBlock), _) if fromBlock > endBlock => None
  | (_, Some(mergeTarget)) =>
    Some(
      Merge({
        toBlock: mergeTarget.latestFetchedBlock.blockNumber,
        intoPartitionId: mergeTarget.id,
      }),
    )
  | (Some(endBlock), None) => Some(EndBlock({toBlock: endBlock}))
  | (None, None) => Some(Head)
  }->Option.map(target => {
    {
      partitionId: p.id,
      fromBlock,
      target,
      selection: p.selection,
      contractAddressMapping: p.contractAddressMapping,
    }
  })
}

type nextQuery =
  | ReachedMaxConcurrency
  | WaitingForNewBlock
  | NothingToQuery
  | Ready(array<query>)

let startFetchingQueries = ({partitions}: t, ~queries: array<query>, ~stateId) => {
  queries->Array.forEach(q => {
    switch partitions->Js.Array2.find(p => p.id === q.partitionId) {
    // Shouldn't be mutated to None anymore
    // The status will be immutably set to the initial one when we handle response
    | Some(p) => p.status.fetchingStateId = Some(stateId)
    | None => Js.Exn.raiseError("Unexpected case: Couldn't find partition for the fetching query")
    }
  })
}

@inline
let isFullPartition = (p: partition, ~maxAddrInPartition) => {
  switch p {
  | {selection: {dependsOnAddresses: false}} => true
  | {contractAddressMapping} =>
    contractAddressMapping->ContractAddressingMap.addressCount >= maxAddrInPartition
  }
}

let getNextQuery = (
  {partitions, maxAddrInPartition, endBlock, latestFullyFetchedBlock}: t,
  ~concurrencyLimit,
  ~maxQueueSize,
  ~currentBlockHeight,
  ~stateId,
) => {
  if currentBlockHeight === 0 {
    WaitingForNewBlock
  } else if concurrencyLimit === 0 {
    ReachedMaxConcurrency
  } else {
    let fullPartitions = []
    let mergingPartitions = []
    let areMergingPartitionsFetching = ref(false)
    let mostBehindMergingPartition = ref(None)
    let mergingPartitionTarget = ref(None)
    let shouldWaitForNewBlock = ref(
      switch endBlock {
      | Some(endBlock) => currentBlockHeight < endBlock
      | None => true
      },
    )

    let checkIsFetchingPartition = p => {
      switch p.status.fetchingStateId {
      | Some(fetchingStateId) => stateId <= fetchingStateId
      | None => false
      }
    }

    for idx in 0 to partitions->Js.Array2.length - 1 {
      let p = partitions->Js.Array2.unsafe_get(idx)

      let isFetching = checkIsFetchingPartition(p)
      let isReachedTheHead = p.latestFetchedBlock.blockNumber >= currentBlockHeight

      if isFetching || !isReachedTheHead {
        // Even if there are some partitions waiting for the new block
        // We still want to wait for all partitions reaching the head
        // because they might update currentBlockHeight in their response
        // Also, there are cases when some partitions fetching at 50% of the chain
        // and we don't want to poll the head for a few small partitions
        shouldWaitForNewBlock := false
      }

      if p->isFullPartition(~maxAddrInPartition) {
        fullPartitions->Array.push(p)
      } else {
        mergingPartitions->Array.push(p)

        mostBehindMergingPartition :=
          switch mostBehindMergingPartition.contents {
          | Some(mostBehindMergingPartition) =>
            if (
              // The = check is important here. We don't want to have a target
              // with the same latestFetchedBlock. They should be merged in separate queries
              mostBehindMergingPartition.latestFetchedBlock.blockNumber ===
                p.latestFetchedBlock.blockNumber
            ) {
              mostBehindMergingPartition
            } else if (
              mostBehindMergingPartition.latestFetchedBlock.blockNumber <
              p.latestFetchedBlock.blockNumber
            ) {
              mergingPartitionTarget :=
                switch mergingPartitionTarget.contents {
                | Some(mergingPartitionTarget)
                  if mergingPartitionTarget.latestFetchedBlock.blockNumber <
                  p.latestFetchedBlock.blockNumber => mergingPartitionTarget
                | _ => p
                }->Some
              mostBehindMergingPartition
            } else {
              mergingPartitionTarget := Some(mostBehindMergingPartition)
              p
            }
          | None => p
          }->Some

        if isFetching {
          areMergingPartitionsFetching := true
        }
      }
    }

    let maxPartitionQueueSize = maxQueueSize / (fullPartitions->Array.length + 1)
    let isWithinSyncRange = checkIsWithinSyncRange(
      ~latestFetchedBlock=latestFullyFetchedBlock,
      ~currentBlockHeight,
    )
    let queries = []

    let registerPartitionQuery = (p, ~checkQueueSize, ~mergeTarget=?) => {
      if (
        p->checkIsFetchingPartition->not &&
        p.latestFetchedBlock.blockNumber < currentBlockHeight &&
        (checkQueueSize ? p.fetchedEventQueue->Array.length < maxPartitionQueueSize : true) && (
          isWithinSyncRange
            ? true
            : !checkIsWithinSyncRange(~latestFetchedBlock=p.latestFetchedBlock, ~currentBlockHeight)
        )
      ) {
        switch p->makePartitionQuery(~endBlock, ~mergeTarget) {
        | Some(q) => queries->Array.push(q)
        | None => ()
        }
      }
    }

    fullPartitions->Array.forEach(p => p->registerPartitionQuery(~checkQueueSize=true))

    if areMergingPartitionsFetching.contents->not {
      switch mergingPartitions {
      | [] => ()
      | [p] =>
        // If there's only one non-full partition without merge target,
        // check that it didn't exceed queue size
        p->registerPartitionQuery(~checkQueueSize=true)
      | _ =>
        switch (mostBehindMergingPartition.contents, mergingPartitionTarget.contents) {
        | (Some(p), None) =>
          // Even though there's no merge target for the query,
          // we still have partitions to merge, so don't check for the queue size here
          p->registerPartitionQuery(~checkQueueSize=false)
        | (Some(p), Some(mergeTarget)) =>
          p->registerPartitionQuery(~checkQueueSize=false, ~mergeTarget)
        | (None, _) =>
          Js.Exn.raiseError("Unexpected case, should always have a most behind partition.")
        }
      }
    }

    if queries->Utils.Array.isEmpty {
      if shouldWaitForNewBlock.contents {
        WaitingForNewBlock
      } else {
        NothingToQuery
      }
    } else {
      Ready(
        if queries->Array.length > concurrencyLimit {
          queries
          ->Js.Array2.sortInPlaceWith((a, b) => a.fromBlock - b.fromBlock)
          ->Js.Array2.slice(~start=0, ~end_=concurrencyLimit)
        } else {
          queries
        },
      )
    }
  }
}

type itemWithPopFn = {item: Internal.eventItem, popItemOffQueue: unit => unit}

/**
Represents a fetchState partitions head of the  fetchedEventQueue as either
an existing item, or no item with latest fetched block data
*/
type queueItem =
  | Item(itemWithPopFn)
  | NoItem({latestFetchedBlock: blockNumberAndTimestamp})

let queueItemBlockNumber = (queueItem: queueItem) => {
  switch queueItem {
  | Item({item}) => item.blockNumber
  | NoItem({latestFetchedBlock: {blockNumber}}) => blockNumber === 0 ? 0 : blockNumber + 1
  }
}

let queueItemIsInReorgThreshold = (
  queueItem: queueItem,
  ~currentBlockHeight,
  ~heighestBlockBelowThreshold,
) => {
  if currentBlockHeight === 0 {
    false
  } else {
    switch queueItem {
    | Item(_) => queueItem->queueItemBlockNumber > heighestBlockBelowThreshold
    | NoItem(_) => queueItem->queueItemBlockNumber > heighestBlockBelowThreshold
    }
  }
}

/**
Simple constructor for no item from partition
*/
let makeNoItem = ({latestFetchedBlock}: partition) => NoItem({
  latestFetchedBlock: latestFetchedBlock,
})

/**
Creates a compareable value for items and no items on partition queues.
Block number takes priority here. Since a latest fetched timestamp could
be zero from initialization of partition but a higher latest fetched block number exists

Note: on the chain manager, when comparing multi chain, the timestamp is the highest priority compare value
*/
let qItemLt = (a, b) => {
  let aBlockNumber = a->queueItemBlockNumber
  let bBlockNumber = b->queueItemBlockNumber
  if aBlockNumber < bBlockNumber {
    true
  } else if aBlockNumber === bBlockNumber {
    switch (a, b) {
    | (Item(a), Item(b)) => a.item.logIndex < b.item.logIndex
    | (NoItem(_), Item(_)) => true
    | (Item(_), NoItem(_))
    | (NoItem(_), NoItem(_)) => false
    }
  } else {
    false
  }
}

/**
Returns queue item WITHOUT the updated fetch state. Used for checking values
not updating state
*/
let getEarliestEventInPartition = (p: partition) => {
  switch p.fetchedEventQueue->Utils.Array.last {
  | Some(head) =>
    Item({item: head, popItemOffQueue: () => p.fetchedEventQueue->Js.Array2.pop->ignore})
  | None => makeNoItem(p)
  }
}

/**
Gets the earliest queueItem from thgetNodeEarliestEventWithUpdatedQueue.

Finds the earliest queue item across all partitions and then returns that
queue item with an update fetch state.
*/
let getEarliestEvent = ({partitions}: t) => {
  let item = ref(partitions->Js.Array2.unsafe_get(0)->getEarliestEventInPartition)
  for idx in 1 to partitions->Array.length - 1 {
    let p = partitions->Js.Array2.unsafe_get(idx)
    let pItem = p->getEarliestEventInPartition
    if pItem->qItemLt(item.contents) {
      item := pItem
    }
  }
  item.contents
}

/**
Instantiates a fetch state with partitions for initial addresses
*/
let make = (
  ~startBlock,
  ~endBlock,
  ~eventConfigs: array<Internal.eventConfig>,
  ~staticContracts: dict<array<Address.t>>,
  ~dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>,
  ~maxAddrInPartition,
  ~chainId,
): t => {
  let latestFetchedBlock = {
    blockTimestamp: 0,
    // Here's a bug that startBlock: 1 won't work
    blockNumber: Pervasives.max(startBlock - 1, 0),
  }

  let notDependingOnAddresses = []
  let normalEventConfigs = []
  let contractNamesWithNormalEvents = Utils.Set.make()
  let indexingContracts = Js.Dict.empty()

  eventConfigs->Array.forEach(ec => {
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
      status: {
        fetchingStateId: None,
      },
      latestFetchedBlock,
      selection: {
        dependsOnAddresses: false,
        eventConfigs: notDependingOnAddresses,
      },
      contractAddressMapping: ContractAddressingMap.make(),
      fetchedEventQueue: [],
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
          status: {
            fetchingStateId: None,
          },
          latestFetchedBlock,
          selection: normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
          fetchedEventQueue: [],
        }
      }

      let pendingNormalPartition = ref(makePendingNormalPartition())

      let registerAddress = (
        contractName,
        address,
        ~dc: option<TablesStatic.DynamicContractRegistry.t>=?,
      ) => {
        let pendingPartition = pendingNormalPartition.contents
        pendingPartition.contractAddressMapping->ContractAddressingMap.addAddress(
          ~name=contractName,
          ~address,
        )
        indexingContracts->Js.Dict.set(
          address->Address.toString,
          switch dc {
          | Some(dc) => {
              address,
              contractName,
              startBlockNumber: dc.registeringEventBlockNumber,
              startLogIndex: dc.registeringEventLogIndex,
              register: DC({
                id: dc.id->Utils.magic,
                startBlockTimestamp: dc.registeringEventBlockTimestamp,
                registeringEventContractName: dc.registeringEventContractName,
                registeringEventName: dc.registeringEventName,
                registeringEventSrcAddress: dc.registeringEventSrcAddress,
              }),
            }
          | None => {
              address,
              contractName,
              startBlockNumber: startBlock,
              startLogIndex: 0,
              register: Config,
            }
          },
        )
        if (
          pendingPartition.contractAddressMapping->ContractAddressingMap.addressCount ===
            maxAddrInPartition
        ) {
          partitions->Array.push(pendingPartition)
          pendingNormalPartition := makePendingNormalPartition()
        }
      }

      staticContracts
      ->Js.Dict.entries
      ->Array.forEach(((contractName, addresses)) => {
        if contractNamesWithNormalEvents->Utils.Set.has(contractName) {
          addresses->Array.forEach(a => {
            registerAddress(contractName, a)
          })
        }
      })

      dynamicContracts->Array.forEach(dc => {
        let contractName = (dc.contractType :> string)
        if contractNamesWithNormalEvents->Utils.Set.has(contractName) {
          registerAddress(contractName, dc.contractAddress, ~dc)
        }
      })

      if (
        pendingNormalPartition.contents.contractAddressMapping->ContractAddressingMap.addressCount > 0
      ) {
        partitions->Array.push(pendingNormalPartition.contents)
      }
    }
  }

  if partitions->Array.length === 0 {
    Js.Exn.raiseError(
      "Invalid configuration: Nothing to fetch. Make sure that you provided at least one contract address to index, or have events with Wildcard mode enabled.",
    )
  }

  if Env.Benchmark.shouldSaveData {
    Benchmark.addSummaryData(
      ~group="Other",
      ~label="Num partitions",
      ~value=partitions->Array.length->Int.toFloat,
    )
  }

  let numAddresses = indexingContracts->Js.Dict.keys->Array.length
  Prometheus.IndexingAddresses.set(~addressesCount=numAddresses, ~chainId)
  switch endBlock {
  | Some(endBlock) => Prometheus.IndexingEndBlock.set(~endBlock, ~chainId)
  | None => ()
  }

  {
    partitions,
    nextPartitionIndex: partitions->Array.length,
    isFetchingAtHead: false,
    maxAddrInPartition,
    chainId,
    endBlock,
    latestFullyFetchedBlock: latestFetchedBlock,
    queueSize: 0,
    firstEventBlockNumber: None,
    normalSelection,
    indexingContracts,
  }
}

let queueSize = ({queueSize}: t) => queueSize

/**
* Returns the latest block number fetched for the lowest fetcher queue (ie the earliest un-fetched dynamic contract)
*/
let getLatestFullyFetchedBlock = ({latestFullyFetchedBlock}: t) => latestFullyFetchedBlock

let pruneQueueFromFirstChangeEvent = (
  queue: array<Internal.eventItem>,
  ~firstChangeEvent: blockNumberAndLogIndex,
) => {
  queue->Array.keep(item =>
    (item.blockNumber, item.logIndex) < (firstChangeEvent.blockNumber, firstChangeEvent.logIndex)
  )
}

/**
Rolls back partitions to the given valid block
*/
let rollbackPartition = (
  p: partition,
  ~firstChangeEvent: blockNumberAndLogIndex,
  ~addressesToRemove,
) => {
  switch p {
  | {selection: {dependsOnAddresses: false}} =>
    Some({
      ...p,
      status: {
        fetchingStateId: None,
      },
    })
  | {contractAddressMapping} =>
    //remove them from the contract address mapping and dynamic contract addresses mapping
    let contractAddressMapping =
      contractAddressMapping->ContractAddressingMap.removeAddresses(~addressesToRemove)

    if contractAddressMapping->ContractAddressingMap.addressCount === 0 {
      None
    } else {
      let shouldRollbackFetched = p.latestFetchedBlock.blockNumber >= firstChangeEvent.blockNumber

      let fetchedEventQueue = if shouldRollbackFetched {
        p.fetchedEventQueue->pruneQueueFromFirstChangeEvent(~firstChangeEvent)
      } else {
        p.fetchedEventQueue
      }

      Some({
        id: p.id,
        selection: p.selection,
        status: {
          fetchingStateId: None,
        },
        contractAddressMapping,
        fetchedEventQueue,
        latestFetchedBlock: shouldRollbackFetched
          ? {
              blockNumber: Pervasives.max(firstChangeEvent.blockNumber - 1, 0),
              blockTimestamp: 0,
            }
          : p.latestFetchedBlock,
      })
    }
  }
}

let rollback = (fetchState: t, ~firstChangeEvent) => {
  let addressesToRemove = []
  let indexingContracts = Js.Dict.empty()

  fetchState.indexingContracts
  ->Js.Dict.keys
  ->Array.forEach(address => {
    let indexingContract = fetchState.indexingContracts->Js.Dict.unsafeGet(address)
    if (
      (indexingContract.startBlockNumber, indexingContract.startLogIndex) >=
      (firstChangeEvent.blockNumber, firstChangeEvent.logIndex)
    ) {
      //If the registration block is later than the first change event,
      //Do not keep it and add to the removed addresses
      addressesToRemove->Array.push(address->Address.unsafeFromString)
    } else {
      indexingContracts->Js.Dict.set(address, indexingContract)
    }
  })

  let partitions =
    fetchState.partitions->Array.keepMap(p =>
      p->rollbackPartition(~firstChangeEvent, ~addressesToRemove)
    )

  fetchState->updateInternal(~partitions, ~indexingContracts)
}

/**
* Returns a boolean indicating whether the fetch state is actively indexing
* used for comparing event queues in the chain manager
*/
let isActivelyIndexing = ({latestFullyFetchedBlock, endBlock} as fetchState: t) => {
  switch endBlock {
  | Some(endBlock) =>
    let isPastEndblock = latestFullyFetchedBlock.blockNumber >= endBlock
    if isPastEndblock {
      fetchState->queueSize > 0
    } else {
      true
    }
  | None => true
  }
}
