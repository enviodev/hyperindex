open Belt

type contractConfig = {filterByAddresses: bool}

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
  addressesByContractName: dict<array<Address.t>>,
}

type t = {
  partitions: array<partition>,
  // Used for the incremental partition id. Can't use the partitions length,
  // since partitions might be deleted on merge or cleaned up
  nextPartitionIndex: int,
  startBlock: int,
  endBlock: option<int>,
  maxAddrInPartition: int,
  normalSelection: selection,
  // By address
  indexingContracts: dict<Internal.indexingContract>,
  // By contract name
  contractConfigs: dict<contractConfig>,
  // Not used for logic - only metadata
  chainId: int,
  // The block number of the latest block fetched
  // which added all its events to the queue
  latestFullyFetchedBlock: blockNumberAndTimestamp,
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
  // How many items we should aim to have in the buffer
  // ready for processing
  targetBufferSize: int,
  onBlockConfigs: array<Internal.onBlockConfig>,
}

let mergeIntoPartition = (p: partition, ~target: partition, ~maxAddrInPartition) => {
  switch (p, target) {
  | ({selection: {dependsOnAddresses: true}}, {selection: {dependsOnAddresses: true}}) => {
      let latestFetchedBlock = target.latestFetchedBlock

      let mergedAddresses = Js.Dict.empty()

      let allowedAddressesNumber = ref(maxAddrInPartition)

      target.addressesByContractName->Utils.Dict.forEachWithKey((addresses, contractName) => {
        allowedAddressesNumber := allowedAddressesNumber.contents - addresses->Array.length
        mergedAddresses->Js.Dict.set(contractName, addresses)
      })

      // Start with putting all addresses to the merging dict
      // And if they exceed the limit, start removing from the merging dict
      // and putting into the rest dict
      p.addressesByContractName->Utils.Dict.forEachWithKey((addresses, contractName) => {
        allowedAddressesNumber := allowedAddressesNumber.contents - addresses->Array.length
        switch mergedAddresses->Utils.Dict.dangerouslyGetNonOption(contractName) {
        | Some(targetAddresses) =>
          mergedAddresses->Js.Dict.set(contractName, Array.concat(targetAddresses, addresses))
        | None => mergedAddresses->Js.Dict.set(contractName, addresses)
        }
      })

      let rest = if allowedAddressesNumber.contents < 0 {
        let restAddresses = Js.Dict.empty()

        mergedAddresses->Utils.Dict.forEachWithKey((addresses, contractName) => {
          if allowedAddressesNumber.contents === 0 {
            ()
          } else if addresses->Array.length <= -allowedAddressesNumber.contents {
            allowedAddressesNumber := allowedAddressesNumber.contents + addresses->Array.length
            mergedAddresses->Utils.Dict.deleteInPlace(contractName)
            restAddresses->Js.Dict.set(contractName, addresses)
          } else {
            let restFrom = addresses->Array.length + allowedAddressesNumber.contents
            mergedAddresses->Js.Dict.set(
              contractName,
              addresses->Js.Array2.slice(~start=0, ~end_=restFrom),
            )
            restAddresses->Js.Dict.set(contractName, addresses->Js.Array2.sliceFrom(restFrom))
            allowedAddressesNumber := 0
          }
        })

        Some({
          id: p.id,
          status: {
            fetchingStateId: None,
          },
          selection: target.selection,
          addressesByContractName: restAddresses,
          latestFetchedBlock,
        })
      } else {
        None
      }

      (
        {
          id: target.id,
          status: {
            fetchingStateId: None,
          },
          selection: target.selection,
          addressesByContractName: mergedAddresses,
          latestFetchedBlock,
        },
        rest,
      )
    }
  | ({selection: {dependsOnAddresses: false}}, _)
  | (_, {selection: {dependsOnAddresses: false}}) => (p, Some(target))
  }
}

@inline
let bufferBlockNumber = ({latestFullyFetchedBlock, latestOnBlockBlockNumber}: t) => {
  latestOnBlockBlockNumber < latestFullyFetchedBlock.blockNumber
    ? latestOnBlockBlockNumber
    : latestFullyFetchedBlock.blockNumber
}

