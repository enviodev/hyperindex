open Belt
type t = {
  maxAddrInPartition: int,
  partitions: list<FetchState.t>,
  endBlock: option<int>,
  startBlock: int,
  logger: Pino.t,
}

type partitionIndex = int
type id = {
  partitionId: partitionIndex,
  fetchStateId: FetchState.id,
}

let make = (
  ~maxAddrInPartition,
  ~endBlock,
  ~staticContracts,
  ~dynamicContractRegistrations,
  ~startBlock,
  ~logger,
) => {
  let numAddresses = staticContracts->Array.length + dynamicContractRegistrations->Array.length

  let partitions = if numAddresses <= maxAddrInPartition {
    list{
      FetchState.makeRoot(~endBlock)(
        ~staticContracts,
        ~dynamicContractRegistrations,
        ~startBlock,
        ~logger,
        ~isFetchingAtHead=false,
      ),
    }
  } else {
    let partitions: ref<list<FetchState.t>> = ref(list{})
    let staticContractsClone = staticContracts->Array.copy

    //Chunk static contract addresses (clone) until it is under the size of 1 partition
    while staticContractsClone->Array.length > maxAddrInPartition {
      let staticContractsChunk =
        staticContractsClone->Js.Array2.removeCountInPlace(~pos=0, ~count=maxAddrInPartition)

      partitions :=
        partitions.contents->List.add(
          FetchState.makeRoot(~endBlock)(
            ~staticContracts=staticContractsChunk,
            ~dynamicContractRegistrations=[],
            ~startBlock,
            ~logger,
            ~isFetchingAtHead=false,
          ),
        )
    }

    let dynamicContractRegistrationsClone = dynamicContractRegistrations->Array.copy

    //Add the rest of the static addresses filling the remainder of the partition with dynamic contract
    //registrations
    partitions :=
      partitions.contents->List.add(
        FetchState.makeRoot(~endBlock)(
          ~staticContracts=staticContractsClone,
          ~dynamicContractRegistrations=dynamicContractRegistrationsClone->Js.Array2.removeCountInPlace(
            ~pos=0,
            ~count=maxAddrInPartition - staticContractsClone->Array.length,
          ),
          ~startBlock,
          ~logger,
          ~isFetchingAtHead=false,
        ),
      )

    //Make partitions with all remaining dynamic contract registrations
    while dynamicContractRegistrationsClone->Array.length > 0 {
      let dynamicContractRegistrationsChunk =
        dynamicContractRegistrationsClone->Js.Array2.removeCountInPlace(
          ~pos=0,
          ~count=maxAddrInPartition,
        )

      partitions :=
        partitions.contents->List.add(
          FetchState.makeRoot(~endBlock)(
            ~staticContracts=[],
            ~dynamicContractRegistrations=dynamicContractRegistrationsChunk,
            ~startBlock,
            ~logger,
            ~isFetchingAtHead=false,
          ),
        )
    }
    partitions.contents
  }

  if Env.saveBenchmarkData {
    Benchmark.addSummaryData(
      ~group="Other",
      ~label="Num partitions",
      ~value=partitions->List.size->Int.toFloat,
    )
  }

  {maxAddrInPartition, partitions, endBlock, startBlock, logger}
}

let registerDynamicContracts = (
  {partitions, maxAddrInPartition, endBlock, startBlock, logger}: t,
  ~registeringEventBlockNumber,
  ~registeringEventLogIndex,
  ~dynamicContractRegistrations,
  ~isFetchingAtHead,
) => {
  let partitions = switch partitions {
  | list{head, ...tail} if head->FetchState.getNumContracts < maxAddrInPartition =>
    let updated =
      head->FetchState.registerDynamicContract(
        ~registeringEventBlockNumber,
        ~registeringEventLogIndex,
        ~dynamicContractRegistrations,
      )
    list{updated, ...tail}
  | partitions =>
    let newPartition = FetchState.makeRoot(~endBlock)(
      ~startBlock,
      ~logger,
      ~staticContracts=[],
      ~dynamicContractRegistrations,
      ~isFetchingAtHead,
    )
    partitions->List.add(newPartition)
  }

  if Env.saveBenchmarkData {
    Benchmark.addSummaryData(
      ~group="Other",
      ~label="Num partitions",
      ~value=partitions->List.size->Int.toFloat,
    )
  }
  {partitions, maxAddrInPartition, endBlock, startBlock, logger}
}

let eventFilterIsValid = ({partitions}: t, ~eventFilter: FetchState.eventFilter, ~chain) =>
  partitions->List.reduce(false, (accum, partition) => {
    accum || eventFilter.isValid(~fetchState=partition, ~chain)
  })

exception UnexpectedPartitionDoesNotExist(partitionIndex)

