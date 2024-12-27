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
An id for a given register
*/
type id = string

let rootRegisterId = "root"

let makeDynamicContractRegisterId = (dynamicContractId: dynamicContractId) => {
  `dynamic-${dynamicContractId.blockNumber->Int.toString}-${dynamicContractId.logIndex->Int.toString}`
}

let isRootRegisterId = id => id === rootRegisterId

let registerIdToName = id => {
  if id->isRootRegisterId {
    "Root"
  } else {
    "Dynamic Contract"
  }
}

/**
A state that holds a queue of events and data regarding what to fetch next.
There's always a root register and potentially additional registers for dynamic contracts.
When the registers are caught up to each other they are getting merged
*/
type register = {
  id: id,
  latestFetchedBlock: blockNumberAndTimestamp,
  contractAddressMapping: ContractAddressingMap.mapping,
  //Events ordered from latest to earliest
  fetchedEventQueue: array<Internal.eventItem>,
  //Used to prune dynamic contract registrations in the event
  //of a rollback.
  dynamicContracts: DynamicContractsMap.t,
  firstEventBlockNumber: option<int>,
}

type dynamicContractRegistration = {
  registeringEventBlockNumber: int,
  registeringEventLogIndex: int,
  registeringEventChain: ChainMap.Chain.t,
  dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>,
}

type t = {
  partitionId: int,
  // How many times the fetch has been executed with a response
  // Needed as idempotency key to sync the immutable state with immutable SourceManager
  responseCount: int,
  registers: array<register>,
  pendingDynamicContracts: array<dynamicContractRegistration>,
  isFetchingAtHead: bool,
  // Fields computed by updateInternal
  mostBehindRegister: register,
  nextMostBehindRegister: option<register>,
}

let shallowCopyRegister = (register: register) => {
  ...register,
  fetchedEventQueue: register.fetchedEventQueue->Array.copy,
}

let copy = (self: t) => {
  let pendingDynamicContracts = self.pendingDynamicContracts->Array.copy
  let registers = self.registers->Array.map(shallowCopyRegister)
  {
    partitionId: self.partitionId,
    responseCount: self.responseCount,
    registers,
    // Must use the reference to copied value, so we use find
    mostBehindRegister: registers
    ->Js.Array2.find(r => r.id == self.mostBehindRegister.id)
    ->Option.getExn,
    nextMostBehindRegister: switch self.nextMostBehindRegister {
    | Some(nextMostBehindRegister) =>
      registers->Js.Array2.find(r => r.id == nextMostBehindRegister.id)->Option.getExn->Some
    | None => None
    },
    pendingDynamicContracts,
    isFetchingAtHead: self.isFetchingAtHead,
  }
}

let isRegisterBehind = (r1, r2: register) =>
  r1.latestFetchedBlock.blockNumber < r2.latestFetchedBlock.blockNumber

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

let mergeWithNextRegister = (register: register, ~next: register) => {
  let fetchedEventQueue = mergeSortedEventList(register.fetchedEventQueue, next.fetchedEventQueue)
  let contractAddressMapping = ContractAddressingMap.combine(
    register.contractAddressMapping,
    next.contractAddressMapping,
  )

  let dynamicContracts = DynamicContractsMap.merge(register.dynamicContracts, next.dynamicContracts)

  if register.latestFetchedBlock.blockNumber !== next.latestFetchedBlock.blockNumber {
    Js.Exn.raiseError("Invalid state: Merged registers should belong to the same block")
  }

  {
    id: next.id,
    fetchedEventQueue,
    contractAddressMapping,
    dynamicContracts,
    firstEventBlockNumber: Utils.Math.minOptInt(
      register.firstEventBlockNumber,
      next.firstEventBlockNumber,
    ),
    latestFetchedBlock: next.latestFetchedBlock,
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
  let firstEventBlockNumber = switch register.firstEventBlockNumber {
  | Some(n) => Some(n)
  | None => reversedNewItems->Utils.Array.last->Option.map(v => v.blockNumber)
  }
  {
    ...register,
    latestFetchedBlock,
    firstEventBlockNumber,
    fetchedEventQueue: Array.concat(reversedNewItems, register.fetchedEventQueue),
  }
}

let makeDynamicContractRegister = (
  ~registeringEventBlockNumber,
  ~registeringEventLogIndex,
  ~dynamicContractRegistrations: array<TablesStatic.DynamicContractRegistry.t>,
) => {
  let id: dynamicContractId = {
    blockNumber: registeringEventBlockNumber,
    logIndex: registeringEventLogIndex,
  }

  let contractAddressMapping =
    dynamicContractRegistrations
    ->Array.map(d => (d.contractAddress, (d.contractType :> string)))
    ->ContractAddressingMap.fromArray

  let dynamicContracts =
    DynamicContractsMap.empty->DynamicContractsMap.add(
      id,
      contractAddressMapping->ContractAddressingMap.getAllAddresses,
    )

  {
    id: makeDynamicContractRegisterId(id),
    latestFetchedBlock: {
      blockNumber: Pervasives.max(registeringEventBlockNumber - 1, 0),
      blockTimestamp: 0,
    },
    contractAddressMapping,
    dynamicContracts,
    fetchedEventQueue: [],
    firstEventBlockNumber: None,
  }
}

/*
 Update fetchState, merge registers and recompute derived values
 */
let updateInternal = (
  fetchState: t,
  ~registers=fetchState.registers,
  ~pendingDynamicContracts=fetchState.pendingDynamicContracts,
  ~isFetchingAtHead=fetchState.isFetchingAtHead,
  ~responseCount=fetchState.responseCount,
): t => {
  let registerByLatestBlock = Js.Dict.empty()
  let add = register => {
    let key = register.latestFetchedBlock.blockNumber->Js.Int.toString
    let mergedRegister = switch registerByLatestBlock->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(next) => register->mergeWithNextRegister(~next)
    | None => register
    }
    registerByLatestBlock->Js.Dict.set(key, mergedRegister)
  }
  registers->Array.forEach(add)
  let registers = registerByLatestBlock->Js.Dict.values
  {
    partitionId: fetchState.partitionId,
    responseCount,
    pendingDynamicContracts,
    // Js automatically sorts numeric dict keys
    mostBehindRegister: registers->Js.Array2.unsafe_get(0),
    nextMostBehindRegister: registers->Belt.Array.get(1),
    registers,
    isFetchingAtHead,
  }
}

