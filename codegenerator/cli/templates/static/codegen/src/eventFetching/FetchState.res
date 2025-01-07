open Belt

/**
The block number and log index of the event that registered a
dynamic contract
*/
type dynamicContractId = EventUtils.eventIndex

type blockNumberAndTimestamp = {
  blockNumber: int,
  blockTimestamp: int,
}

type blockNumberAndLogIndex = {blockNumber: int, logIndex: int}

type status = {mutable fetchingStateId: option<int>}

/**
A state that holds a queue of events and data regarding what to fetch next.
There's always a root register and potentially additional registers for dynamic contracts.
When the registers are caught up to each other they are getting merged
*/
type register = {
  id: string,
  status: status,
  latestFetchedBlock: blockNumberAndTimestamp,
  contractAddressMapping: ContractAddressingMap.mapping,
  //Events ordered from latest to earliest
  fetchedEventQueue: array<Internal.eventItem>,
  //Used to prune dynamic contract registrations in the event
  //of a rollback.
  dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>,
}

type t = {
  partitions: array<register>,
  // Used for the incremental partition id. Can't use the partitions length,
  // since partitions might be deleted on merge or cleaned up
  nextPartitionIndex: int,
  isFetchingAtHead: bool,
  endBlock: option<int>,
  maxAddrInPartition: int,
  batchSize: int,
  firstEventBlockNumber: option<int>,
  // Fields computed by updateInternal
  latestFullyFetchedBlock: blockNumberAndTimestamp,
  queueSize: int,
}

let shallowCopyRegister = (register: register) => {
  ...register,
  fetchedEventQueue: register.fetchedEventQueue->Array.copy,
}

let copy = (fetchState: t) => {
  let partitions = fetchState.partitions->Js.Array2.map(shallowCopyRegister)
  {
    maxAddrInPartition: fetchState.maxAddrInPartition,
    partitions,
    endBlock: fetchState.endBlock,
    nextPartitionIndex: fetchState.nextPartitionIndex,
    isFetchingAtHead: fetchState.isFetchingAtHead,
    latestFullyFetchedBlock: fetchState.latestFullyFetchedBlock,
    batchSize: fetchState.batchSize,
    queueSize: fetchState.queueSize,
    firstEventBlockNumber: fetchState.firstEventBlockNumber,
  }
}

/*
Comapritor for two events from the same chain. No need for chain id or timestamp
*/
/*
Returns the latest of two events on the same chain
*/
let getEventCmp = (event: Internal.eventItem) => {
  (event.blockNumber, event.logIndex)
}

let eventCmp = (a, b) => a->getEventCmp > b->getEventCmp

/*
Merges two event queues on a single event fetcher

Pass the shorter list into A for better performance
*/
let mergeSortedEventList = (a, b) => Utils.Array.mergeSorted(eventCmp, a, b)

let mergeIntoPartition = (register: register, ~target: register, ~maxAddrInPartition) => {
  let latestFetchedBlock = target.latestFetchedBlock

  let mergedContractAddressMapping = target.contractAddressMapping->ContractAddressingMap.copy
  let mergedDynamicContracts = target.dynamicContracts->Js.Array2.copy

  let restDcsCount =
    target.contractAddressMapping->ContractAddressingMap.addressCount +
    register.contractAddressMapping->ContractAddressingMap.addressCount -
    maxAddrInPartition

  let rest = if restDcsCount > 0 {
    let restAddresses = Utils.Set.make()

    let restDcs = register.dynamicContracts->Js.Array2.slice(~start=0, ~end_=restDcsCount)
    restDcs->Array.forEach(dc => {
      let _ = restAddresses->Utils.Set.add(dc.contractAddress)
    })

    let restContractAddressMapping = ContractAddressingMap.make()

    register.contractAddressMapping.nameByAddress
    ->Js.Dict.keys
    ->Belt.Array.forEach(key => {
      let name = register.contractAddressMapping.nameByAddress->Js.Dict.unsafeGet(key)
      let address = key->Address.unsafeFromString
      let map =
        restAddresses->Utils.Set.has(address)
          ? restContractAddressMapping
          : mergedContractAddressMapping
      map->ContractAddressingMap.addAddress(~address, ~name)
    })

    let _ =
      mergedDynamicContracts->Js.Array2.pushMany(
        register.dynamicContracts->Js.Array2.sliceFrom(restDcsCount),
      )

    Some({
      id: register.id,
      status: {
        fetchingStateId: None,
      },
      fetchedEventQueue: [],
      contractAddressMapping: restContractAddressMapping,
      dynamicContracts: restDcs,
      latestFetchedBlock,
    })
  } else {
    register.contractAddressMapping->ContractAddressingMap.mergeInPlace(
      ~target=mergedContractAddressMapping,
    )
    let _ = mergedDynamicContracts->Js.Array2.pushMany(register.dynamicContracts)
    None
  }

  (
    {
      id: target.id,
      status: {
        fetchingStateId: None,
      },
      fetchedEventQueue: mergeSortedEventList(register.fetchedEventQueue, target.fetchedEventQueue),
      contractAddressMapping: mergedContractAddressMapping,
      dynamicContracts: mergedDynamicContracts,
      latestFetchedBlock,
    },
    rest,
  )
}

