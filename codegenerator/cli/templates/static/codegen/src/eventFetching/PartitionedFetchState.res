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

type partitionIndexSet = Belt.Set.Int.t

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

exception UnexpectedPartitionDoesNotExist(partitionIndex)

/**
Updates partition at given id with given values and checks to see if it can be merged into its next register.
Returns Error if the partition/node with given id cannot be found (unexpected)
*/
let update = (self: t, ~id: id, ~latestFetchedBlock, ~newItems, ~currentBlockHeight) => {
  switch self.partitions->List.splitAt(id.partitionId) {
  | Some((left, list{head, ...tail})) =>
    head
    ->FetchState.update(~id=id.fetchStateId, ~latestFetchedBlock, ~newItems, ~currentBlockHeight)
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

/**
Retrieves an array of partitions that are most behind with a max number based on
the max number of queries with the context of the partitions currently fetching.

The array could be shorter than the max number of queries if the partitions are
at the max queue size.
*/
let getMostBehindPartitions = (
  {partitions}: t,
  ~maxNumQueries,
  ~maxPerChainQueueSize,
  ~partitionsCurrentlyFetching,
) => {
  let maxNumQueries = Pervasives.max(
    maxNumQueries - partitionsCurrentlyFetching->Belt.Set.Int.size,
    0,
  )
  let maxPartitionQueueSize = maxPerChainQueueSize / partitions->List.length

  partitions
  ->List.mapWithIndex((index, partition) => {fetchState: partition, partitionId: index}) // create the indecies that are returned by the function as an array - done here for sake of testing
  ->List.keep(({fetchState: partition, partitionId: index}) =>
    !(partitionsCurrentlyFetching->Set.Int.has(index)) &&
    partition->FetchState.isReadyForNextQuery(~maxQueueSize=maxPartitionQueueSize)
  )
  ->List.sort((a, b) =>
    a.fetchState.latestFetchedBlock.blockNumber - b.fetchState.latestFetchedBlock.blockNumber
  )
  ->List.toArray
  ->Js.Array.slice(~start=0, ~end_=maxNumQueries)
}

let updatePartition = (self: t, ~fetchState: FetchState.t, ~partitionId: partitionIndex) => {
  switch self.partitions->List.splitAt(partitionId) {
  | Some((left, list{_head, ...tail})) =>
    let partitions = list{...left, fetchState, ...tail}
    Ok({...self, partitions})
  | _ => Error(UnexpectedPartitionDoesNotExist(partitionId))
  }
}

type nextQueries = WaitForNewBlock | NextQuery(array<FetchState.nextQuery>)
/**
Gets the next query from the fetchState with the lowest latestFetchedBlock number.
*/
let getNextQueriesOrThrow = (
  self: t,
  ~currentBlockHeight,
  ~maxPerChainQueueSize,
  ~partitionsCurrentlyFetching,
) => {
  let optUpdatedPartition = ref(None)
  let includesWaitForNewBlock = ref(false)
  let nextQueries = []
  self
  ->getMostBehindPartitions(
    ~maxNumQueries=Env.maxPartitionConcurrency,
    ~maxPerChainQueueSize,
    ~partitionsCurrentlyFetching,
  )
  ->Array.forEach(({fetchState, partitionId}) => {
    switch fetchState->FetchState.getNextQuery(~currentBlockHeight, ~partitionId) {
    | Ok((nextQuery, optUpdatesFetchState)) =>
      switch nextQuery {
      | NextQuery(q) => nextQueries->Js.Array2.push(q)->ignore
      | WaitForNewBlock => includesWaitForNewBlock := true
      | Done => ()
      }
      switch optUpdatesFetchState {
      | Some(fetchState) =>
        optUpdatedPartition :=
          optUpdatedPartition.contents
          ->Option.getWithDefault(self)
          ->updatePartition(~fetchState, ~partitionId)
          ->Utils.unwrapResultExn
          ->Some
      | None => ()
      }
    | Error(e) =>
      e->ErrorHandling.mkLogAndRaise(~msg="Unexpected error getting next query in partition")
    }
  })

  let nextQueries = switch nextQueries {
  | [] if includesWaitForNewBlock.contents => WaitForNewBlock
  | queries => NextQuery(queries)
  }

  (nextQueries, optUpdatedPartition.contents)
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
