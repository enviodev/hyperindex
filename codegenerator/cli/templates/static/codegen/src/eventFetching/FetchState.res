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

type status = {mutable isFetching: bool}

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
  dynamicContracts: DynamicContractsMap.t,
}

type t = {
  partitions: dict<register>,
  // Used for the incremental partition id. Can't use the partitions length,
  // since partitions might be deleted on merge or cleaned up
  nextPartitionIndex: int,
  isFetchingAtHead: bool,
  maxAddrInPartition: int,
  batchSize: int,
  // Fields computed by updateInternal
  latestFullyFetchedBlock: blockNumberAndTimestamp,
  queueSize: int,
  firstEventBlockNumber: option<int>,
}

let shallowCopyRegister = (register: register) => {
  ...register,
  fetchedEventQueue: register.fetchedEventQueue->Array.copy,
}

let copy = (fetchState: t) => {
  let partitions = fetchState.partitions->Utils.Dict.map(shallowCopyRegister)
  {
    maxAddrInPartition: fetchState.maxAddrInPartition,
    partitions,
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

  {
    id: target.id,
    status: {
      isFetching: false,
    },
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
let addItemsToPartition = (
  register: register,
  ~latestFetchedBlock,
  //Events ordered latest to earliest
  ~reversedNewItems: array<Internal.eventItem>,
) => {
  {
    ...register,
    status: {
      isFetching: false,
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
  ~partitions=?,
  ~nextPartitionIndex=fetchState.nextPartitionIndex,
  ~isFetchingAtHead=fetchState.isFetchingAtHead,
  ~batchSize=fetchState.batchSize,
  ~firstEventBlockNumber=fetchState.firstEventBlockNumber,
): t => {
  let originalPartitions = fetchState.partitions->Js.Dict.values
  let partitions = partitions->Option.getWithDefault(originalPartitions)
  let firstPartition = partitions->Js.Array2.unsafe_get(0)

  let partitionsMap = Js.Dict.empty()
  let queueSize = ref(0)
  let latestFullyFetchedBlock = ref(firstPartition.latestFetchedBlock)

  for idx in 0 to partitions->Array.length - 1 {
    let p = partitions->Js.Array2.unsafe_get(idx)
    partitionsMap->Js.Dict.set(p.id, p)

    let partitionQueueSize = p.fetchedEventQueue->Array.length

    queueSize := queueSize.contents + partitionQueueSize

    if latestFullyFetchedBlock.contents.blockNumber > p.latestFetchedBlock.blockNumber {
      latestFullyFetchedBlock := p.latestFetchedBlock
    }
  }

  if Env.Benchmark.shouldSaveData && originalPartitions->Array.length !== partitions->Array.length {
    Benchmark.addSummaryData(
      ~group="Other",
      ~label="Num partitions",
      ~value=partitions->Array.length->Int.toFloat,
    )
  }

  {
    maxAddrInPartition: fetchState.maxAddrInPartition,
    nextPartitionIndex,
    firstEventBlockNumber,
    batchSize,
    partitions: partitionsMap,
    isFetchingAtHead,
    latestFullyFetchedBlock: latestFullyFetchedBlock.contents,
    queueSize: queueSize.contents,
  }
}

let makePartition = (
  ~partitionIndex,
  ~latestFetchedBlock,
  ~dynamicContractRegistrations: array<TablesStatic.DynamicContractRegistry.t>=[],
  ~staticContracts=[],
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
    status: {
      isFetching: false,
    },
    latestFetchedBlock,
    contractAddressMapping,
    dynamicContracts,
    fetchedEventQueue: [],
  }
}

let registerDynamicContract = (
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
        ~dynamicContractRegistrations=dcs,
        ~latestFetchedBlock={
          blockNumber: Pervasives.max(startBlockKey->Int.fromString->Option.getExn - 1, 0),
          blockTimestamp: 0,
        },
      )
    })

  fetchState->updateInternal(
    ~partitions=fetchState.partitions->Js.Dict.values->Js.Array2.concat(newPartitions),
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
    switch partitions->Utils.Dict.dangerouslyGetNonOption(partitionId) {
    | Some(p) =>
      let updatedPartition =
        p->addItemsToPartition(~latestFetchedBlock, ~reversedNewItems=newItems->Array.reverse)

      switch query {
      | PartitionQuery(_) =>
        Ok(partitions->Utils.Dict.updateImmutable(partitionId, updatedPartition))
      | MergeQuery({intoPartitionId}) =>
        switch partitions->Utils.Dict.dangerouslyGetNonOption(intoPartitionId) {
        | Some(target)
          if target.latestFetchedBlock.blockNumber === latestFetchedBlock.blockNumber => {
            let merged = updatedPartition->mergeIntoPartition(~target)

            let updatedPartitions = partitions->Utils.Dict.updateImmutable(target.id, merged)
            updatedPartitions->Utils.Dict.deleteInPlace(merged.id)

            Ok(updatedPartitions)
          }
        | _ => Ok(partitions->Utils.Dict.updateImmutable(partitionId, updatedPartition))
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
      ~partitions=partitions->Js.Dict.values,
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

let startFetchingQueries = ({partitions}: t, ~queries: array<query>) => {
  queries->Array.forEach(q => {
    switch partitions->Utils.Dict.dangerouslyGetNonOption(q->queryPartitionId) {
    | Some(p) => p.status.isFetching = true
    // Shouldn't be mutated to false anymore
    // The status will be immutably set to the initial one when we handle response
    | None => Js.Exn.raiseError("Unexpected case: Couldn't find partition for the fetching query")
    }
  })
}

let getNextQuery = (
  {partitions, maxAddrInPartition}: t,
  ~endBlock,
  ~concurrencyLimit,
  ~maxQueueSize,
  ~currentBlockHeight,
) => {
  if concurrencyLimit === 0 {
    ReachedMaxConcurrency
  } else {
    let fullPartitions = []
    let mergingPartitions = []
    let hasFetchingPartition = ref(false)
    let areMergingPartitionsFetching = ref(false)
    let mostBehindMergingPartition = ref(None)
    let mergingPartitionTarget = ref(None)

    let partitionIds = partitions->Js.Dict.keys
    for idx in 0 to partitionIds->Js.Array2.length - 1 {
      let id = partitionIds->Js.Array2.unsafe_get(idx)
      let p = partitions->Js.Dict.unsafeGet(id)
      if p.contractAddressMapping->ContractAddressingMap.addressCount >= maxAddrInPartition {
        fullPartitions->Array.push(p)
        if p.status.isFetching {
          hasFetchingPartition := true
        }
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

        if p.status.isFetching {
          hasFetchingPartition := true
          areMergingPartitionsFetching := true
        }
      }
    }

    let maxPartitionQueueSize = maxQueueSize / (fullPartitions->Array.length + 1)
    let hasQueryWaitingForNewBlock = ref(false)
    let queries = []

    let registerPartitionQuery = (p, ~checkQueueSize, ~mergeTarget=?) => {
      if (
        p.status.isFetching->not && (
            checkQueueSize ? p.fetchedEventQueue->Array.length <= maxPartitionQueueSize : true
          )
      ) {
        switch p->makePartitionQuery(~endBlock) {
        | Some(q) =>
          if q.fromBlock > currentBlockHeight {
            hasQueryWaitingForNewBlock := true
          } else {
            queries->Array.push(
              switch mergeTarget {
              | Some(mergeTarget) =>
                MergeQuery({
                  partitionId: q.partitionId,
                  contractAddressMapping: q.contractAddressMapping,
                  fromBlock: q.fromBlock,
                  toBlock: mergeTarget.latestFetchedBlock.blockNumber - 1,
                  intoPartitionId: mergeTarget.id,
                })
              | None => PartitionQuery(q)
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
  let partitions = partitions->Js.Dict.values
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
  let partitions = Js.Dict.empty()
  let nextPartitionIndex = ref(0)

  let addPartition = (~staticContracts=?, ~dynamicContractRegistrations=?, ~latestFetchedBlock) => {
    let p = makePartition(
      ~partitionIndex=nextPartitionIndex.contents,
      ~staticContracts?,
      ~dynamicContractRegistrations?,
      ~latestFetchedBlock,
    )
    nextPartitionIndex := nextPartitionIndex.contents + 1
    partitions->Js.Dict.set(p.id, p)
  }

  if numAddresses <= maxAddrInPartition {
    addPartition(~staticContracts, ~dynamicContractRegistrations, ~latestFetchedBlock)
  } else {
    let staticContractsClone = staticContracts->Array.copy

    //Chunk static contract addresses (clone) until it is under the size of 1 partition
    while staticContractsClone->Array.length > maxAddrInPartition {
      let staticContractsChunk =
        staticContractsClone->Js.Array2.removeCountInPlace(~pos=0, ~count=maxAddrInPartition)

      addPartition(~staticContracts=staticContractsChunk, ~latestFetchedBlock)
    }

    let dynamicContractRegistrationsClone = dynamicContractRegistrations->Array.copy

    //Add the rest of the static addresses filling the remainder of the partition with dynamic contract
    //registrations
    addPartition(
      ~staticContracts=staticContractsClone,
      ~dynamicContractRegistrations=dynamicContractRegistrationsClone->Js.Array2.removeCountInPlace(
        ~pos=0,
        ~count=maxAddrInPartition - staticContractsClone->Array.length,
      ),
      ~latestFetchedBlock,
    )

    //Make partitions with all remaining dynamic contract registrations
    while dynamicContractRegistrationsClone->Array.length > 0 {
      let dynamicContractRegistrationsChunk =
        dynamicContractRegistrationsClone->Js.Array2.removeCountInPlace(
          ~pos=0,
          ~count=maxAddrInPartition,
        )

      addPartition(
        ~dynamicContractRegistrations=dynamicContractRegistrationsChunk,
        ~latestFetchedBlock,
      )
    }
  }

  if Env.Benchmark.shouldSaveData {
    Benchmark.addSummaryData(
      ~group="Other",
      ~label="Num partitions",
      ~value=nextPartitionIndex.contents->Int.toFloat,
    )
  }

  {
    partitions,
    nextPartitionIndex: nextPartitionIndex.contents,
    isFetchingAtHead,
    maxAddrInPartition,
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
  self.partitions
  ->Js.Dict.values
  ->Array.some(r => {
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
        status: {
          isFetching: false,
        },
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
  let partitions =
    fetchState.partitions
    ->Js.Dict.values
    ->Array.keepMap(r => r->rollbackRegister(~lastScannedBlock, ~firstChangeEvent))

  fetchState->updateInternal(~partitions)
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
