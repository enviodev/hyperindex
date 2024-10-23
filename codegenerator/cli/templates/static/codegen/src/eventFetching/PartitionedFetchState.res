open Belt
type partitionIndex = int
type t = {
  maxAddrInPartition: int,
  newestPartitionIndex: partitionIndex,
  partitions: dict<FetchState.t>,
  endBlock: option<int>,
  startBlock: int,
  logger: Pino.t,
}

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

  let newestPartitionIndexRef = ref(None)
  let partitions = Js.Dict.empty()
  let setNextPartition = partition => {
    let nextPartitionIndex = switch newestPartitionIndexRef.contents {
    | Some(newestPartitionIndex) => newestPartitionIndex + 1
    | None => 0
    }
    newestPartitionIndexRef := Some(nextPartitionIndex)
    partitions->Js.Dict.set(nextPartitionIndex->Int.toString, partition)
  }

  let getNewestPartitionIndex = () => {
    switch newestPartitionIndexRef.contents {
    | Some(newestPartitionIndex) => newestPartitionIndex
    | None => Js.Exn.raiseError("Unexpected no part")
    }
  }

  if numAddresses <= maxAddrInPartition {
    let partition = FetchState.makeRoot(~endBlock)(
      ~staticContracts,
      ~dynamicContractRegistrations,
      ~startBlock,
      ~logger,
      ~isFetchingAtHead=false,
    )
    setNextPartition(partition)
  } else {
    let staticContractsClone = staticContracts->Array.copy

    //Chunk static contract addresses (clone) until it is under the size of 1 partition
    while staticContractsClone->Array.length > maxAddrInPartition {
      let staticContractsChunk =
        staticContractsClone->Js.Array2.removeCountInPlace(~pos=0, ~count=maxAddrInPartition)

      let staticContractPartition = FetchState.makeRoot(~endBlock)(
        ~staticContracts=staticContractsChunk,
        ~dynamicContractRegistrations=[],
        ~startBlock,
        ~logger,
        ~isFetchingAtHead=false,
      )
      setNextPartition(staticContractPartition)
    }

    let dynamicContractRegistrationsClone = dynamicContractRegistrations->Array.copy

    //Add the rest of the static addresses filling the remainder of the partition with dynamic contract
    //registrations
    let remainingStaticContractsWithDynamicPartition = FetchState.makeRoot(~endBlock)(
      ~staticContracts=staticContractsClone,
      ~dynamicContractRegistrations=dynamicContractRegistrationsClone->Js.Array2.removeCountInPlace(
        ~pos=0,
        ~count=maxAddrInPartition - staticContractsClone->Array.length,
      ),
      ~startBlock,
      ~logger,
      ~isFetchingAtHead=false,
    )

    setNextPartition(remainingStaticContractsWithDynamicPartition)

    //Make partitions with all remaining dynamic contract registrations
    while dynamicContractRegistrationsClone->Array.length > 0 {
      let dynamicContractRegistrationsChunk =
        dynamicContractRegistrationsClone->Js.Array2.removeCountInPlace(
          ~pos=0,
          ~count=maxAddrInPartition,
        )

      let dynamicContractPartition = FetchState.makeRoot(~endBlock)(
        ~staticContracts=[],
        ~dynamicContractRegistrations=dynamicContractRegistrationsChunk,
        ~startBlock,
        ~logger,
        ~isFetchingAtHead=false,
      )
      setNextPartition(dynamicContractPartition)
    }
  }

  if Env.saveBenchmarkData {
    Benchmark.addSummaryData(
      ~group="Other",
      ~label="Num partitions",
      ~value=partitions->Js.Dict.keys->Array.length->Int.toFloat,
    )
  }

  {
    maxAddrInPartition,
    newestPartitionIndex: getNewestPartitionIndex(),
    partitions,
    endBlock,
    startBlock,
    logger,
  }
}

let registerDynamicContracts = (
  {partitions, newestPartitionIndex, maxAddrInPartition, endBlock, startBlock, logger}: t,
  dynamicContractRegistration: FetchState.dynamicContractRegistration,
  ~isFetchingAtHead,
) => {
  let newestPartition = partitions->Js.Dict.unsafeGet(newestPartitionIndex->Int.toString)

  let (partitions, newestPartitionIndex) = if (
    newestPartition->FetchState.getNumContracts < maxAddrInPartition
  ) {
    let updated = newestPartition->FetchState.registerDynamicContract(dynamicContractRegistration)
    let partitions =
      partitions->Utils.Dict.updateImmutable(newestPartitionIndex->Int.toString, updated)
    (partitions, newestPartitionIndex)
  } else {
    let newPartition = FetchState.makeRoot(~endBlock)(
      ~startBlock,
      ~logger,
      ~staticContracts=[],
      ~dynamicContractRegistrations=dynamicContractRegistration.dynamicContracts,
      ~isFetchingAtHead,
    )
    let newestPartitionIndex = newestPartitionIndex + 1
    let partitions =
      partitions->Utils.Dict.updateImmutable(newestPartitionIndex->Int.toString, newPartition)
    (partitions, newestPartitionIndex)
  }

  if Env.saveBenchmarkData {
    Benchmark.addSummaryData(
      ~group="Other",
      ~label="Num partitions",
      ~value=partitions->Js.Dict.keys->Array.length->Int.toFloat,
    )
  }
  {partitions, newestPartitionIndex, maxAddrInPartition, endBlock, startBlock, logger}
}