/*
Adds a new dynamic contract registration. It appends the registration to the pending dynamic
contract registrations. These pending registrations are applied to the base register when next
query is called.
*/
let registerDynamicContract = (
  fetchState: t,
  registration: dynamicContractRegistration,
  ~isFetchingAtHead,
) => {
  {
    ...fetchState,
    pendingDynamicContracts: fetchState.pendingDynamicContracts->Array.concat([registration]),
    isFetchingAtHead,
  }
}

type partitionQuery = {
  fetchStateRegisterId: id,
  idempotencyKey: int,
  //used to id the partition of the fetchstate
  partitionId: int,
  fromBlock: int,
  toBlock: option<int>,
  contractAddressMapping: ContractAddressingMap.mapping,
}

type mergeQuery = {
  idempotencyKey: int,
  partitionId: int,
  toBlock: int,
  pendingDynamicContracts: array<dynamicContractRegistration>,
}

type query =
  | PartitionQuery(partitionQuery)
  | MergeQuery(mergeQuery)

exception UnexpectedRegisterDoesNotExist(id)
exception UnexpectedMergeQueryResponse({message: string})

/*
Updates node at given id with given values and checks to see if it can be merged into its next register.
Returns Error if the node with given id cannot be found (unexpected)

newItems are ordered earliest to latest (as they are returned from the worker)
*/
let setQueryResponse = (
  fetchState: t,
  ~query: query,
  ~latestFetchedBlock: blockNumberAndTimestamp,
  ~newItems,
  ~currentBlockHeight,
): result<t, exn> => {
  switch query {
  | PartitionQuery({fetchStateRegisterId}) =>
    switch fetchState.registers->Array.getIndexBy(r => r.id == fetchStateRegisterId) {
    | Some(registerIdx) =>
      Ok(
        fetchState.registers->Utils.Array.setIndexImmutable(
          registerIdx,
          fetchState.registers
          ->Array.getUnsafe(registerIdx)
          ->updateRegister(~latestFetchedBlock, ~reversedNewItems=newItems->Array.reverse),
        ),
      )
    | None => Error(UnexpectedRegisterDoesNotExist(fetchStateRegisterId))
    }

  | MergeQuery({toBlock}) =>
    if toBlock !== latestFetchedBlock.blockNumber {
      Error(
        UnexpectedMergeQueryResponse({
          message: `The expected to block ${toBlock->Int.toString} of a Merge Query doesn't match the latest fetched block number ${latestFetchedBlock.blockNumber->Int.toString}.`,
        }),
      )
    } else {
      switch fetchState.registers->Array.getIndexBy(r =>
        r.latestFetchedBlock.blockNumber === toBlock
      ) {
      | Some(registerIdx) =>
        Ok(
          fetchState.registers->Utils.Array.setIndexImmutable(
            registerIdx,
            fetchState.registers
            ->Array.getUnsafe(registerIdx)
            ->updateRegister(~latestFetchedBlock, ~reversedNewItems=newItems->Array.reverse),
          ),
        )
      | None =>
        Error(UnexpectedRegisterDoesNotExist(`For Merge Query to block ${toBlock->Int.toString}`))
      }
    }
  }->Result.map(registers => {
    let pendingDynamicContracts = switch query {
    | PartitionQuery(_) => fetchState.pendingDynamicContracts
    | MergeQuery({toBlock, pendingDynamicContracts: queryDynamicContracts}) => {
        queryDynamicContracts->Array.forEach(dc => {
          let wasFilteredOutFromExecution = dc.registeringEventBlockNumber > toBlock
          if wasFilteredOutFromExecution {
            // Fine to push, since registers were cloned at this point by setIndexImmutable
            registers->Array.push(
              makeDynamicContractRegister(
                ~registeringEventBlockNumber=dc.registeringEventBlockNumber,
                ~registeringEventLogIndex=dc.registeringEventLogIndex,
                ~dynamicContractRegistrations=dc.dynamicContracts,
              ),
            )
          }
        })

        fetchState.pendingDynamicContracts->Array.sliceToEnd(queryDynamicContracts->Array.length)
      }
    }

    fetchState->updateInternal(
      ~registers,
      ~pendingDynamicContracts,
      ~responseCount=fetchState.responseCount + 1,
      ~isFetchingAtHead=fetchState.isFetchingAtHead ||
      currentBlockHeight <= latestFetchedBlock.blockNumber,
    )
  })
}