/**
Updates a given register with new latest block values and new fetched
events.
*/
let addItemsToPartition = (
  register: register,
  ~latestFetchedBlock,
  //Events ordered latest to earliest
  ~reversedNewItems: array<Internal.eventItem>,
) => {
  {
    ...register,
    status: {
      fetchingStateId: None,
    },
    latestFetchedBlock,
    fetchedEventQueue: Array.concat(reversedNewItems, register.fetchedEventQueue),
  }
}

/*
 Update fetchState, merge registers and recompute derived values
 */
let updateInternal = (
  fetchState: t,
  ~partitions=fetchState.partitions,
  ~nextPartitionIndex=fetchState.nextPartitionIndex,
  ~isFetchingAtHead=fetchState.isFetchingAtHead,
  ~batchSize=fetchState.batchSize,
  ~firstEventBlockNumber=fetchState.firstEventBlockNumber,
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

  {
    maxAddrInPartition: fetchState.maxAddrInPartition,
    endBlock: fetchState.endBlock,
    nextPartitionIndex,
    firstEventBlockNumber,
    batchSize,
    partitions,
    isFetchingAtHead,
    latestFullyFetchedBlock: latestFullyFetchedBlock.contents,
    queueSize: queueSize.contents,
  }
}

let makePartition = (
  ~partitionIndex,
  ~latestFetchedBlock,
  ~dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>=[],
  ~staticContracts=[],
) => {
  let contractAddressMapping = ContractAddressingMap.make()

  staticContracts->Array.forEach(((contractName, address)) => {
    contractAddressMapping->ContractAddressingMap.addAddress(~name=contractName, ~address)
  })

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
    contractAddressMapping,
    dynamicContracts,
    fetchedEventQueue: [],
  }
}

let registerDynamicContracts = (
  fetchState: t,
  dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>,
  ~isFetchingAtHead,
) => {
  let dcsByStartBlock = Js.Dict.empty()
  dynamicContracts->Array.forEach(dc => {
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
  })

  // Will be in the ASC order by Js spec
  let newPartitions =
    dcsByStartBlock
    ->Js.Dict.entries
    ->Array.mapWithIndex((index, (startBlockKey, dcs)) => {
      makePartition(
        ~partitionIndex=fetchState.nextPartitionIndex + index,
        ~dynamicContracts=dcs,
        ~latestFetchedBlock={
          blockNumber: Pervasives.max(startBlockKey->Int.fromString->Option.getExn - 1, 0),
          blockTimestamp: 0,
        },
      )
    })

  fetchState->updateInternal(
    ~partitions=fetchState.partitions->Js.Array2.concat(newPartitions),
    ~isFetchingAtHead,
    ~nextPartitionIndex=fetchState.nextPartitionIndex + newPartitions->Array.length,
  )
}

type partitionQuery = {
  partitionId: string,
  fromBlock: int,
  toBlock: option<int>,
  contractAddressMapping: ContractAddressingMap.mapping,
}

type mergeQuery = {
  // The catching up partition
  partitionId: string,
  // The partition we are going to merge into
  // It shouldn't be fetching during the query
  intoPartitionId: string,
  fromBlock: int,
  toBlock: int,
  contractAddressMapping: ContractAddressingMap.mapping,
}

type query =
  | PartitionQuery(partitionQuery)
  | MergeQuery(mergeQuery)

let queryFromBlock = query => {
  switch query {
  | PartitionQuery({fromBlock}) => fromBlock
  | MergeQuery({fromBlock}) => fromBlock
  }
}

let queryPartitionId = query => {
  switch query {
  | PartitionQuery({partitionId}) => partitionId
  | MergeQuery({partitionId}) => partitionId
  }
}

let shouldApplyWildcards = (~partitionId) => partitionId === "0"

exception UnexpectedPartitionNotFound({partitionId: string})
exception UnexpectedMergeQueryResponse({message: string})

