open Belt
type partitionId = int
type allPartitions = array<FetchState.t>
type t = {
  maxAddrInPartition: int,
  partitions: allPartitions,
  endBlock: option<int>,
  startBlock: int,
  logger: Pino.t,
}

type id = {
  partitionId: partitionId,
  fetchStateId: FetchState.id,
}

type partition = {
  fetchState: FetchState.t,
  partitionId: partitionId,
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

  let partitions = []

  if numAddresses <= maxAddrInPartition {
    let partition = FetchState.make(
      ~staticContracts,
      ~dynamicContractRegistrations,
      ~startBlock,
      ~endBlock,
      ~logger,
      ~isFetchingAtHead=false,
    )
    partitions->Js.Array2.push(partition)->ignore
  } else {
    let staticContractsClone = staticContracts->Array.copy

    //Chunk static contract addresses (clone) until it is under the size of 1 partition
    while staticContractsClone->Array.length > maxAddrInPartition {
      let staticContractsChunk =
        staticContractsClone->Js.Array2.removeCountInPlace(~pos=0, ~count=maxAddrInPartition)

      let staticContractPartition = FetchState.make(
        ~staticContracts=staticContractsChunk,
        ~dynamicContractRegistrations=[],
        ~startBlock,
        ~endBlock,
        ~logger,
        ~isFetchingAtHead=false,
      )
      partitions->Js.Array2.push(staticContractPartition)->ignore
    }

    let dynamicContractRegistrationsClone = dynamicContractRegistrations->Array.copy

    //Add the rest of the static addresses filling the remainder of the partition with dynamic contract
    //registrations
    let remainingStaticContractsWithDynamicPartition = FetchState.make(
      ~staticContracts=staticContractsClone,
      ~dynamicContractRegistrations=dynamicContractRegistrationsClone->Js.Array2.removeCountInPlace(
        ~pos=0,
        ~count=maxAddrInPartition - staticContractsClone->Array.length,
      ),
      ~startBlock,
      ~endBlock,
      ~logger,
      ~isFetchingAtHead=false,
    )
    partitions->Js.Array2.push(remainingStaticContractsWithDynamicPartition)->ignore

    //Make partitions with all remaining dynamic contract registrations
    while dynamicContractRegistrationsClone->Array.length > 0 {
      let dynamicContractRegistrationsChunk =
        dynamicContractRegistrationsClone->Js.Array2.removeCountInPlace(
          ~pos=0,
          ~count=maxAddrInPartition,
        )

      let dynamicContractPartition = FetchState.make(
        ~staticContracts=[],
        ~dynamicContractRegistrations=dynamicContractRegistrationsChunk,
        ~startBlock,
        ~endBlock,
        ~logger,
        ~isFetchingAtHead=false,
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
    maxAddrInPartition,
    partitions,
    endBlock,
    startBlock,
    logger,
  }
}

let registerDynamicContracts = (
  {partitions, maxAddrInPartition, endBlock, startBlock, logger}: t,
  dynamicContractRegistration: FetchState.dynamicContractRegistration,
  ~isFetchingAtHead,
) => {
  let newestPartitionIndex = partitions->Array.length - 1
  let newestPartition = switch partitions[newestPartitionIndex] {
  | Some(p) => p
  | None => Js.Exn.raiseError("Unexpected: No partitions in PartitionedFetchState")
  }

  let partitions = if newestPartition->FetchState.getNumContracts < maxAddrInPartition {
    let updated =
      newestPartition->FetchState.registerDynamicContract(
        dynamicContractRegistration,
        ~isFetchingAtHead,
      )
    partitions->Utils.Array.setIndexImmutable(newestPartitionIndex, updated)
  } else {
    let newPartition = FetchState.make(
      ~startBlock,
      ~endBlock,
      ~logger,
      ~staticContracts=[],
      ~dynamicContractRegistrations=dynamicContractRegistration.dynamicContracts,
      ~isFetchingAtHead,
    )
    partitions->Array.concat([newPartition])
  }

  if Env.Benchmark.shouldSaveData {
    Benchmark.addSummaryData(
      ~group="Other",
      ~label="Num partitions",
      ~value=partitions->Array.length->Int.toFloat,
    )
  }

  {partitions, maxAddrInPartition, endBlock, startBlock, logger}
}

exception UnexpectedPartitionDoesNotExist(partitionId)

/**
Updates partition at given id with given values and checks to see if it can be merged into its next register.
Returns Error if the partition/node with given id cannot be found (unexpected)
*/
let update = (self: t, ~id: id, ~latestFetchedBlock, ~newItems, ~currentBlockHeight, ~chain) => {
  switch self.partitions[id.partitionId] {
  | Some(partition) =>
    partition
    ->FetchState.update(~id=id.fetchStateId, ~latestFetchedBlock, ~newItems, ~currentBlockHeight)
    ->Result.map(updatedPartition => {
      Prometheus.PartitionBlockFetched.set(
        ~blockNumber=latestFetchedBlock.blockNumber,
        ~chainId=chain->ChainMap.Chain.toChainId,
        ~partitionId=id.partitionId,
      )
      {
        ...self,
        partitions: self.partitions->Utils.Array.setIndexImmutable(
          id.partitionId,
          updatedPartition,
        ),
      }
    })
  | _ => Error(UnexpectedPartitionDoesNotExist(id.partitionId))
  }
}

let getReadyPartitions = (
  allPartitions: allPartitions,
  ~maxPerChainQueueSize,
  ~fetchingPartitions,
) => {
  let numPartitions = allPartitions->Array.length
  let maxPartitionQueueSize = maxPerChainQueueSize / numPartitions

  let readyPartitions = []
  allPartitions->Belt.Array.forEachWithIndex((partitionId, fetchState) => {
    if (
      !(fetchingPartitions->Utils.Set.has(partitionId)) &&
      fetchState->FetchState.isReadyForNextQuery(~maxQueueSize=maxPartitionQueueSize)
    ) {
      readyPartitions->Js.Array2.push({fetchState, partitionId})->ignore
    }
  })
  readyPartitions
}

/**
Rolls back all partitions to the given valid block
*/
let rollback = (self: t, ~lastScannedBlock, ~firstChangeEvent) => {
  let partitions = self.partitions->Array.map(partition => {
    partition->FetchState.rollback(~lastScannedBlock, ~firstChangeEvent)
  })

  {...self, partitions}
}

let getEarliestEvent = (self: t) =>
  self.partitions->Array.reduce(None, (accum, fetchState) => {
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
  partitions->Array.reduce(0, (accum, partition) => accum + partition->FetchState.queueSize)

let getLatestFullyFetchedBlock = ({partitions}: t) =>
  partitions
  ->Array.reduce((None: option<FetchState.blockNumberAndTimestamp>), (accum, partition) => {
    let partitionBlock = partition->FetchState.getLatestFullyFetchedBlock
    switch accum {
    | Some({blockNumber}) if partitionBlock.blockNumber >= blockNumber => accum
    | _ => Some(partitionBlock)
    }
  })
  ->Option.getUnsafe

let checkContainsRegisteredContractAddress = (
  {partitions}: t,
  ~contractAddress,
  ~contractName,
  ~chainId,
) => {
  partitions->Array.some(partition => {
    partition->FetchState.checkContainsRegisteredContractAddress(
      ~contractAddress,
      ~contractName,
      ~chainId,
    )
  })
}

let isFetchingAtHead = ({partitions}: t) => {
  partitions->Array.reduce(true, (accum, partition) => {
    accum && partition.isFetchingAtHead
  })
}

let getFirstEventBlockNumber = ({partitions}: t) => {
  partitions->Array.reduce(None, (accum, partition) => {
    Utils.Math.minOptInt(accum, partition.baseRegister.firstEventBlockNumber)
  })
}

let copy = (self: t) => {
  ...self,
  partitions: self.partitions->Array.map(partition => partition->FetchState.copy),
}