let makePartitionQuery = (register, ~idempotencyKey, ~partitionId, ~endBlock, ~nextRegister) => {
  let fromBlock = switch register.latestFetchedBlock.blockNumber {
  | 0 => 0
  | latestFetchedBlockNumber => latestFetchedBlockNumber + 1
  }
  switch endBlock {
  | Some(endBlock) if fromBlock > endBlock => None
  | _ =>
    Some(
      PartitionQuery({
        idempotencyKey,
        partitionId,
        fetchStateRegisterId: register.id,
        fromBlock,
        toBlock: Utils.Math.minOptInt(
          nextRegister->Option.map(r => r.latestFetchedBlock.blockNumber),
          endBlock,
        ),
        contractAddressMapping: register.contractAddressMapping,
      }),
    )
  }
}

/**
Gets the next query either with a to block
to catch up to another registery or without endBlock if all registries are merged
*/
let getNextQuery = (
  {
    partitionId,
    mostBehindRegister,
    nextMostBehindRegister,
    responseCount,
    pendingDynamicContracts,
  }: t,
  ~endBlock,
) => {
  switch pendingDynamicContracts {
  | [] =>
    mostBehindRegister->makePartitionQuery(
      ~partitionId,
      ~idempotencyKey=responseCount,
      ~endBlock,
      ~nextRegister=nextMostBehindRegister,
    )
  | _ =>
    Some(
      MergeQuery({
        partitionId,
        idempotencyKey: responseCount,
        toBlock: mostBehindRegister.latestFetchedBlock.blockNumber,
        pendingDynamicContracts,
      }),
    )
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
  let earliestItemInRegisters = switch fetchState.registers {
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

  if fetchState.pendingDynamicContracts->Utils.Array.isEmpty {
    //In the case where there are no pending dynamic contracts, return the earliest item
    //from the registers
    earliestItemInRegisters
  } else {
    //In the case where there are pending dynamic contracts, construct the earliest queue item from
    //the pending dynamic contracts
    let earliestPendingDynamicContractBlockNumber =
      fetchState.pendingDynamicContracts->Array.reduce(
        (fetchState.pendingDynamicContracts->Js.Array2.unsafe_get(0)).registeringEventBlockNumber,
        (accumBlockNumber, dynamicContractRegistration) => {
          min(accumBlockNumber, dynamicContractRegistration.registeringEventBlockNumber)
        },
      )

    let earliestItemInPendingDynamicContracts = NoItem({
      blockTimestamp: 0,
      blockNumber: Pervasives.max(earliestPendingDynamicContractBlockNumber - 1, 0),
    })

    //Compare the earliest item in the pending dynamic contracts with the earliest item in the registers
    earliestItemInPendingDynamicContracts->qItemLt(earliestItemInRegisters)
      ? earliestItemInPendingDynamicContracts
      : earliestItemInRegisters
  }
}

/**
Instantiates a fetch state with root register
*/
let make = (
  ~partitionId,
  ~staticContracts,
  ~dynamicContractRegistrations: array<TablesStatic.DynamicContractRegistry.t>,
  ~startBlock,
  ~isFetchingAtHead,
  ~logger as _,
): t => {
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

  let rootRegister = {
    id: rootRegisterId,
    latestFetchedBlock: {
      blockTimestamp: 0,
      // Here's a bug that startBlock: 1 won't work
      blockNumber: Pervasives.max(startBlock - 1, 0),
    },
    contractAddressMapping,
    dynamicContracts,
    fetchedEventQueue: [],
    firstEventBlockNumber: None,
  }

  {
    partitionId,
    responseCount: 0,
    registers: [rootRegister],
    mostBehindRegister: rootRegister,
    nextMostBehindRegister: None,
    pendingDynamicContracts: [],
    isFetchingAtHead,
  }
}

/**
Calculates the cummulative queue sizes in all registers
*/
let queueSize = ({registers}: t) => {
  let size = ref(0)
  for idx in 0 to registers->Js.Array2.length - 1 {
    let register = registers->Js.Array2.unsafe_get(idx)
    size := size.contents + register.fetchedEventQueue->Array.length
  }
  size.contents
}

/**
Check the max queue size of the tip of the tree.

Don't use the cummulative queue sizes because otherwise there
could be a deadlock. With a very small buffer size of the actively
fetching registration
 
If there are pending dynamic contracts, we always need to allow the next query
*/
let isReadyForNextQuery = ({pendingDynamicContracts} as fetchState: t, ~maxQueueSize) =>
  pendingDynamicContracts->Utils.Array.isEmpty
    ? fetchState.mostBehindRegister.fetchedEventQueue->Array.length < maxQueueSize
    : true

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
  }) ||
    self.pendingDynamicContracts->Array.some(({dynamicContracts}) =>
      dynamicContracts->Array.some(dcr => {
        let exists = dcr.contractAddress == contractAddress
        if exists {
          warnIfAttemptedAddressRegisterOnDifferentContracts(
            ~contractAddress,
            ~contractName,
            ~existingContractName=(dcr.contractType :> string),
            ~chainId,
          )
        }
        exists
      })
    )
}

