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

module DynamicContractsMap = {
  //mapping of address to dynamicContractId
  module IdCmp = Belt.Id.MakeComparableU({
    type t = dynamicContractId
    let toCmp = (dynamicContractId: dynamicContractId) => (
      dynamicContractId.blockNumber,
      dynamicContractId.logIndex,
    )
    let cmp = (a, b) => Pervasives.compare(a->toCmp, b->toCmp)
  })

  type t = Belt.Map.t<dynamicContractId, Belt.Set.String.t, IdCmp.identity>

  let empty: t = Belt.Map.make(~id=module(IdCmp))

  let add = (self, id, addressesArr: array<Address.t>) => {
    self->Belt.Map.set(id, addressesArr->Utils.magic->Belt.Set.String.fromArray)
  }

  let addAddress = (self: t, id, address: Address.t) => {
    let addressStr = address->Address.toString
    self->Belt.Map.update(id, optCurrentVal => {
      switch optCurrentVal {
      | None => Belt.Set.String.fromArray([addressStr])
      | Some(currentVal) => currentVal->Belt.Set.String.add(addressStr)
      }->Some
    })
  }

  let merge = (a: t, b: t) =>
    Array.concat(a->Map.toArray, b->Map.toArray)->Array.reduce(empty, (
      accum,
      (nextKey, nextVal),
    ) => {
      let optCurrentVal = accum->Map.get(nextKey)
      let nextValMerged =
        optCurrentVal->Option.mapWithDefault(nextVal, currentVal =>
          Set.String.union(currentVal, nextVal)
        )
      accum->Map.set(nextKey, nextValMerged)
    })

  let removeContractAddressesFromFirstChangeEvent = (
    self: t,
    ~firstChangeEvent: blockNumberAndLogIndex,
  ) => {
    self
    ->Map.toArray
    ->Array.reduce((empty, []), ((currentMap, currentRemovedAddresses), (nextKey, nextVal)) => {
      if (
        (nextKey.blockNumber, nextKey.logIndex) >=
        (firstChangeEvent.blockNumber, firstChangeEvent.logIndex)
      ) {
        //If the registration block is later than the first change event,
        //Do not add it to the currentMap, but add the removed addresses
        let updatedRemovedAddresses =
          currentRemovedAddresses->Array.concat(
            nextVal->Set.String.toArray->ContractAddressingMap.stringsToAddresses,
          )
        (currentMap, updatedRemovedAddresses)
      } else {
        //If it is earlier than the first change event, updated the
        //current map and keep the currentRemovedAddresses
        let updatedMap = currentMap->Map.set(nextKey, nextVal)
        (updatedMap, currentRemovedAddresses)
      }
    })
  }
}

/**
A state that holds a queue of events and data regarding what to fetch next.
There's always a root register and potentially additional registers for dynamic contracts.
When the registers are caught up to each other they are getting merged
*/
type register = {
  id: string,
  latestFetchedBlock: blockNumberAndTimestamp,
  contractAddressMapping: ContractAddressingMap.mapping,
  // Partition-specific endBlock (fetch up until including)
  endBlock: option<int>,
  //Events ordered from latest to earliest
  fetchedEventQueue: array<Internal.eventItem>,
  //Used to prune dynamic contract registrations in the event
  //of a rollback.
  dynamicContracts: DynamicContractsMap.t,
  // Need to prevent duplicated query calls. Even though we have the isFetching flag,
  // there might be cases when mutable and immutable states are not synced, so this is needed.
  // Increment on immutable state update.
  idempotencyKey: int,
}

type dynamicContractRegistration = {
  registeringEventBlockNumber: int,
  registeringEventLogIndex: int,
  registeringEventChain: ChainMap.Chain.t,
  dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>,
}

// There are currently three ways of choosing partitions to query:
// 1. Until there's at least one partition with queueSize of a full batch,
//    we query all partitions in parallel, prioritizing the most behind ones.
// 2.1 Once there's at least one partition having a queue of a full batch,
//    we can do a wild assumption of a block range for the batch,
//    with this we can start quering partitions specifically to cover the range.
// 2.2 At this point there are some partitions which are not fetching,
//    we can use this to sefely merge partitions.
// 3. When we are confident there's a full batch of items for processing,
//    we still want to continue query partitions until we reach the max queue size.
//    To do it safely and not exceed it too much, the query will be done for one partition at a time
//    also allowing us to merge everything that can be merged.
//    It's not represented in the state, but chosen when all partitions
//    exceeded the estimatedEndBlock of the next batch.
type fetchMode =
  | InitialFill
  | CatchUpNextBatch({estimatedEndBlock: int})