/*
Updates node at given id with given values and checks to see if it can be merged into its next register.
Returns Error if the node with given id cannot be found (unexpected)

newItems are ordered earliest to latest (as they are returned from the worker)
*/
let setQueryResponse = (
  {partitions} as fetchState: t,
  ~query: query,
  ~latestFetchedBlock: blockNumberAndTimestamp,
  ~newItems,
  ~currentBlockHeight,
): result<t, exn> => {
  switch query {
  | PartitionQuery({partitionId})
  | MergeQuery({partitionId}) =>
    switch partitions->Array.getIndexBy(p => p.id === partitionId) {
    | Some(pIndex) =>
      let p = partitions->Js.Array2.unsafe_get(pIndex)
      let updatedPartition =
        p->addItemsToPartition(~latestFetchedBlock, ~reversedNewItems=newItems->Array.reverse)

      switch query {
      | PartitionQuery(_) => Ok(partitions->Utils.Array.setIndexImmutable(pIndex, updatedPartition))
      | MergeQuery({intoPartitionId}) =>
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
      ~isFetchingAtHead=fetchState.isFetchingAtHead ||
      currentBlockHeight <= latestFetchedBlock.blockNumber,
      ~firstEventBlockNumber=switch newItems->Array.get(0) {
      | Some(newFirstItem) =>
        Utils.Math.minOptInt(fetchState.firstEventBlockNumber, Some(newFirstItem.blockNumber))
      | None => fetchState.firstEventBlockNumber
      },
    )
  })
}

let makePartitionQuery = (register: register, ~endBlock) => {
  let fromBlock = switch register.latestFetchedBlock.blockNumber {
  | 0 => 0
  | latestFetchedBlockNumber => latestFetchedBlockNumber + 1
  }
  switch endBlock {
  | Some(endBlock) if fromBlock > endBlock => None
  | _ =>
    Some({
      partitionId: register.id,
      fromBlock,
      toBlock: endBlock,
      contractAddressMapping: register.contractAddressMapping,
    })
  }
}

type nextQuery =
  | ReachedMaxConcurrency
  | WaitingForNewBlock
  | NothingToQuery
  | Ready(array<query>)

let startFetchingQueries = ({partitions}: t, ~queries: array<query>, ~stateId) => {
  queries->Array.forEach(q => {
    switch partitions->Js.Array2.find(p => p.id === q->queryPartitionId) {
    // Shouldn't be mutated to None anymore
    // The status will be immutably set to the initial one when we handle response
    | Some(p) => p.status.fetchingStateId = Some(stateId)
    | None => Js.Exn.raiseError("Unexpected case: Couldn't find partition for the fetching query")
    }
  })
}