/**
* Returns the latest block number fetched for the lowest fetcher queue (ie the earliest un-fetched dynamic contract)
*/
let getLatestFullyFetchedBlock = ({mostBehindRegister, pendingDynamicContracts}: t) => {
  let latestFullyFetchedBlock = ref(mostBehindRegister.latestFetchedBlock)

  //Consider pending dynamic contracts when calculating the latest fully fetched block
  //Since they are now registered lazily on query or update of the fetchstate, not when
  //the register function is called
  pendingDynamicContracts->Js.Array2.forEach(contract => {
    let {registeringEventBlockNumber} = contract
    let contractLatestFullyFetchedBlockNumber = Pervasives.max(registeringEventBlockNumber - 1, 0)
    if contractLatestFullyFetchedBlockNumber < latestFullyFetchedBlock.contents.blockNumber {
      latestFullyFetchedBlock := {
          blockNumber: contractLatestFullyFetchedBlockNumber,
          blockTimestamp: 0,
        }
    }
  })

  latestFullyFetchedBlock.contents
}

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
  let registers =
    fetchState.registers->Array.keepMap(r =>
      r->rollbackRegister(~lastScannedBlock, ~firstChangeEvent)
    )

  let pendingDynamicContracts =
    fetchState.pendingDynamicContracts->Array.keep(({
      registeringEventBlockNumber,
      registeringEventLogIndex,
    }) =>
      (registeringEventBlockNumber, registeringEventLogIndex) <
      (firstChangeEvent.blockNumber, firstChangeEvent.logIndex)
    )

  fetchState->updateInternal(~pendingDynamicContracts, ~registers)
}

/**
* Returns a boolean indicating whether the fetch state is actively indexing
* used for comparing event queues in the chain manager
*/
let isActivelyIndexing = (
  {mostBehindRegister, pendingDynamicContracts} as fetchState: t,
  ~endBlock,
) => {
  if pendingDynamicContracts->Utils.Array.isEmpty {
    switch endBlock {
    | Some(endBlock) =>
      let isPastEndblock = mostBehindRegister.latestFetchedBlock.blockNumber >= endBlock
      if isPastEndblock {
        fetchState->queueSize > 0
      } else {
        true
      }
    | None => true
    }
  } else {
    true
  }
}

// FIXME: Should include pending contracts?
let getNumContracts = ({registers}: t) => {
  let sum = ref(0)
  for idx in 0 to registers->Js.Array2.length - 1 {
    let register = registers->Js.Array2.unsafe_get(idx)
    sum := sum.contents + register.contractAddressMapping->ContractAddressingMap.addressCount
  }
  sum.contents
}