/**
* Returns the latest block which is ready to be consumed
*/
@inline
let bufferBlock = ({latestFullyFetchedBlock, latestOnBlockBlockNumber}: t) => {
  latestOnBlockBlockNumber < latestFullyFetchedBlock.blockNumber
    ? {
        blockNumber: latestOnBlockBlockNumber,
        blockTimestamp: 0,
      }
    : latestFullyFetchedBlock
}

/*
Comparitor for two events from the same chain. No need for chain id or timestamp
*/
let compareBufferItem = (a: Internal.item, b: Internal.item) => {
  let blockDiff = a->Internal.getItemBlockNumber - b->Internal.getItemBlockNumber
  if blockDiff === 0 {
    a->Internal.getItemLogIndex - b->Internal.getItemLogIndex
  } else {
    blockDiff
  }
}

// Some big number which should be bigger than any log index
let blockItemLogIndex = 16777216

/*
 Update fetchState, merge registers and recompute derived values
 */
let updateInternal = (
  fetchState: t,
  ~partitions=fetchState.partitions,
  ~nextPartitionIndex=fetchState.nextPartitionIndex,
  ~indexingContracts=fetchState.indexingContracts,
  ~mutItems=?,
  ~blockLag=fetchState.blockLag,
): t => {
  let firstPartition = partitions->Js.Array2.unsafe_get(0)
  let latestFullyFetchedBlock = ref(firstPartition.latestFetchedBlock)
  for idx in 0 to partitions->Array.length - 1 {
    let p = partitions->Js.Array2.unsafe_get(idx)
    if latestFullyFetchedBlock.contents.blockNumber > p.latestFetchedBlock.blockNumber {
      latestFullyFetchedBlock := p.latestFetchedBlock
    }
  }
  let latestFullyFetchedBlock = latestFullyFetchedBlock.contents

  let mutItemsRef = ref(mutItems)

  let latestOnBlockBlockNumber = switch fetchState.onBlockConfigs {
  | [] => latestFullyFetchedBlock.blockNumber
  | onBlockConfigs => {
      // Calculate the max block number we are going to create items for
      // Use targetBufferSize to get the last target item in the buffer
      //
      // mutItems is not very reliable, since it might not be sorted,
      // but the chances for it happen are very low and not critical
      //
      // All this needed to prevent OOM when adding too many block items to the queue
      let maxBlockNumber = switch switch mutItemsRef.contents {
      | Some(mutItems) => mutItems
      | None => fetchState.buffer
      }->Belt.Array.get(fetchState.targetBufferSize - 1) {
      | Some(item) => item->Internal.getItemBlockNumber
      | None => latestFullyFetchedBlock.blockNumber
      }

      let mutItems = switch mutItemsRef.contents {
      | Some(mutItems) => mutItems
      | None => fetchState.buffer->Array.copy
      }
      mutItemsRef := Some(mutItems)

      let newItemsCounter = ref(0)
      let latestOnBlockBlockNumber = ref(fetchState.latestOnBlockBlockNumber)

      // Simply iterate over every block
      // could have a better algorithm to iterate over blocks in a more efficient way
      // but raw loops are fast enough
      while (
        latestOnBlockBlockNumber.contents < maxBlockNumber &&
          // Additional safeguard to prevent OOM
          newItemsCounter.contents <= fetchState.targetBufferSize
      ) {
        let blockNumber = latestOnBlockBlockNumber.contents + 1
        latestOnBlockBlockNumber := blockNumber

        for configIdx in 0 to onBlockConfigs->Array.length - 1 {
          let onBlockConfig = onBlockConfigs->Js.Array2.unsafe_get(configIdx)

          let handlerStartBlock = switch onBlockConfig.startBlock {
          | Some(startBlock) => startBlock
          | None => fetchState.startBlock
          }

          if (
            blockNumber >= handlerStartBlock &&
            switch onBlockConfig.endBlock {
            | Some(endBlock) => blockNumber <= endBlock
            | None => true
            } &&
            (blockNumber - handlerStartBlock)->Pervasives.mod(onBlockConfig.interval) === 0
          ) {
            mutItems->Array.push(
              Block({
                onBlockConfig,
                blockNumber,
                logIndex: blockItemLogIndex + onBlockConfig.index,
              }),
            )
            newItemsCounter := newItemsCounter.contents + 1
          }
        }
      }

      latestOnBlockBlockNumber.contents
    }
  }

  let updatedFetchState = {
    maxAddrInPartition: fetchState.maxAddrInPartition,
    startBlock: fetchState.startBlock,
    endBlock: fetchState.endBlock,
    contractConfigs: fetchState.contractConfigs,
    normalSelection: fetchState.normalSelection,
    chainId: fetchState.chainId,
    onBlockConfigs: fetchState.onBlockConfigs,
    targetBufferSize: fetchState.targetBufferSize,
    nextPartitionIndex,
    partitions,
    latestOnBlockBlockNumber,
    latestFullyFetchedBlock,
    indexingContracts,
    blockLag,
    buffer: switch mutItemsRef.contents {
    // Theoretically it could be faster to asume that
    // the items are sorted, but there are cases
    // when the data source returns them unsorted
    | Some(mutItems) => mutItems->Js.Array2.sortInPlaceWith(compareBufferItem)
    | None => fetchState.buffer
    },
  }

  Prometheus.IndexingPartitions.set(
    ~partitionsCount=partitions->Array.length,
    ~chainId=fetchState.chainId,
  )
  Prometheus.IndexingBufferSize.set(
    ~bufferSize=updatedFetchState.buffer->Array.length,
    ~chainId=fetchState.chainId,
  )
  Prometheus.IndexingBufferBlockNumber.set(
    ~blockNumber=updatedFetchState->bufferBlockNumber,
    ~chainId=fetchState.chainId,
  )

  updatedFetchState
}