/**
Updates partition at given id with given values and checks to see if it can be merged into its next register.
Returns Error if the partition/node with given id cannot be found (unexpected)
*/
let update = (self: t, ~id: id, ~latestFetchedBlock, ~fetchedEvents, ~currentBlockHeight) => {
  switch self.partitions->List.splitAt(id.partitionId) {
  | Some((left, list{head, ...tail})) =>
    head
    ->FetchState.update(
      ~id=id.fetchStateId,
      ~latestFetchedBlock,
      ~fetchedEvents,
      ~currentBlockHeight,
    )
    ->Result.map(updatedPartition => {
      ...self,
      partitions: list{...left, updatedPartition, ...tail},
    })
  | _ => Error(UnexpectedPartitionDoesNotExist(id.partitionId))
  }
}

type singlePartition = {
  fetchState: FetchState.t,
  partitionId: partitionIndex,
}

let getMostBehindPartition = ({partitions}: t) =>
  partitions
  ->List.reduceWithIndex(None, (accum, partition, partitionIndex) => {
    switch accum {
    | Some({fetchState: accumPartition}: singlePartition)
      if accumPartition.FetchState.latestFetchedBlock.blockNumber <
      partition.latestFetchedBlock.blockNumber => accum
    | _ => Some({fetchState: partition, partitionId: partitionIndex})
    }
  })
  ->Option.getUnsafe

let updatePartition = (self: t, ~fetchState: FetchState.t, ~partitionId: partitionIndex) => {
  switch self.partitions->List.splitAt(partitionId) {
  | Some((left, list{_head, ...tail})) =>
    let partitions = list{...left, fetchState, ...tail}
    Ok({...self, partitions})
  | _ => Error(UnexpectedPartitionDoesNotExist(partitionId))
  }
}

/**
Gets the next query from the fetchState with the lowest latestFetchedBlock number.
*/
let getNextQuery = (self: t, ~eventFilters=?, ~currentBlockHeight) => {
  let {fetchState, partitionId} = self->getMostBehindPartition

  fetchState
  ->FetchState.getNextQuery(~eventFilters?, ~currentBlockHeight, ~partitionId)
  ->Result.map(((nextQuery, optUpdatesFetchState)) => (
    nextQuery,
    optUpdatesFetchState->Option.map(fetchState =>
      self->updatePartition(~fetchState, ~partitionId)->Utils.unwrapResultExn
    ),
  ))
}

/**
Rolls back all partitions to the given valid block
*/
let rollback = (self: t, ~lastKnownValidBlock) => {
  let partitions =
    self.partitions->List.map(partition => partition->FetchState.rollback(~lastKnownValidBlock))

  {...self, partitions}
}

let getEarliestEvent = (self: t) =>
  self.partitions->List.reduce(None, (accum, fetchState) => {
    // If the fetch state has reached the end block we don't need to consider it
    if fetchState->FetchState.isActivelyIndexing {
      let nextItem = fetchState->FetchState.getEarliestEvent
      switch accum {
      | Some(accumItem) if FetchState.qItemLt(accumItem, nextItem) => accum
      | _ => Some(nextItem)
      }
    } else {
      accum
    }
  })

let queueSize = ({partitions}: t) =>
  partitions->List.reduce(0, (accum, partition) => accum + partition->FetchState.queueSize)

let getLatestFullyFetchedBlock = ({partitions}: t) =>
  partitions
  ->List.reduce(None, (accum, partition) => {
    let partitionBlock = partition->FetchState.getLatestFullyFetchedBlock
    switch accum {
    | Some({FetchState.blockNumber: blockNumber})
      if partitionBlock.blockNumber >= blockNumber => accum
    | _ => Some(partitionBlock)
    }
  })
  ->Option.getUnsafe

let isReadyForNextQuery = (self: t, ~maxQueueSize) => {
  let {fetchState} = self->getMostBehindPartition
  fetchState->FetchState.isReadyForNextQuery(~maxQueueSize)
}

let checkContainsRegisteredContractAddress = ({partitions}: t, ~contractAddress, ~contractName) => {
  partitions->List.reduce(false, (accum, partition) => {
    accum ||
    partition->FetchState.checkContainsRegisteredContractAddress(~contractAddress, ~contractName)
  })
}

let isFetchingAtHead = ({partitions}: t) => {
  partitions->List.reduce(true, (accum, partition) => {
    accum && partition.isFetchingAtHead
  })
}

let getFirstEventBlockNumber = ({partitions}: t) => {
  partitions->List.reduce(None, (accum, partition) => {
    Utils.Math.minOptInt(accum, partition.firstEventBlockNumber)
  })
}

let copy = (self: t) => {...self, partitions: self.partitions->List.map(FetchState.copy)}