exception UnexpectedPartitionDoesNotExist(partitionIndex)

/**
Updates partition at given id with given values and checks to see if it can be merged into its next register.
Returns Error if the partition/node with given id cannot be found (unexpected)
*/
let update = (self: t, ~id: id, ~latestFetchedBlock, ~newItems, ~currentBlockHeight) => {
  let partitionKey = id.partitionId->Int.toString
  switch self.partitions->Js.Dict.get(partitionKey) {
  | Some(partition) =>
    partition
    ->FetchState.update(~id=id.fetchStateId, ~latestFetchedBlock, ~newItems, ~currentBlockHeight)
    ->Result.map(updatedPartition => {
      ...self,
      partitions: self.partitions->Utils.Dict.updateImmutable(partitionKey, updatedPartition),
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
  {partitions, newestPartitionIndex}: t,
  ~maxNumQueries,
  ~maxPerChainQueueSize,
  ~partitionsCurrentlyFetching,
) => {
  let maxNumQueries = Pervasives.max(
    maxNumQueries - partitionsCurrentlyFetching->Belt.Set.Int.size,
    0,
  )
  let numPartitions = newestPartitionIndex + 1
  let maxPartitionQueueSize = maxPerChainQueueSize / numPartitions

  partitions
  ->Js.Dict.entries
  ->Array.keepMap(((partitionKey, partition)) => {
    let partitionId = partitionKey->Int.fromString->Option.getUnsafe
    if (
      !(partitionsCurrentlyFetching->Set.Int.has(partitionId)) &&
      partition->FetchState.isReadyForNextQuery(~maxQueueSize=maxPartitionQueueSize)
    ) {
      Some({fetchState: partition, partitionId})
    } else {
      None
    }
  })
  ->Js.Array2.sortInPlaceWith((a, b) =>
    FetchState.getLatestFullyFetchedBlock(a.fetchState).blockNumber -
    FetchState.getLatestFullyFetchedBlock(b.fetchState).blockNumber
  )
  ->Js.Array.slice(~start=0, ~end_=maxNumQueries)
}

let updatePartition = (self: t, ~fetchState: FetchState.t, ~partitionId: partitionIndex) => {
  let partitionKey = partitionId->Int.toString
  let partitions = self.partitions->Utils.Dict.updateImmutable(partitionKey, fetchState)
  {...self, partitions}
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
    self.partitions
    ->Js.Dict.entries
    ->Array.map(((partitionKey, partition)) => {
      (partitionKey, partition->FetchState.rollback(~lastKnownValidBlock))
    })
    ->Js.Dict.fromArray

  {...self, partitions}
}

let getEarliestEvent = (self: t) =>
  self.partitions
  ->Js.Dict.values
  ->Array.reduce(None, (accum, fetchState) => {
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
  partitions
  ->Js.Dict.values
  ->Array.reduce(0, (accum, partition) => accum + partition->FetchState.queueSize)

let getLatestFullyFetchedBlock = ({partitions}: t) =>
  partitions
  ->Js.Dict.values
  ->Array.reduce(None, (accum, partition) => {
    let partitionBlock = partition->FetchState.getLatestFullyFetchedBlock
    switch accum {
    | Some({FetchState.blockNumber: blockNumber})
      if partitionBlock.blockNumber >= blockNumber => accum
    | _ => Some(partitionBlock)
    }
  })
  ->Option.getUnsafe

let checkContainsRegisteredContractAddress = ({partitions}: t, ~contractAddress, ~contractName) => {
  partitions
  ->Js.Dict.values
  ->Array.reduce(false, (accum, partition) => {
    accum ||
    partition->FetchState.checkContainsRegisteredContractAddress(~contractAddress, ~contractName)
  })
}

let isFetchingAtHead = ({partitions}: t) => {
  partitions
  ->Js.Dict.values
  ->Array.reduce(true, (accum, partition) => {
    accum && partition.isFetchingAtHead
  })
}

let getFirstEventBlockNumber = ({partitions}: t) => {
  partitions
  ->Js.Dict.values
  ->Array.reduce(None, (accum, partition) => {
    Utils.Math.minOptInt(accum, partition.baseRegister.firstEventBlockNumber)
  })
}

let copy = (self: t) => {
  ...self,
  partitions: self.partitions
  ->Js.Dict.entries
  ->Array.map(((partitionKey, partition)) => (partitionKey, partition->FetchState.copy))
  ->Js.Dict.fromArray,
}