let numAddresses = fetchState => fetchState.indexingContracts->Js.Dict.keys->Array.length

let warnDifferentContractType = (
  fetchState,
  ~existingContract: Internal.indexingContract,
  ~dc: Internal.indexingContract,
) => {
  let logger = Logging.createChild(
    ~params={
      "chainId": fetchState.chainId,
      "contractAddress": dc.address->Address.toString,
      "existingContractType": existingContract.contractName,
      "newContractType": dc.contractName,
    },
  )
  logger->Logging.childWarn(`Skipping contract registration: Contract address is already registered for one contract and cannot be registered for another contract.`)
}

let registerDynamicContracts = (
  fetchState: t,
  // These are raw items which might have dynamic contracts received from contractRegister call.
  // Might contain duplicates which we should filter out
  items: array<Internal.item>,
) => {
  if fetchState.normalSelection.eventConfigs->Utils.Array.isEmpty {
    // Can the normalSelection be empty?
    // Probably only on pre-registration, but we don't
    // register dynamic contracts during it
    Js.Exn.raiseError(
      "Invalid configuration. No events to fetch for the dynamic contract registration.",
    )
  }

  let indexingContracts = fetchState.indexingContracts
  let registeringContracts: dict<Internal.indexingContract> = Js.Dict.empty()
  let addressesByContractName = Js.Dict.empty()
  let earliestRegisteringEventBlockNumber = ref(%raw(`Infinity`))
  let hasDCWithFilterByAddresses = ref(false)

  for itemIdx in 0 to items->Array.length - 1 {
    let item = items->Js.Array2.unsafe_get(itemIdx)
    switch item->Internal.getItemDcs {
    | None => ()
    | Some(dcs) =>
      for idx in 0 to dcs->Array.length - 1 {
        let dc = dcs->Js.Array2.unsafe_get(idx)

        switch fetchState.contractConfigs->Utils.Dict.dangerouslyGetNonOption(dc.contractName) {
        | Some({filterByAddresses}) =>
          // Prevent registering already indexing contracts
          switch indexingContracts->Utils.Dict.dangerouslyGetNonOption(
            dc.address->Address.toString,
          ) {
          | Some(existingContract) =>
            // FIXME: Instead of filtering out duplicates,
            // we should check the block number first.
            // If new registration with earlier block number
            // we should register it for the missing block range
            if existingContract.contractName != dc.contractName {
              fetchState->warnDifferentContractType(~existingContract, ~dc)
            } else if existingContract.startBlock > dc.startBlock {
              let logger = Logging.createChild(
                ~params={
                  "chainId": fetchState.chainId,
                  "contractAddress": dc.address->Address.toString,
                  "existingBlockNumber": existingContract.startBlock,
                  "newBlockNumber": dc.startBlock,
                },
              )
              logger->Logging.childWarn(`Skipping contract registration: Contract address is already registered at a later block number. Currently registration of the same contract address is not supported by Envio. Reach out to us if it's a problem for you.`)
            }
            // Remove the DC from item to prevent it from saving to the db
            let _ = dcs->Js.Array2.removeCountInPlace(~count=1, ~pos=idx)
          | None =>
            let shouldUpdate = switch registeringContracts->Utils.Dict.dangerouslyGetNonOption(
              dc.address->Address.toString,
            ) {
            | Some(registeringContract) if registeringContract.contractName != dc.contractName =>
              fetchState->warnDifferentContractType(~existingContract=registeringContract, ~dc)
              false
            | Some(_) => // Since the DC is registered by an earlier item in the query
              // FIXME: This unsafely relies on the asc order of the items
              // which is 99% true, but there were cases when the source ordering was wrong
              false
            | None =>
              hasDCWithFilterByAddresses := hasDCWithFilterByAddresses.contents || filterByAddresses
              addressesByContractName->Utils.Dict.push(dc.contractName, dc.address)
              true
            }
            if shouldUpdate {
              earliestRegisteringEventBlockNumber :=
                Pervasives.min(earliestRegisteringEventBlockNumber.contents, dc.startBlock)
              registeringContracts->Js.Dict.set(dc.address->Address.toString, dc)
            } else {
              // Remove the DC from item to prevent it from saving to the db
              let _ = dcs->Js.Array2.removeCountInPlace(~count=1, ~pos=idx)
            }
          }
        | None => {
            let logger = Logging.createChild(
              ~params={
                "chainId": fetchState.chainId,
                "contractAddress": dc.address->Address.toString,
                "contractName": dc.contractName,
              },
            )
            logger->Logging.childWarn(`Skipping contract registration: Contract doesn't have any events to fetch.`)
            let _ = dcs->Js.Array2.removeCountInPlace(~count=1, ~pos=idx)
          }
        }
      }
    }
  }

  let dcsToStore = registeringContracts->Js.Dict.values
  switch dcsToStore {
  // Dont update anything when everything was filter out
  | [] => fetchState
  | _ => {
      let newPartitions = if (
        // This case is more like a simple case when we need to create a single partition.
        // Theoretically, we can only keep else, but don't want to iterate over the addresses again.

        dcsToStore->Array.length <= fetchState.maxAddrInPartition &&
          !hasDCWithFilterByAddresses.contents
      ) {
        [
          {
            id: fetchState.nextPartitionIndex->Int.toString,
            status: {
              fetchingStateId: None,
            },
            latestFetchedBlock: {
              blockNumber: earliestRegisteringEventBlockNumber.contents - 1,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            addressesByContractName,
          },
        ]
      } else {
        let partitions = []

        let earliestRegisteringEventBlockNumber = ref(%raw(`Infinity`))
        let pendingAddressesByContractName = ref(Js.Dict.empty())
        let pendingCount = ref(0)

        let addPartition = () =>
          partitions->Array.push({
            id: (fetchState.nextPartitionIndex + partitions->Array.length)->Int.toString,
            status: {
              fetchingStateId: None,
            },
            latestFetchedBlock: {
              blockNumber: earliestRegisteringEventBlockNumber.contents - 1,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            addressesByContractName: pendingAddressesByContractName.contents,
          })

        // I use for loops instead of forEach, so ReScript better inlines ref access
        for idx in 0 to addressesByContractName->Js.Dict.keys->Array.length - 1 {
          let contractName = addressesByContractName->Js.Dict.keys->Js.Array2.unsafe_get(idx)
          let addresses = addressesByContractName->Js.Dict.unsafeGet(contractName)

          // Can unsafely get it, because we already filtered out the contracts
          // that don't have any events to fetch
          let contractConfig = fetchState.contractConfigs->Js.Dict.unsafeGet(contractName)

          // For this case we can't filter out events earlier than contract registration
          // on the client side, so we need to keep the old logic of creating
          // a partition for every block range, so there are no irrelevant events
          if contractConfig.filterByAddresses {
            let byStartBlock = Js.Dict.empty()

            for jdx in 0 to addresses->Array.length - 1 {
              let address = addresses->Js.Array2.unsafe_get(jdx)
              let indexingContract =
                registeringContracts->Js.Dict.unsafeGet(address->Address.toString)

              byStartBlock->Utils.Dict.push(indexingContract.startBlock->Int.toString, address)
            }

            // Will be in the ASC order by Js spec
            byStartBlock
            ->Js.Dict.keys
            ->Js.Array2.forEach(startBlockKey => {
              let addresses = byStartBlock->Js.Dict.unsafeGet(startBlockKey)
              let addressesByContractName = Js.Dict.empty()
              addressesByContractName->Js.Dict.set(contractName, addresses)
              partitions->Array.push({
                id: (fetchState.nextPartitionIndex + partitions->Array.length)->Int.toString,
                status: {
                  fetchingStateId: None,
                },
                latestFetchedBlock: {
                  blockNumber: Pervasives.max(startBlockKey->Int.fromString->Option.getExn - 1, 0),
                  blockTimestamp: 0,
                },
                selection: fetchState.normalSelection,
                addressesByContractName,
              })
            })
          } else {
            // The goal is to try to split partitions the way,
            // so there are mostly addresses of the same contract in each partition
            // TODO: Should do the same for the initial FetchState creation
            for jdx in 0 to addresses->Array.length - 1 {
              let address = addresses->Js.Array2.unsafe_get(jdx)
              if pendingCount.contents === fetchState.maxAddrInPartition {
                addPartition()
                pendingAddressesByContractName := Js.Dict.empty()
                pendingCount := 0
                earliestRegisteringEventBlockNumber := %raw(`Infinity`)
              }

              let indexingContract =
                registeringContracts->Js.Dict.unsafeGet(address->Address.toString)

              pendingCount := pendingCount.contents + 1
              pendingAddressesByContractName.contents->Utils.Dict.push(contractName, address)
              earliestRegisteringEventBlockNumber :=
                Pervasives.min(
                  earliestRegisteringEventBlockNumber.contents,
                  indexingContract.startBlock,
                )
            }
          }
        }

        if pendingCount.contents > 0 {
          addPartition()
        }

        partitions
      }

      Prometheus.IndexingAddresses.set(
        ~addressesCount=fetchState->numAddresses + dcsToStore->Array.length,
        ~chainId=fetchState.chainId,
      )

      fetchState->updateInternal(
        ~partitions=fetchState.partitions->Js.Array2.concat(newPartitions),
        ~indexingContracts=// We don't need registeringContracts anymore,
        // so we can safely mixin indexingContracts in it
        // The original indexingContracts won't be mutated
        Utils.Dict.mergeInPlace(registeringContracts, indexingContracts),
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
  addressesByContractName: dict<array<Address.t>>,
  target: queryTarget,
  indexingContracts: dict<Internal.indexingContract>,
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
  ~newItems,
): result<t, exn> =>
  {
    let partitionId = query.partitionId

    switch partitions->Array.getIndexBy(p => p.id === partitionId) {
    | Some(pIndex) =>
      let p = partitions->Js.Array2.unsafe_get(pIndex)
      let updatedPartition = {
        ...p,
        status: {
          fetchingStateId: None,
        },
        latestFetchedBlock,
      }

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
      ~mutItems=?{
        switch newItems {
        | [] => None
        | _ => Some(fetchState.buffer->Array.concat(newItems))
        }
      },
    )
  })

let makePartitionQuery = (p: partition, ~indexingContracts, ~endBlock, ~mergeTarget) => {
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
      addressesByContractName: p.addressesByContractName,
      indexingContracts,
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

let addressesByContractNameCount = (addressesByContractName: dict<array<Address.t>>) => {
  let numAddresses = ref(0)
  let contractNames = addressesByContractName->Js.Dict.keys
  for idx in 0 to contractNames->Array.length - 1 {
    let contractName = contractNames->Js.Array2.unsafe_get(idx)
    numAddresses :=
      numAddresses.contents + addressesByContractName->Js.Dict.unsafeGet(contractName)->Array.length
  }
  numAddresses.contents
}

let addressesByContractNameGetAll = (addressesByContractName: dict<array<Address.t>>) => {
  let all = ref([])
  let contractNames = addressesByContractName->Js.Dict.keys
  for idx in 0 to contractNames->Array.length - 1 {
    let contractName = contractNames->Js.Array2.unsafe_get(idx)
    all := all.contents->Array.concat(addressesByContractName->Js.Dict.unsafeGet(contractName))
  }
  all.contents
}

@inline
let isFullPartition = (p: partition, ~maxAddrInPartition) => {
  switch p {
  | {selection: {dependsOnAddresses: false}} => true
  | _ => p.addressesByContractName->addressesByContractNameCount >= maxAddrInPartition
  }
}

let getNextQuery = (
  {
    buffer,
    partitions,
    targetBufferSize,
    maxAddrInPartition,
    endBlock,
    indexingContracts,
    blockLag,
  }: t,
  ~concurrencyLimit,
  ~currentBlockHeight,
  ~stateId,
) => {
  let headBlock = currentBlockHeight - blockLag
  if headBlock <= 0 {
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
      | Some(endBlock) => headBlock < endBlock
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
      let hasReachedTheHead = p.latestFetchedBlock.blockNumber >= headBlock

      if isFetching || !hasReachedTheHead {
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

    // We want to limit the buffer size to targetBufferSize (usually 3 * batchSize)
    // To make sure the processing always has some buffer
    // and not increase the memory usage too much
    // If a partition fetched further than 3 * batchSize,
    // it should be skipped until the buffer is consumed
    let maxQueryBlockNumber = {
      switch buffer->Array.get(targetBufferSize - 1) {
      | Some(item) =>
        // Just in case check that we don't query beyond the current block
        Pervasives.min(item->Internal.getItemBlockNumber, currentBlockHeight)
      | None => currentBlockHeight
      }
    }
    let queries = []

    let registerPartitionQuery = (p, ~mergeTarget=?) => {
      if (
        p->checkIsFetchingPartition->not && p.latestFetchedBlock.blockNumber < maxQueryBlockNumber
      ) {
        let endBlock = switch blockLag {
        | 0 => endBlock
        | _ =>
          switch endBlock {
          | Some(endBlock) => Some(Pervasives.min(headBlock, endBlock))
          // Force head block as an endBlock when blockLag is set
          // because otherwise HyperSync might return bigger range
          | None => Some(headBlock)
          }
        }
        // Enforce the respose range up until target block
        // Otherwise for indexers with 100+ partitions
        // we might blow up the buffer size to more than 600k events
        // simply because of HyperSync returning extra blocks
        let endBlock = switch (endBlock, maxQueryBlockNumber < currentBlockHeight) {
        | (Some(endBlock), true) => Some(Pervasives.min(maxQueryBlockNumber, endBlock))
        | (None, true) => Some(maxQueryBlockNumber)
        | (_, false) => endBlock
        }

        switch p->makePartitionQuery(~indexingContracts, ~endBlock, ~mergeTarget) {
        | Some(q) => queries->Array.push(q)
        | None => ()
        }
      }
    }

    fullPartitions->Array.forEach(p => p->registerPartitionQuery)

    if areMergingPartitionsFetching.contents->not {
      switch mergingPartitions {
      | [] => ()
      | [p] => p->registerPartitionQuery
      | _ =>
        switch (mostBehindMergingPartition.contents, mergingPartitionTarget.contents) {
        | (Some(p), None) => p->registerPartitionQuery
        | (Some(p), Some(mergeTarget)) => p->registerPartitionQuery(~mergeTarget)
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

let getTimestampAt = (fetchState: t, ~index) => {
  switch fetchState.buffer->Belt.Array.get(index) {
  | Some(Event({timestamp})) => timestamp
  | Some(Block(_)) =>
    Js.Exn.raiseError("Block handlers are not supported for ordered multichain mode.")
  | None => (fetchState->bufferBlock).blockTimestamp
  }
}

let hasReadyItem = ({buffer} as fetchState: t) => {
  switch buffer->Belt.Array.get(0) {
  | Some(item) => item->Internal.getItemBlockNumber <= fetchState->bufferBlockNumber
  | None => false
  }
}

let getReadyItemsCount = (fetchState: t, ~targetSize: int, ~fromItem) => {
  let readyBlockNumber = ref(fetchState->bufferBlockNumber)
  let acc = ref(0)
  let isFinished = ref(false)
  while !isFinished.contents {
    switch fetchState.buffer->Belt.Array.get(fromItem + acc.contents) {
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
  ~eventConfigs: array<Internal.eventConfig>,
  ~contracts: array<Internal.indexingContract>,
  ~maxAddrInPartition,
  ~chainId,
  ~targetBufferSize,
  ~progressBlockNumber=startBlock - 1,
  ~onBlockConfigs=[],
  ~blockLag=0,
): t => {
  let latestFetchedBlock = {
    blockTimestamp: 0,
    blockNumber: progressBlockNumber,
  }

  let notDependingOnAddresses = []
  let normalEventConfigs = []
  let contractNamesWithNormalEvents = Utils.Set.make()
  let indexingContracts = Js.Dict.empty()
  let contractConfigs = Js.Dict.empty()

  eventConfigs->Array.forEach(ec => {
    switch contractConfigs->Utils.Dict.dangerouslyGetNonOption(ec.contractName) {
    | Some({filterByAddresses}) =>
      contractConfigs->Js.Dict.set(
        ec.contractName,
        {filterByAddresses: filterByAddresses || ec.filterByAddresses},
      )
    | None =>
      contractConfigs->Js.Dict.set(ec.contractName, {filterByAddresses: ec.filterByAddresses})
    }

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
      addressesByContractName: Js.Dict.empty(),
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
          addressesByContractName: Js.Dict.empty(),
        }
      }

      let pendingNormalPartition = ref(makePendingNormalPartition())

      contracts->Array.forEach(contract => {
        let contractName = contract.contractName
        if contractNamesWithNormalEvents->Utils.Set.has(contractName) {
          let pendingPartition = pendingNormalPartition.contents
          pendingPartition.addressesByContractName->Utils.Dict.push(contractName, contract.address)
          indexingContracts->Js.Dict.set(contract.address->Address.toString, contract)
          if (
            pendingPartition.addressesByContractName->addressesByContractNameCount ===
              maxAddrInPartition
          ) {
            // FIXME: should split into separate partitions
            // depending on the start block
            partitions->Array.push(pendingPartition)
            pendingNormalPartition := makePendingNormalPartition()
          }
        }
      })

      if pendingNormalPartition.contents.addressesByContractName->addressesByContractNameCount > 0 {
        partitions->Array.push(pendingNormalPartition.contents)
      }
    }
  }

  if partitions->Array.length === 0 {
    Js.Exn.raiseError(
      "Invalid configuration: Nothing to fetch. Make sure that you provided at least one contract address to index, or have events with Wildcard mode enabled.",
    )
  }

  let numAddresses = indexingContracts->Js.Dict.keys->Array.length
  Prometheus.IndexingAddresses.set(~addressesCount=numAddresses, ~chainId)
  Prometheus.IndexingPartitions.set(~partitionsCount=partitions->Array.length, ~chainId)
  Prometheus.IndexingBufferSize.set(~bufferSize=0, ~chainId)
  Prometheus.IndexingBufferBlockNumber.set(~blockNumber=latestFetchedBlock.blockNumber, ~chainId)
  switch endBlock {
  | Some(endBlock) => Prometheus.IndexingEndBlock.set(~endBlock, ~chainId)
  | None => ()
  }

  {
    partitions,
    nextPartitionIndex: partitions->Array.length,
    contractConfigs,
    maxAddrInPartition,
    chainId,
    startBlock,
    endBlock,
    latestFullyFetchedBlock: latestFetchedBlock,
    latestOnBlockBlockNumber: progressBlockNumber,
    normalSelection,
    indexingContracts,
    blockLag,
    onBlockConfigs,
    targetBufferSize,
    buffer: [],
  }
}

let bufferSize = ({buffer}: t) => buffer->Array.length

/**
Rolls back partitions to the given valid block
*/
let rollbackPartition = (p: partition, ~targetBlockNumber, ~addressesToRemove) => {
  let shouldRollbackFetched = p.latestFetchedBlock.blockNumber > targetBlockNumber
  let latestFetchedBlock = shouldRollbackFetched
    ? {
        blockNumber: targetBlockNumber,
        blockTimestamp: 0,
      }
    : p.latestFetchedBlock
  switch p {
  | {selection: {dependsOnAddresses: false}} =>
    Some({
      ...p,
      latestFetchedBlock,
      status: {
        fetchingStateId: None,
      },
    })
  | {addressesByContractName} =>
    let rollbackedAddressesByContractName = Js.Dict.empty()
    addressesByContractName->Utils.Dict.forEachWithKey((addresses, contractName) => {
      let keptAddresses =
        addresses->Array.keep(address => !(addressesToRemove->Utils.Set.has(address)))
      if keptAddresses->Array.length > 0 {
        rollbackedAddressesByContractName->Js.Dict.set(contractName, keptAddresses)
      }
    })

    if rollbackedAddressesByContractName->Js.Dict.keys->Array.length === 0 {
      None
    } else {
      Some({
        id: p.id,
        selection: p.selection,
        status: {
          fetchingStateId: None,
        },
        addressesByContractName: rollbackedAddressesByContractName,
        latestFetchedBlock,
      })
    }
  }
}

let rollback = (fetchState: t, ~targetBlockNumber) => {
  let addressesToRemove = Utils.Set.make()
  let indexingContracts = Js.Dict.empty()

  fetchState.indexingContracts
  ->Js.Dict.keys
  ->Array.forEach(address => {
    let indexingContract = fetchState.indexingContracts->Js.Dict.unsafeGet(address)
    switch indexingContract.registrationBlock {
    | Some(registrationBlock) if registrationBlock > targetBlockNumber => {
        //If the registration block is later than the first change event,
        //Do not keep it and add to the removed addresses
        let _ = addressesToRemove->Utils.Set.add(address->Address.unsafeFromString)
      }
    | _ => indexingContracts->Js.Dict.set(address, indexingContract)
    }
  })

  let partitions =
    fetchState.partitions->Array.keepMap(p =>
      p->rollbackPartition(~targetBlockNumber, ~addressesToRemove)
    )

  {
    ...fetchState,
    latestOnBlockBlockNumber: targetBlockNumber, // TODO: This is not tested. I assume there might be a possible issue of it skipping some blocks
  }->updateInternal(
    ~partitions,
    ~indexingContracts,
    ~mutItems=fetchState.buffer->Array.keep(item =>
      switch item {
      | Event({blockNumber})
      | Block({blockNumber}) => blockNumber
      } <=
      targetBlockNumber
    ),
  )
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

let isReadyToEnterReorgThreshold = (
  {endBlock, blockLag, buffer} as fetchState: t,
  ~currentBlockHeight,
) => {
  let bufferBlockNumber = fetchState->bufferBlockNumber
  currentBlockHeight !== 0 &&
  switch endBlock {
  | Some(endBlock) if bufferBlockNumber >= endBlock => true
  | _ => bufferBlockNumber >= currentBlockHeight - blockLag
  } &&
  buffer->Utils.Array.isEmpty
}

let sortForUnorderedBatch = {
  let hasFullBatch = ({buffer} as fetchState: t, ~batchSizeTarget) => {
    switch buffer->Belt.Array.get(batchSizeTarget - 1) {
    | Some(item) => item->Internal.getItemBlockNumber <= fetchState->bufferBlockNumber
    | None => false
    }
  }

  (fetchStates: array<t>, ~batchSizeTarget: int) => {
    fetchStates
    ->Array.copy
    ->Js.Array2.sortInPlaceWith((a: t, b: t) => {
      switch (a->hasFullBatch(~batchSizeTarget), b->hasFullBatch(~batchSizeTarget)) {
      | (true, true)
      | (false, false) =>
        switch (a.buffer->Belt.Array.get(0), b.buffer->Belt.Array.get(0)) {
        | (Some(Event({timestamp: aTimestamp})), Some(Event({timestamp: bTimestamp}))) =>
          aTimestamp - bTimestamp
        | (Some(Block(_)), _)
        | (_, Some(Block(_))) =>
          // Currently block items don't have a timestamp,
          // so we sort chains with them in a random order
          Js.Math.random_int(-1, 1)
        // We don't care about the order of chains with no items
        // Just keep them to increase the progress block number when relevant
        | (Some(_), None) => -1
        | (None, Some(_)) => 1
        | (None, None) => 0
        }
      | (true, false) => -1
      | (false, true) => 1
      }
    })
  }
}

// Ordered multichain mode can't skip blocks, even if there are no items.
let getUnorderedMultichainProgressBlockNumberAt = ({buffer} as fetchState: t, ~index) => {
  let bufferBlockNumber = fetchState->bufferBlockNumber
  switch buffer->Belt.Array.get(index) {
  | Some(item) if bufferBlockNumber >= item->Internal.getItemBlockNumber =>
    item->Internal.getItemBlockNumber - 1
  | _ => bufferBlockNumber
  }
}