let getNextQuery = (
  {partitions, maxAddrInPartition, endBlock}: t,
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
    let hasFetchingPartition = ref(false)
    let areMergingPartitionsFetching = ref(false)
    let mostBehindMergingPartition = ref(None)
    let mergingPartitionTarget = ref(None)

    let checkIsFetchingPartition = p => {
      switch p.status.fetchingStateId {
      | Some(fetchingStateId) => stateId <= fetchingStateId
      | None => false
      }
    }

    for idx in 0 to partitions->Js.Array2.length - 1 {
      let p = partitions->Js.Array2.unsafe_get(idx)

      let isFetching = checkIsFetchingPartition(p)

      if isFetching {
        hasFetchingPartition := true
      }

      if p.contractAddressMapping->ContractAddressingMap.addressCount >= maxAddrInPartition {
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
    let hasQueryWaitingForNewBlock = ref(false)
    let queries = []

    let registerPartitionQuery = (p, ~checkQueueSize, ~mergeTarget=?) => {
      if (
        p->checkIsFetchingPartition->not && (
            checkQueueSize ? p.fetchedEventQueue->Array.length < maxPartitionQueueSize : true
          )
      ) {
        switch p->makePartitionQuery(~endBlock) {
        | Some(q) =>
          if q.fromBlock > currentBlockHeight {
            hasQueryWaitingForNewBlock := true
          } else {
            queries->Array.push(
              switch mergeTarget {
              | Some(mergeTarget)
                if // This is to prevent breaking the current check for shouldApplyWildcards
                !shouldApplyWildcards(~partitionId=q.partitionId) =>
                MergeQuery({
                  partitionId: q.partitionId,
                  contractAddressMapping: q.contractAddressMapping,
                  fromBlock: q.fromBlock,
                  toBlock: mergeTarget.latestFetchedBlock.blockNumber,
                  intoPartitionId: mergeTarget.id,
                })
              | _ => PartitionQuery(q)
              },
            )
          }
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
      // Even if there are queries waiting for the new block
      // We still want to wait for the all fetching queries, because they might update
      // the currentBlockHeight in their response
      if hasQueryWaitingForNewBlock.contents && !hasFetchingPartition.contents {
        WaitingForNewBlock
      } else {
        NothingToQuery
      }
    } else {
      Ready(
        if queries->Array.length > concurrencyLimit {
          queries
          ->Js.Array2.sortInPlaceWith((a, b) => a->queryFromBlock - b->queryFromBlock)
          ->Js.Array2.slice(~start=0, ~end_=concurrencyLimit)
        } else {
          queries
        },
      )
    }
  }
}

type itemWithPopFn = {item: Internal.eventItem, popItemOffQueue: unit => unit}

let itemIsInReorgThreshold = (item: itemWithPopFn, ~heighestBlockBelowThreshold) => {
  //Only consider it in reorg threshold when the current block number has advanced beyond 0
  if heighestBlockBelowThreshold > 0 {
    item.item.blockNumber > heighestBlockBelowThreshold
  } else {
    false
  }
}

/**
Represents a fetchState registers head of the  fetchedEventQueue as either
an existing item, or no item with latest fetched block data
*/
type queueItem =
  | Item(itemWithPopFn)
  | NoItem(blockNumberAndTimestamp)

let queueItemIsInReorgThreshold = (queueItem: queueItem, ~heighestBlockBelowThreshold) => {
  switch queueItem {
  | Item(itemWithPopFn) => itemWithPopFn->itemIsInReorgThreshold(~heighestBlockBelowThreshold)
  | NoItem({blockNumber}) => blockNumber > heighestBlockBelowThreshold
  }
}

/**
Creates a compareable value for items and no items on register queues.
Block number takes priority here. Since a latest fetched timestamp could
be zero from initialization of register but a higher latest fetched block number exists

Note: on the chain manager, when comparing multi chain, the timestamp is the highest priority compare value
*/
let getCmpVal = qItem =>
  switch qItem {
  | Item({item: {blockNumber, logIndex}}) => (blockNumber, logIndex)
  | NoItem({blockNumber}) => (blockNumber, 0)
  }

/**
Simple constructor for no item from register
*/
let makeNoItem = ({latestFetchedBlock}: register) => NoItem(latestFetchedBlock)

let qItemLt = (a, b) => a->getCmpVal < b->getCmpVal

/**
Returns queue item WITHOUT the updated fetch state. Used for checking values
not updating state
*/
let getEarliestEventInRegister = (register: register) => {
  switch register.fetchedEventQueue->Utils.Array.last {
  | Some(head) =>
    Item({item: head, popItemOffQueue: () => register.fetchedEventQueue->Js.Array2.pop->ignore})
  | None => makeNoItem(register)
  }
}

/**
Gets the earliest queueItem from thgetNodeEarliestEventWithUpdatedQueue.

Finds the earliest queue item across all registers and then returns that
queue item with an update fetch state.
*/
let getEarliestEvent = ({partitions}: t) => {
  let item = ref(partitions->Js.Array2.unsafe_get(0)->getEarliestEventInRegister)
  for idx in 1 to partitions->Array.length - 1 {
    let p = partitions->Js.Array2.unsafe_get(idx)
    let pItem = p->getEarliestEventInRegister
    if pItem->qItemLt(item.contents) {
      item := pItem
    }
  }
  item.contents
}

/**
Instantiates a fetch state with root register
*/
let make = (
  ~staticContracts,
  ~dynamicContracts,
  ~startBlock,
  ~endBlock,
  ~maxAddrInPartition,
  ~isFetchingAtHead,
  ~batchSize=Env.maxProcessBatchSize,
): t => {
  let latestFetchedBlock = {
    blockTimestamp: 0,
    // Here's a bug that startBlock: 1 won't work
    blockNumber: Pervasives.max(startBlock - 1, 0),
  }

  let numAddresses = staticContracts->Array.length + dynamicContracts->Array.length
  let partitions = []

  let addPartition = (~staticContracts=?, ~dynamicContracts=?, ~latestFetchedBlock) => {
    partitions->Array.push(
      makePartition(
        ~partitionIndex=partitions->Array.length,
        ~staticContracts?,
        ~dynamicContracts?,
        ~latestFetchedBlock,
      ),
    )
  }

  if numAddresses <= maxAddrInPartition {
    addPartition(~staticContracts, ~dynamicContracts, ~latestFetchedBlock)
  } else {
    let staticContractsClone = staticContracts->Array.copy

    //Chunk static contract addresses (clone) until it is under the size of 1 partition
    while staticContractsClone->Array.length > maxAddrInPartition {
      let staticContractsChunk =
        staticContractsClone->Js.Array2.removeCountInPlace(~pos=0, ~count=maxAddrInPartition)

      addPartition(~staticContracts=staticContractsChunk, ~latestFetchedBlock)
    }

    let dynamicContractsClone = dynamicContracts->Array.copy

    //Add the rest of the static addresses filling the remainder of the partition with dynamic contract
    //registrations
    addPartition(
      ~staticContracts=staticContractsClone,
      ~dynamicContracts=dynamicContractsClone->Js.Array2.removeCountInPlace(
        ~pos=0,
        ~count=maxAddrInPartition - staticContractsClone->Array.length,
      ),
      ~latestFetchedBlock,
    )

    //Make partitions with all remaining dynamic contract registrations
    while dynamicContractsClone->Array.length > 0 {
      let dynamicContractsChunk =
        dynamicContractsClone->Js.Array2.removeCountInPlace(~pos=0, ~count=maxAddrInPartition)

      addPartition(~dynamicContracts=dynamicContractsChunk, ~latestFetchedBlock)
    }
  }

  if Env.Benchmark.shouldSaveData {
    Benchmark.addSummaryData(
      ~group="Other",
      ~label="Num partitions",
      ~value=partitions->Array.length->Int.toFloat,
    )
  }

  {
    partitions,
    nextPartitionIndex: partitions->Array.length,
    isFetchingAtHead,
    maxAddrInPartition,
    endBlock,
    batchSize,
    latestFullyFetchedBlock: latestFetchedBlock,
    queueSize: 0,
    firstEventBlockNumber: None,
  }
}

let queueSize = ({queueSize}: t) => queueSize

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

/**
Recurses through registers and determines whether a contract has already been registered with
the given name and address
*/
let checkContainsRegisteredContractAddress = (
  self: t,
  ~contractName,
  ~contractAddress,
  ~chainId,
) => {
  self.partitions->Array.some(r => {
    switch r.contractAddressMapping->ContractAddressingMap.getContractNameFromAddress(
      ~contractAddress,
    ) {
    | Some(existingContractName) =>
      if existingContractName != contractName {
        warnIfAttemptedAddressRegisterOnDifferentContracts(
          ~contractAddress,
          ~contractName,
          ~existingContractName,
          ~chainId,
        )
      }
      true
    | None => false
    }
  })
}

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
Rolls back registers to the given valid block
*/
let rollbackPartition = (
  partition: register,
  ~lastScannedBlock,
  ~firstChangeEvent: blockNumberAndLogIndex,
) => {
  //get all dynamic contract addresses past valid blockNumber to remove along with
  //updated dynamicContracts map
  let addressesToRemove = []
  let dynamicContracts = partition.dynamicContracts->Array.keep(dc => {
    if (
      (dc.registeringEventBlockNumber, dc.registeringEventLogIndex) >=
      (firstChangeEvent.blockNumber, firstChangeEvent.logIndex)
    ) {
      //If the registration block is later than the first change event,
      //Do not keep it and add to the removed addresses
      addressesToRemove->Array.push(dc.contractAddress)
      false
    } else {
      true
    }
  })

  if (
    addressesToRemove->Array.length ===
      partition.contractAddressMapping->ContractAddressingMap.addressCount &&
      !shouldApplyWildcards(~partitionId=partition.id)
  ) {
    None
  } else {
    //remove them from the contract address mapping and dynamic contract addresses mapping
    let contractAddressMapping =
      partition.contractAddressMapping->ContractAddressingMap.removeAddresses(~addressesToRemove)

    let shouldRollbackFetched =
      partition.latestFetchedBlock.blockNumber >= firstChangeEvent.blockNumber

    let fetchedEventQueue = if shouldRollbackFetched {
      partition.fetchedEventQueue->pruneQueueFromFirstChangeEvent(~firstChangeEvent)
    } else {
      partition.fetchedEventQueue
    }

    Some({
      id: partition.id,
      dynamicContracts,
      contractAddressMapping,
      status: {
        fetchingStateId: None,
      },
      fetchedEventQueue,
      latestFetchedBlock: shouldRollbackFetched ? lastScannedBlock : partition.latestFetchedBlock,
    })
  }
}

let rollback = (fetchState: t, ~lastScannedBlock, ~firstChangeEvent) => {
  let partitions =
    fetchState.partitions->Array.keepMap(r =>
      r->rollbackPartition(~lastScannedBlock, ~firstChangeEvent)
    )

  fetchState->updateInternal(~partitions)
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
