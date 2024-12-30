open Belt

type allPartitions = array<FetchState.t>
type t = {
  maxAddrInPartition: int,
  partitions: allPartitions,
  endBlock: option<int>,
  startBlock: int,
  logger: Pino.t,
}

let make = (
  ~maxAddrInPartition,
  ~endBlock,
  ~staticContracts,
  ~dynamicContractRegistrations,
  ~startBlock,
  ~logger,
) => {
  let partition = FetchState.make(
    ~staticContracts,
    ~dynamicContractRegistrations,
    ~startBlock,
    ~maxAddrInPartition,
    ~isFetchingAtHead=false,
  )

  {
    maxAddrInPartition,
    partitions: [partition],
    endBlock,
    startBlock,
    logger,
  }
}

exception InvalidFetchState({message: string})

let registerDynamicContracts = (
  {partitions, maxAddrInPartition, endBlock, startBlock, logger}: t,
  dynamicContractRegistration: FetchState.dynamicContractRegistration,
  ~isFetchingAtHead,
) => {
  let fetchState = switch partitions {
  | [fetchState] => fetchState
  | _ =>
    raise(
      InvalidFetchState({
        message: "Unexpected: Invalid fetchState in PartitionedFetchState",
      }),
    )
  }

  {
    partitions: [
      fetchState->FetchState.registerDynamicContract(
        dynamicContractRegistration,
        ~isFetchingAtHead,
      ),
    ],
    maxAddrInPartition,
    endBlock,
    startBlock,
    logger,
  }
}

/**
Updates partition at given id with given values and checks to see if it can be merged into its next register.
Returns Error if the partition/node with given id cannot be found (unexpected)
*/
let setQueryResponse = (
  self: t,
  ~query: FetchState.query,
  ~latestFetchedBlock,
  ~newItems,
  ~currentBlockHeight,
  ~chain,
) => {
  let partitionId = switch query {
  | PartitionQuery({partitionId})
  | MergeQuery({partitionId}) => partitionId
  }

  switch self.partitions {
  | [fetchState] =>
    fetchState
    ->FetchState.setQueryResponse(~query, ~latestFetchedBlock, ~newItems, ~currentBlockHeight)
    ->Result.map(updatedFetchState => {
      Prometheus.PartitionBlockFetched.set(
        ~blockNumber=latestFetchedBlock.blockNumber,
        ~chainId=chain->ChainMap.Chain.toChainId,
        ~partitionId,
      )
      {
        ...self,
        partitions: [updatedFetchState],
      }
    })
  | _ =>
    Error(
      InvalidFetchState({
        message: "Unexpected: Invalid fetchState in PartitionedFetchState",
      }),
    )
  }
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
    if fetchState->FetchState.isActivelyIndexing(~endBlock=self.endBlock) {
      let nextItem = fetchState->FetchState.getEarliestEvent
      switch accum {
      | Some(accumItem) if FetchState.qItemLt(accumItem, nextItem) => accum
      | _ => Some(nextItem)
      }
    } else {
      accum
    }
  })

let isActivelyIndexing = (self: t) =>
  self.partitions->Js.Array2.every(fs => fs->FetchState.isActivelyIndexing(~endBlock=self.endBlock))

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
    Utils.Math.minOptInt(accum, partition.firstEventBlockNumber)
  })
}

let copy = (self: t) => {
  ...self,
  partitions: self.partitions->Array.map(partition => partition->FetchState.copy),
}

let syncStateOnQueueUpdate = (self: t) => {
  {
    ...self,
    partitions: self.partitions->Array.map(partition => partition->FetchState.updateInternal),
  }
}