type t = {
  registers: array<register>,
  // Used for the incremental partition id. Can't use the partitions length,
  // since partitions might be deleted on merge or cleaned up
  nextPartitionIndex: int,
  isFetchingAtHead: bool,
  maxAddrInPartition: int,
  batchSize: int,
  // Fields computed by updateInternal
  latestFullyFetchedBlock: blockNumberAndTimestamp,
  queueSize: int,
  fetchMode: fetchMode,
  firstEventBlockNumber: option<int>,
}

let shallowCopyRegister = (register: register) => {
  ...register,
  fetchedEventQueue: register.fetchedEventQueue->Array.copy,
}

let copy = (self: t) => {
  let registers = self.registers->Array.map(shallowCopyRegister)
  {
    maxAddrInPartition: self.maxAddrInPartition,
    registers,
    nextPartitionIndex: self.nextPartitionIndex,
    isFetchingAtHead: self.isFetchingAtHead,
    latestFullyFetchedBlock: self.latestFullyFetchedBlock,
    batchSize: self.batchSize,
    queueSize: self.queueSize,
    fetchMode: self.fetchMode,
    firstEventBlockNumber: self.firstEventBlockNumber,
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

let mergeIntoPartition = (register: register, ~target: register) => {
  let fetchedEventQueue = mergeSortedEventList(register.fetchedEventQueue, target.fetchedEventQueue)
  let contractAddressMapping = ContractAddressingMap.combine(
    register.contractAddressMapping,
    target.contractAddressMapping,
  )

  let dynamicContracts = DynamicContractsMap.merge(
    register.dynamicContracts,
    target.dynamicContracts,
  )

  if register.latestFetchedBlock.blockNumber !== target.latestFetchedBlock.blockNumber {
    Js.Exn.raiseError("Invalid state: Merged registers should belong to the same block")
  }
  if register.endBlock !== None || target.endBlock !== None {
    Js.Exn.raiseError("Invalid state: Partitions with endBlock shouldn't merge")
  }

  {
    id: target.id,
    idempotencyKey: register.idempotencyKey + 1,
    endBlock: None,
    fetchedEventQueue,
    contractAddressMapping,
    dynamicContracts,
    latestFetchedBlock: target.latestFetchedBlock,
  }
}

/**
Updates a given register with new latest block values and new fetched
events.
*/
let updateRegister = (
  register: register,
  ~latestFetchedBlock,
  //Events ordered latest to earliest
  ~reversedNewItems: array<Internal.eventItem>,
) => {
  {
    ...register,
    idempotencyKey: register.idempotencyKey + 1,
    latestFetchedBlock,
    fetchedEventQueue: Array.concat(reversedNewItems, register.fetchedEventQueue),
  }
}

/*
 Update fetchState, merge registers and recompute derived values
 */
let updateInternal = (
  fetchState: t,
  ~registers=fetchState.registers,
  ~isFetchingAtHead=fetchState.isFetchingAtHead,
  ~batchSize=fetchState.batchSize,
  ~firstEventBlockNumber=fetchState.firstEventBlockNumber,
): t => {
  let firstRegister = registers->Js.Array2.unsafe_get(0)

  let queueSize = ref(0)
  let latestFullyFetchedBlock = ref(firstRegister.latestFetchedBlock)
  let fetchMode = ref(InitialFill)
  for idx in 0 to registers->Js.Array2.length - 1 {
    let register = registers->Js.Array2.unsafe_get(idx)
    let registerQueueSize = register.fetchedEventQueue->Js.Array2.length

    queueSize := queueSize.contents + registerQueueSize

    if registerQueueSize >= batchSize {
      let itemAtEstimatedBatchEnd =
        register.fetchedEventQueue->Js.Array2.unsafe_get(registerQueueSize - batchSize)

      switch fetchMode.contents {
      | CatchUpNextBatch({estimatedEndBlock})
        if estimatedEndBlock <= itemAtEstimatedBatchEnd.blockNumber => ()
      | InitialFill
      | CatchUpNextBatch(_) =>
        fetchMode := CatchUpNextBatch({estimatedEndBlock: itemAtEstimatedBatchEnd.blockNumber})
      }
    }

    if latestFullyFetchedBlock.contents.blockNumber > register.latestFetchedBlock.blockNumber {
      latestFullyFetchedBlock := register.latestFetchedBlock
    }
  }

  {
    maxAddrInPartition: fetchState.maxAddrInPartition,
    nextPartitionIndex: fetchState.nextPartitionIndex,
    firstEventBlockNumber,
    batchSize,
    registers,
    isFetchingAtHead,
    latestFullyFetchedBlock: latestFullyFetchedBlock.contents,
    queueSize: queueSize.contents,
    fetchMode: fetchMode.contents,
  }
}

let makePartition = (
  ~partitionIndex,
  ~dynamicContractRegistrations: array<TablesStatic.DynamicContractRegistry.t>,
  ~latestFetchedBlock,
  ~staticContracts=[],
  ~endBlock=?,
) => {
  let contractAddressMapping = ContractAddressingMap.make()

  staticContracts->Belt.Array.forEach(((contractName, address)) => {
    contractAddressMapping->ContractAddressingMap.addAddress(~name=contractName, ~address)
  })

  let dynamicContracts = dynamicContractRegistrations->Array.reduce(DynamicContractsMap.empty, (
    accum,
    {contractType, contractAddress, registeringEventBlockNumber, registeringEventLogIndex},
  ) => {
    //add address to contract address mapping
    contractAddressMapping->ContractAddressingMap.addAddress(
      ~name=(contractType :> string),
      ~address=contractAddress,
    )

    let dynamicContractId: dynamicContractId = {
      blockNumber: registeringEventBlockNumber,
      logIndex: registeringEventLogIndex,
    }

    accum->DynamicContractsMap.addAddress(dynamicContractId, contractAddress)
  })

  {
    id: partitionIndex->Int.toString,
    idempotencyKey: 0,
    endBlock,
    latestFetchedBlock,
    contractAddressMapping,
    dynamicContracts,
    fetchedEventQueue: [],
  }
}

let registerDynamicContract = (
  fetchState: t,
  registration: dynamicContractRegistration,
  ~isFetchingAtHead,
) => {
  let newPartition = makePartition(
    ~partitionIndex=fetchState.nextPartitionIndex,
    ~dynamicContractRegistrations=registration.dynamicContracts,
    ~latestFetchedBlock={
      blockNumber: Pervasives.max(registration.registeringEventBlockNumber - 1, 0),
      blockTimestamp: 0,
    },
  )

  let newPartitions = fetchState.registers->Js.Array2.concat([newPartition])

  if Env.Benchmark.shouldSaveData {
    Benchmark.addSummaryData(
      ~group="Other",
      ~label="Num partitions",
      ~value=newPartitions->Array.length->Int.toFloat,
    )
  }

  {
    ...fetchState,
    nextPartitionIndex: fetchState.nextPartitionIndex + 1,
    registers: newPartitions,
    isFetchingAtHead,
  }
}

type partitionQuery = {
  idempotencyKey: int,
  partitionId: string,
  fromBlock: int,
  toBlock: option<int>,
  contractAddressMapping: ContractAddressingMap.mapping,
}

type mergeQuery = {
  idempotencyKey: int,
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

exception UnexpectedPartitionNotFound({partitionId: string})
exception UnexpectedMergeQueryResponse({message: string})

/*
Updates node at given id with given values and checks to see if it can be merged into its next register.
Returns Error if the node with given id cannot be found (unexpected)

newItems are ordered earliest to latest (as they are returned from the worker)
*/
let setQueryResponse = (
  {registers} as fetchState: t,
  ~query: query,
  ~latestFetchedBlock: blockNumberAndTimestamp,
  ~newItems,
  ~currentBlockHeight,
): result<t, exn> => {
  switch query {
  | PartitionQuery({partitionId})
  | MergeQuery({partitionId}) =>
    switch registers->Array.getIndexBy(r => r.id === partitionId) {
    | Some(registerIdx) =>
      let updatedRegister =
        registers
        ->Array.getUnsafe(registerIdx)
        ->updateRegister(~latestFetchedBlock, ~reversedNewItems=newItems->Array.reverse)

      switch query {
      | PartitionQuery(_) =>
        Ok(registers->Utils.Array.setIndexImmutable(registerIdx, updatedRegister))
      | MergeQuery({intoPartitionId}) =>
        switch registers->Array.getIndexBy(r =>
          r.id === intoPartitionId &&
            r.latestFetchedBlock.blockNumber === latestFetchedBlock.blockNumber
        ) {
        | Some(catchedUpTargetIdx) => {
            let target = registers->Array.getUnsafe(catchedUpTargetIdx)
            let merged = updatedRegister->mergeIntoPartition(~target)
            Ok(
              registers
              ->Utils.Array.setIndexImmutable(catchedUpTargetIdx, merged)
              ->Utils.Array.deleteIndexImmutable(registerIdx),
            )
          }
        | None => Ok(registers->Utils.Array.setIndexImmutable(registerIdx, updatedRegister))
        }
      }
    | None =>
      Error(
        UnexpectedPartitionNotFound({
          partitionId: partitionId,
        }),
      )
    }
  }->Result.map(registers => {
    fetchState->updateInternal(
      ~registers,
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
  let endBlock = Utils.Math.minOptInt(register.endBlock, endBlock)
  switch endBlock {
  | Some(endBlock) if fromBlock > endBlock => None
  | _ =>
    Some({
      idempotencyKey: register.idempotencyKey,
      partitionId: register.id,
      fromBlock,
      toBlock: endBlock,
      contractAddressMapping: register.contractAddressMapping,
    })
  }
}

type partitionStatus = Available | Fetching | Locked
type nextQuery =
  | ReachedMaxConcurrency
  | ReachedMaxBufferSize
  | WaitingForNewBlock
  | NothingToQuery
  | Ready(array<query>)

let getNextQuery = (
  {registers: partitions, queueSize, fetchMode, maxAddrInPartition}: t,
  ~endBlock,
  ~concurrencyLimit,
  ~maxQueueSize,
  ~currentBlockHeight,
  ~checkPartitionStatus,
) => {
  if concurrencyLimit === 0 {
    ReachedMaxConcurrency
  } else {
    let partitionsToMergeInto = []
    let mustQueries = []
    let allPossibleQueries = []
    let hasQueryWaitingForNewBlock = ref(false)
    let hasFetchingQuery = ref(false)

    let addPartitionToMergeInto = (p: register) => {
      if (
        p.endBlock === None &&
          p.contractAddressMapping->ContractAddressingMap.addressCount < maxAddrInPartition
      ) {
        partitionsToMergeInto->Array.push(p)
      }
    }

    for idx in 0 to partitions->Js.Array2.length - 1 {
      let p = partitions->Js.Array2.unsafe_get(idx)

      let mustCatchUp = switch fetchMode {
      | InitialFill => true
      | CatchUpNextBatch({estimatedEndBlock}) =>
        p.latestFetchedBlock.blockNumber < estimatedEndBlock
      }

      // Read more about this above the fetchMode type definition
      switch p->checkPartitionStatus {
      // Partition is already fetching, so skip it
      | Fetching => hasFetchingQuery := true
      // Partition is not fetching, so another partition can merge into it
      // Allow to continue mergin into it, if it's not a part of the initial catch up
      | Locked =>
        if !mustCatchUp {
          addPartitionToMergeInto(p)
        }
      | Available =>
        switch p->makePartitionQuery(~endBlock) {
        // Reached the endBlock
        | None => addPartitionToMergeInto(p)
        | Some(query) =>
          if query.fromBlock > currentBlockHeight {
            hasQueryWaitingForNewBlock := true
          } else {
            allPossibleQueries->Array.push(query)
            if mustCatchUp {
              mustQueries->Array.push(query)
            }
          }
        }
      }
    }

    let hasSpaceInBuffer = queueSize < maxQueueSize

    // Even if there are queries waiting for the new block
    // We still want to wait for the all fetching queries, because they might update
    // the currentBlockHeight in their response
    if (
      hasQueryWaitingForNewBlock.contents &&
      allPossibleQueries->Utils.Array.isEmpty &&
      !hasFetchingQuery.contents
    ) {
      WaitingForNewBlock
    } else if allPossibleQueries->Utils.Array.isEmpty {
      NothingToQuery
    } else if mustQueries->Utils.Array.isEmpty && !hasSpaceInBuffer {
      ReachedMaxBufferSize
    } else {
      let queries = switch mustQueries {
      | [] => allPossibleQueries
      | _ => mustQueries
      }
      // If there are no queries that must catch up,
      // reduce the concurrency to 1
      let concurrencyLimit = switch mustQueries {
      | [] => 1
      | _ => concurrencyLimit
      }

      let readyPartitionQueries = if queries->Array.length > concurrencyLimit {
        queries
        ->Js.Array2.sortInPlaceWith((a, b) => a.fromBlock - b.fromBlock)
        ->Js.Array2.slice(~start=0, ~end_=concurrencyLimit)
      } else {
        queries
      }

      Ready(
        readyPartitionQueries->Array.map(partitionQuery => {
          // This is a case for dynamic contracts. We don't want to merge them,
          // Because the partition addresses are already included in another partition after endBlock
          let isQueryToPartitionEndBlock = partitionQuery.toBlock !== endBlock
          let shouldMerge =
            !(partitionsToMergeInto->Utils.Array.isEmpty) && !isQueryToPartitionEndBlock

          if shouldMerge {
            let mergeTarget = partitionsToMergeInto->Js.Array2.find(p => {
              p.latestFetchedBlock.blockNumber >= partitionQuery.fromBlock &&
                p.contractAddressMapping->ContractAddressingMap.addressCount +
                  partitionQuery.contractAddressMapping->ContractAddressingMap.addressCount <
                  maxAddrInPartition
            })
            switch mergeTarget {
            | Some(intoPartition) =>
              MergeQuery({
                idempotencyKey: partitionQuery.idempotencyKey,
                contractAddressMapping: partitionQuery.contractAddressMapping,
                fromBlock: partitionQuery.fromBlock,
                intoPartitionId: intoPartition.id,
                partitionId: partitionQuery.partitionId,
                toBlock: intoPartition.latestFetchedBlock.blockNumber,
              })
            | None => PartitionQuery(partitionQuery)
            }
          } else {
            PartitionQuery(partitionQuery)
          }
        }),
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
let getEarliestEvent = (fetchState: t) => {
  switch fetchState.registers {
  | [r] => r->getEarliestEventInRegister
  | registers => {
      let item = ref(registers->Js.Array2.unsafe_get(0)->getEarliestEventInRegister)
      for idx in 1 to registers->Js.Array2.length - 1 {
        let register = registers->Js.Array2.unsafe_get(idx)
        let registerItem = register->getEarliestEventInRegister
        if registerItem->qItemLt(item.contents) {
          item := registerItem
        }
      }
      item.contents
    }
  }
}

/**
Instantiates a fetch state with root register
*/
let make = (
  ~staticContracts,
  ~dynamicContractRegistrations,
  ~startBlock,
  ~maxAddrInPartition,
  ~isFetchingAtHead,
  ~batchSize=Env.maxProcessBatchSize,
): t => {
  let latestFetchedBlock = {
    blockTimestamp: 0,
    // Here's a bug that startBlock: 1 won't work
    blockNumber: Pervasives.max(startBlock - 1, 0),
  }

  let numAddresses = staticContracts->Array.length + dynamicContractRegistrations->Array.length
  let partitions = []
  if numAddresses <= maxAddrInPartition {
    let partition = makePartition(
      ~partitionIndex=partitions->Array.length,
      ~staticContracts,
      ~dynamicContractRegistrations,
      ~latestFetchedBlock,
    )
    partitions->Js.Array2.push(partition)->ignore
  } else {
    let staticContractsClone = staticContracts->Array.copy

    //Chunk static contract addresses (clone) until it is under the size of 1 partition
    while staticContractsClone->Array.length > maxAddrInPartition {
      let staticContractsChunk =
        staticContractsClone->Js.Array2.removeCountInPlace(~pos=0, ~count=maxAddrInPartition)

      let staticContractPartition = makePartition(
        ~partitionIndex=partitions->Array.length,
        ~staticContracts=staticContractsChunk,
        ~dynamicContractRegistrations=[],
        ~latestFetchedBlock,
      )
      partitions->Js.Array2.push(staticContractPartition)->ignore
    }

    let dynamicContractRegistrationsClone = dynamicContractRegistrations->Array.copy

    //Add the rest of the static addresses filling the remainder of the partition with dynamic contract
    //registrations
    let remainingStaticContractsWithDynamicPartition = makePartition(
      ~partitionIndex=partitions->Array.length,
      ~staticContracts=staticContractsClone,
      ~dynamicContractRegistrations=dynamicContractRegistrationsClone->Js.Array2.removeCountInPlace(
        ~pos=0,
        ~count=maxAddrInPartition - staticContractsClone->Array.length,
      ),
      ~latestFetchedBlock,
    )
    partitions->Js.Array2.push(remainingStaticContractsWithDynamicPartition)->ignore

    //Make partitions with all remaining dynamic contract registrations
    while dynamicContractRegistrationsClone->Array.length > 0 {
      let dynamicContractRegistrationsChunk =
        dynamicContractRegistrationsClone->Js.Array2.removeCountInPlace(
          ~pos=0,
          ~count=maxAddrInPartition,
        )

      let dynamicContractPartition = makePartition(
        ~partitionIndex=partitions->Array.length,
        ~staticContracts=[],
        ~dynamicContractRegistrations=dynamicContractRegistrationsChunk,
        ~latestFetchedBlock,
      )
      partitions->Js.Array2.push(dynamicContractPartition)->ignore
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
    registers: partitions,
    nextPartitionIndex: partitions->Js.Array2.length,
    isFetchingAtHead,
    maxAddrInPartition,
    batchSize,
    latestFullyFetchedBlock: latestFetchedBlock,
    queueSize: 0,
    fetchMode: InitialFill,
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
  self.registers->Array.some(r => {
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

let pruneDynamicContractAddressesFromFirstChangeEvent = (
  register: register,
  ~firstChangeEvent: blockNumberAndLogIndex,
) => {
  //get all dynamic contract addresses past valid blockNumber to remove along with
  //updated dynamicContracts map
  let (dynamicContracts, addressesToRemove) =
    register.dynamicContracts->DynamicContractsMap.removeContractAddressesFromFirstChangeEvent(
      ~firstChangeEvent,
    )

  //remove them from the contract address mapping and dynamic contract addresses mapping
  let contractAddressMapping =
    register.contractAddressMapping->ContractAddressingMap.removeAddresses(~addressesToRemove)

  {...register, contractAddressMapping, dynamicContracts}
}

/**
Rolls back registers to the given valid block
*/
let rollbackRegister = (
  register: register,
  ~lastScannedBlock,
  ~firstChangeEvent: blockNumberAndLogIndex,
) => {
  if register.latestFetchedBlock.blockNumber < firstChangeEvent.blockNumber {
    Some(register)
  } else {
    let updatedWithRemovedDynamicContracts =
      register->pruneDynamicContractAddressesFromFirstChangeEvent(~firstChangeEvent)
    if updatedWithRemovedDynamicContracts.contractAddressMapping->ContractAddressingMap.isEmpty {
      //If the contractAddressMapping is empty after pruning dynamic contracts,
      // then this is a dead register.
      None
    } else {
      //If there are still values in the contractAddressMapping,
      //we should keep the register but prune queues
      Some({
        ...updatedWithRemovedDynamicContracts,
        fetchedEventQueue: register.fetchedEventQueue->pruneQueueFromFirstChangeEvent(
          ~firstChangeEvent,
        ),
        latestFetchedBlock: lastScannedBlock,
      })
    }
  }
}

let rollback = (fetchState: t, ~lastScannedBlock, ~firstChangeEvent) => {
  // FIXME: Check that it's correct
  let registers =
    fetchState.registers->Array.keepMap(r =>
      r->rollbackRegister(~lastScannedBlock, ~firstChangeEvent)
    )

  fetchState->updateInternal(~registers)
}

/**
* Returns a boolean indicating whether the fetch state is actively indexing
* used for comparing event queues in the chain manager
*/
let isActivelyIndexing = ({latestFullyFetchedBlock} as fetchState: t, ~endBlock) => {
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

let getNumContracts = ({registers}: t) => {
  let sum = ref(0)
  for idx in 0 to registers->Js.Array2.length - 1 {
    let register = registers->Js.Array2.unsafe_get(idx)
    sum := sum.contents + register.contractAddressMapping->ContractAddressingMap.addressCount
  }
  sum.contents
}
