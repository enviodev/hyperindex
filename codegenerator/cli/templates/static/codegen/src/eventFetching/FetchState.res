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

  let add = (self, id, addressesArr: array<Ethers.ethAddress>) => {
    self->Belt.Map.set(id, addressesArr->Utils.magic->Belt.Set.String.fromArray)
  }

  let addAddress = (self: t, id, address: Ethers.ethAddress) => {
    let addressStr = address->Ethers.ethAddressToString
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

  let removeContractAddressesPastValidBlock = (self: t, ~lastKnownValidBlock) => {
    self
    ->Map.toArray
    ->Array.reduce((empty, []), ((currentMap, currentRemovedAddresses), (nextKey, nextVal)) => {
      if nextKey.blockNumber > lastKnownValidBlock.blockNumber {
        //If the registration block is greater than the last valid block,
        //Do not add it to the currentMap, but add the removed addresses
        let updatedRemovedAddresses =
          currentRemovedAddresses->Array.concat(
            nextVal->Set.String.toArray->ContractAddressingMap.stringsToAddresses,
          )
        (currentMap, updatedRemovedAddresses)
      } else {
        //If it is not passed the lastKnownValidBlock, updated the
        //current map and keep the currentRemovedAddresses
        let updatedMap = currentMap->Map.set(nextKey, nextVal)
        (updatedMap, currentRemovedAddresses)
      }
    })
  }
}

/**
A state that holds a queue of events and data regarding what to fetch next.
If there are dynamic contracts currently catching up to the root register,
this the register field will hold "DynamicContractRegister" with id of the registering
contract and either the root register or a chain of "DynamicContractRegisters" ordered
from earliest registering event to latest with the RootRegister at the end of the chain.

As one dynamic contract register catches up to the fetched blocknumebr of the next, it will
merge itself into the next register and combine queries/addresses and queues until fully caught
up to the root. 
*/
type rec t = {
  registerType: register,
  latestFetchedBlock: blockNumberAndTimestamp,
  contractAddressMapping: ContractAddressingMap.mapping,
  fetchedEventQueue: array<Types.eventBatchQueueItem>,
  //Used to prune dynamic contract registrations in the event
  //of a rollback.
  dynamicContracts: DynamicContractsMap.t,
  isFetchingAtHead: bool,
  firstEventBlockNumber: option<int>,
}
and register = RootRegister({endBlock: option<int>}) | DynamicContractRegister(dynamicContractId, t)

/**
Comapritor for two events from the same chain. No need for chain id or timestamp
*/
let getEventCmp = (event: Types.eventBatchQueueItem) => {
  (event.blockNumber, event.logIndex)
}

/**
Returns the earliest of two events on the same chain
*/
let eventCmp = (a, b) => a->getEventCmp <= b->getEventCmp

/**
Merges two event queues on a single event fetcher

Pass the shorter list into A for better performance
*/
let mergeSortedEventList = (a, b) => Utils.Array.mergeSorted(eventCmp, a, b)

/**
Merges a node into its next registered branch. Combines contract address mappings and queues
*/
let mergeIntoNextRegistered = (self: t) => {
  switch self.registerType {
  | DynamicContractRegister(_id, nextRegistered) =>
    let fetchedEventQueue = mergeSortedEventList(
      self.fetchedEventQueue,
      nextRegistered.fetchedEventQueue,
    )
    let contractAddressMapping = ContractAddressingMap.combine(
      self.contractAddressMapping,
      nextRegistered.contractAddressMapping,
    )

    let dynamicContracts = DynamicContractsMap.merge(
      self.dynamicContracts,
      nextRegistered.dynamicContracts,
    )

    {
      isFetchingAtHead: nextRegistered.isFetchingAtHead,
      registerType: nextRegistered.registerType,
      fetchedEventQueue,
      contractAddressMapping,
      dynamicContracts,
      firstEventBlockNumber: Utils.Math.minOptInt(
        self.firstEventBlockNumber,
        nextRegistered.firstEventBlockNumber,
      ),
      latestFetchedBlock: {
        blockTimestamp: Pervasives.max(
          self.latestFetchedBlock.blockTimestamp,
          nextRegistered.latestFetchedBlock.blockTimestamp,
        ),
        blockNumber: Pervasives.max(
          self.latestFetchedBlock.blockNumber,
          nextRegistered.latestFetchedBlock.blockNumber,
        ),
      },
    }
  | RootRegister(_) => self //already merged
  }
}

/**
An id for a given register. Either the root or a dynamic contract register
with a dynamicContractId
*/
type id = Root | DynamicContract(dynamicContractId)

/**
Constructs id from a register
*/
let getRegisterId = (self: t) => {
  switch self.registerType {
  | RootRegister(_) => Root
  | DynamicContractRegister(id, _) => DynamicContract(id)
  }
}

exception UnexpectedRegisterDoesNotExist(id)

/**
Updates a given register with new latest block values and new fetched
events.
*/
let updateRegister = (
  self: t,
  ~latestFetchedBlock,
  ~newFetchedEvents: array<Types.eventBatchQueueItem>,
  ~isFetchingAtHead,
) => {
  let firstEventBlockNumber = switch self.firstEventBlockNumber {
  | Some(n) => Some(n)
  | None => newFetchedEvents[0]->Option.map(v => v.blockNumber)
  }
  {
    ...self,
    isFetchingAtHead,
    latestFetchedBlock,
    firstEventBlockNumber,
    fetchedEventQueue: Array.concat(self.fetchedEventQueue, newFetchedEvents),
  }
}

/**
Links next register to a dynamic contract register
*/
let addNextRegister = (nextRegister: t, ~register: t, ~dynamicContractId) => {
  ...register,
  registerType: DynamicContractRegister(dynamicContractId, nextRegister),
}

type parentRegister = {
  register: t,
  dynamicContractId: dynamicContractId,
}

/**
Updates node at the given id with the values passed.
Errors if the node can't be found.
*/
let rec updateInternal = (
  register: t,
  ~id,
  ~latestFetchedBlock,
  ~newFetchedEvents,
  ~isFetchingAtHead,
  ~parentRegister=?,
): result<t, exn> => {
  let handleParent = (updated: t) => {
    switch parentRegister {
    | Some({register, dynamicContractId}) =>
      updated->addNextRegister(~register, ~dynamicContractId)->Ok
    | None => updated->Ok
    }
  }

  switch (register.registerType, id) {
  | (RootRegister(_), Root) =>
    register
    ->updateRegister(~newFetchedEvents, ~latestFetchedBlock, ~isFetchingAtHead)
    ->handleParent
  | (DynamicContractRegister(id, _nextRegistered), DynamicContract(targetId)) if id == targetId =>
    register
    ->updateRegister(~newFetchedEvents, ~latestFetchedBlock, ~isFetchingAtHead)
    ->handleParent
  | (DynamicContractRegister(dynamicContractId, nextRegistered), id) =>
    nextRegistered->updateInternal(
      ~id,
      ~latestFetchedBlock,
      ~newFetchedEvents,
      ~isFetchingAtHead,
      ~parentRegister={register, dynamicContractId},
    )
  | (RootRegister(_), DynamicContract(_)) => Error(UnexpectedRegisterDoesNotExist(id))
  }
}

/**
If a fetchState register has caught up to its next regisered node. Merge them and recurse.
If no merging happens, None is returned
*/
let rec pruneAndMergeNextRegistered = (self: t, ~parentRegister=?) => {
  switch self.registerType {
  | RootRegister(_) => parentRegister
  | DynamicContractRegister(_, nextRegister)
    if self.latestFetchedBlock.blockNumber <
    nextRegister.latestFetchedBlock.blockNumber => parentRegister
  | DynamicContractRegister(_) =>
    let mergedSelf = self->mergeIntoNextRegistered

    // Recursively look for other merges, if they affect the state, return that merged state otherwise, return the `mergedSelf`
    mergedSelf->pruneAndMergeNextRegistered
  }
}

/**
Updates node at given id with given values and checks to see if it can be merged into its next register.
Returns Error if the node with given id cannot be found (unexpected)
*/
let update = (self: t, ~id, ~latestFetchedBlock, ~fetchedEvents, ~currentBlockHeight): result<
  t,
  exn,
> => {
  let isFetchingAtHead =
    currentBlockHeight <= latestFetchedBlock.blockNumber ? true : self.isFetchingAtHead
  self
  ->updateInternal(~id, ~latestFetchedBlock, ~newFetchedEvents=fetchedEvents, ~isFetchingAtHead)
  ->Result.map(result => pruneAndMergeNextRegistered(result)->Option.getWithDefault(result))
}

//A filter should return true if the event should be kept and isValid should return
//false when the filter should be removed/cleaned up
type eventFilter = {
  filter: Types.eventBatchQueueItem => bool,
  isValid: (~fetchState: t, ~chain: ChainMap.Chain.t) => bool,
}

type eventFilters = list<eventFilter>
let applyFilters = (eventBatchQueueItem, ~eventFilters) =>
  eventFilters->List.reduce(true, (acc, eventFilter) =>
    acc && eventBatchQueueItem->eventFilter.filter
  )

type nextQuery = {
  fetchStateRegisterId: id,
  //used to id the partition of the fetchstate
  partitionId: int,
  fromBlock: int,
  toBlock: int,
  contractAddressMapping: ContractAddressingMap.mapping,
  //Used to filter events where its not possible to filter in the query
  //eg. event should be above a logIndex in a block or above a timestamp
  eventFilters?: eventFilters,
}

let getQueryLogger = (
  {fetchStateRegisterId, fromBlock, toBlock, contractAddressMapping}: nextQuery,
  ~logger,
) => {
  let fetchStateRegister = switch fetchStateRegisterId {
  | Root => "root"
  | DynamicContract({blockNumber, logIndex}) =>
    `dynamic-${blockNumber->Int.toString}-${logIndex->Int.toString}`
  }
  let addressesAll = contractAddressMapping->ContractAddressingMap.getAllAddresses
  let (displayAddr, restCount) = addressesAll->Array.reduce(([], 0), (
    (currentDisplay, restCount),
    addr,
  ) => {
    if currentDisplay->Array.length < 3 {
      (Array.concat(currentDisplay, [addr->Ethers.ethAddressToString]), restCount)
    } else {
      (currentDisplay, restCount + 1)
    }
  })

  let addresses = if restCount > 0 {
    displayAddr->Array.concat([`... and ${restCount->Int.toString} more`])
  } else {
    displayAddr
  }
  let params = {
    "fromBlock": fromBlock,
    "toBlock": toBlock,
    "addresses": addresses,
    "fetchStateRegister": fetchStateRegister,
  }
  Logging.createChildFrom(~logger, ~params)
}

let minOfOption: (int, option<int>) => int = (a: int, b: option<int>) => {
  switch (a, b) {
  | (a, Some(b)) => min(a, b)
  | (a, None) => a
  }
}

/**
Constructs `nextQuery` from a given node
*/
let getNextQueryFromNode = (
  {registerType, latestFetchedBlock, contractAddressMapping}: t,
  ~toBlock,
  ~eventFilters,
  ~partitionId,
) => {
  let (id, endBlock) = switch registerType {
  | RootRegister({endBlock}) => (Root, endBlock)
  | DynamicContractRegister(id, _) => (DynamicContract(id), None)
  }
  let fromBlock = switch latestFetchedBlock.blockNumber {
  | 0 => 0
  | latestFetchedBlockNumber => latestFetchedBlockNumber + 1
  }
  let toBlock = minOfOption(toBlock, endBlock)
  {
    partitionId,
    fetchStateRegisterId: id,
    fromBlock,
    toBlock,
    contractAddressMapping,
    ?eventFilters,
  }
}

type nextQueryOrWaitForBlock =
  | NextQuery(nextQuery)
  | WaitForNewBlock
  | Done

exception FromBlockIsHigherThanToBlock(int, int) //from and to block respectively

let isGreaterThanOpt: (int, option<int>) => bool = (a: int, b: option<int>) => {
  switch b {
  | Some(b) => a > b
  | None => false
  }
}

let rec getEndBlock = (self: t) => {
  switch self.registerType {
  | RootRegister({endBlock}) => endBlock
  | DynamicContractRegister(_, nextRegister) => nextRegister->getEndBlock
  }
}

/**
Gets the next query either with a to block of the current height if it is the root node.
Or with a toBlock of the nextRegistered latestBlockNumber to catch up and merge with the next regisetered.

Errors if nextRegistered dynamic contract has a lower latestFetchedBlock than the current as this would be
an invalid state.
*/
let getNextQuery = (~eventFilters=?, ~currentBlockHeight, ~partitionId, self: t) => {
  let maybeMerged = self->pruneAndMergeNextRegistered
  let self = maybeMerged->Option.getWithDefault(self)

  let nextQuery = switch self.registerType {
  | RootRegister({endBlock}) =>
    self->getNextQueryFromNode(
      ~toBlock={minOfOption(currentBlockHeight, endBlock)},
      ~eventFilters,
      ~partitionId,
    )
  | DynamicContractRegister(_, {latestFetchedBlock}) =>
    self->getNextQueryFromNode(~toBlock=latestFetchedBlock.blockNumber, ~eventFilters, ~partitionId)
  }

  switch nextQuery {
  | {fromBlock} if fromBlock > currentBlockHeight || currentBlockHeight == 0 =>
    (WaitForNewBlock, maybeMerged)->Ok
  | {fromBlock, toBlock} if fromBlock <= toBlock => (NextQuery(nextQuery), maybeMerged)->Ok
  | {fromBlock} if fromBlock->isGreaterThanOpt(getEndBlock(self)) => (Done, maybeMerged)->Ok
  //This is an invalid case. We should never arrive at this match arm but it would be
  //detrimental if it were the case.
  | {fromBlock, toBlock} => Error(FromBlockIsHigherThanToBlock(fromBlock, toBlock))
  }
}

/**
Represents a fetchState registers head of the  fetchedEventQueue as either
an existing item, or no item with latest fetched block data
*/
type queueItem =
  | Item(Types.eventBatchQueueItem)
  | NoItem(blockNumberAndTimestamp)

/**
Creates a compareable value for items and no items on register queues.
Block number takes priority here. Since a latest fetched timestamp could
be zero from initialization of register but a higher latest fetched block number exists

Note: on the chain manager, when comparing multi chain, the timestamp is the highest priority compare value
*/
let getCmpVal = qItem =>
  switch qItem {
  | Item({blockNumber, logIndex}) => (blockNumber, logIndex)
  | NoItem({blockNumber}) => (blockNumber, 0)
  }

/**
Simple constructor for no item from register
*/
let makeNoItem = ({latestFetchedBlock}: t) => NoItem(latestFetchedBlock)

let qItemLt = (a, b) => a->getCmpVal < b->getCmpVal

type earliestEventResponse = {
  //make this lazy to prevent extra array duplications
  //before evaluation of earliestQueueItem
  getUpdatedFetchState: unit => t,
  earliestQueueItem: queueItem,
}

/**
Returns queue item WITHOUT the updated fetch state. Used for checking values
not updating state
*/
let getEarliestEventInRegister = (self: t) => {
  switch self.fetchedEventQueue[0] {
  | Some(head) => Item(head)
  | None => makeNoItem(self)
  }
}

/**
Returns queue item WITH the updated fetch state. 
*/
let getEarliestEventInRegisterWithUpdatedQueue = (self: t) => {
  let (getUpdatedFetchState, earliestQueueItem) = switch self.fetchedEventQueue[0] {
  | None => (() => self, makeNoItem(self))
  | Some(head) => (
      () => {...self, fetchedEventQueue: self.fetchedEventQueue->Array.sliceToEnd(1)},
      Item(head),
    )
  }

  {getUpdatedFetchState, earliestQueueItem}
}

/**
Recurses through all registers and finds the register with the earliest queue item,
then returns its id.
*/
let rec findRegisterIdWithEarliestQueueItem = (~currentEarliestRegister=?, self: t) => {
  let currentEarliestRegister = switch currentEarliestRegister {
  | None => self
  | Some(currentEarliestRegister) =>
    if (
      self->getEarliestEventInRegister->qItemLt(currentEarliestRegister->getEarliestEventInRegister)
    ) {
      self
    } else {
      currentEarliestRegister
    }
  }

  switch self.registerType {
  | RootRegister(_) => currentEarliestRegister->getRegisterId
  | DynamicContractRegister(_, nextRegister) =>
    nextRegister->findRegisterIdWithEarliestQueueItem(~currentEarliestRegister)
  }
}

/**
Helper function, adding an updated child register to the current dynamic
contract register
*/
let getRegisterWithNextResponse = (
  register: t,
  ~dynamicContractId,
  {getUpdatedFetchState, earliestQueueItem},
) => {
  {
    getUpdatedFetchState: () =>
      getUpdatedFetchState()->addNextRegister(~register, ~dynamicContractId),
    earliestQueueItem,
  }
}

/**
Given a register id, pop a queue item off of that register and return the entire updated
fetch state with that item.

Recurses through registers and Errors if ID does not exist
*/
let rec popQItemAtRegisterId = (self: t, ~id, ~parentRegister=?) => {
  switch self.registerType {
  | RootRegister(_)
  | DynamicContractRegister(_) if id == self->getRegisterId =>
    let updated = self->getEarliestEventInRegisterWithUpdatedQueue
    switch parentRegister {
    | Some({register, dynamicContractId}) =>
      register->getRegisterWithNextResponse(~dynamicContractId, updated)->Ok
    | None => Ok(updated)
    }
  | DynamicContractRegister(dynamicContractId, nextRegister) =>
    nextRegister->popQItemAtRegisterId(~id, ~parentRegister={register: self, dynamicContractId})
  | RootRegister(_) => Error(UnexpectedRegisterDoesNotExist(id))
  }
}

/**
Gets the earliest queueItem from thgetNodeEarliestEventWithUpdatedQueue.

Finds the earliest queue item across all registers and then returns that
queue item with an update fetch state.
*/
let getEarliestEvent = (self: t) => {
  let registerWithEarliestQItem = self->findRegisterIdWithEarliestQueueItem
  //Can safely unwrap here since the id is returned from self and so is guarenteed to exist
  self->popQItemAtRegisterId(~id=registerWithEarliestQItem)->Utils.unwrapResultExn
}

let makeInternal = (
  ~registerType,
  ~staticContracts,
  ~dynamicContractRegistrations: array<DbFunctions.DynamicContractRegistry.contractTypeAndAddress>,
  ~startBlock,
  ~isFetchingAtHead,
  ~logger,
): t => {
  let contractAddressMapping = ContractAddressingMap.make()

  staticContracts->Belt.Array.forEach(((contractName, address)) => {
    Logging.childTrace(
      logger,
      {
        "msg": "adding contract address",
        "contractName": contractName,
        "address": address,
      },
    )

    contractAddressMapping->ContractAddressingMap.addAddress(~name=contractName, ~address)
  })

  let dynamicContracts = dynamicContractRegistrations->Array.reduce(DynamicContractsMap.empty, (
    accum,
    {contractType, contractAddress, eventId},
  ) => {
    //add address to contract address mapping
    contractAddressMapping->ContractAddressingMap.addAddress(
      ~name=(contractType :> string),
      ~address=contractAddress,
    )

    let dynamicContractId = EventUtils.unpackEventIndex(eventId)

    accum->DynamicContractsMap.addAddress(dynamicContractId, contractAddress)
  })

  {
    isFetchingAtHead,
    registerType,
    latestFetchedBlock: {
      blockTimestamp: 0,
      blockNumber: Pervasives.max(startBlock - 1, 0),
    },
    contractAddressMapping,
    dynamicContracts,
    fetchedEventQueue: [],
    firstEventBlockNumber: None,
  }
}

/**
Instantiates a fetch state with root register
*/
let makeRoot = (~endBlock) => makeInternal(~registerType=RootRegister({endBlock: endBlock}), ...)

/**
Inserts a dynamic contract register to the head of a given
register. It will then precede the given register in the chain
*/
let addNewRegisterToHead = (
  self,
  ~registeringEventBlockNumber,
  ~registeringEventLogIndex,
  ~contractAddressMapping,
) => {
  let id: dynamicContractId = {
    blockNumber: registeringEventBlockNumber,
    logIndex: registeringEventLogIndex,
  }
  let registerType = DynamicContractRegister(id, self)

  let dynamicContracts =
    DynamicContractsMap.empty->DynamicContractsMap.add(
      id,
      contractAddressMapping->ContractAddressingMap.getAllAddresses,
    )

  {
    isFetchingAtHead: false,
    registerType,
    latestFetchedBlock: {
      blockNumber: registeringEventBlockNumber - 1,
      blockTimestamp: 0,
    },
    contractAddressMapping,
    dynamicContracts,
    fetchedEventQueue: [],
    firstEventBlockNumber: None,
  }
}

/**
Adds a new dynamic contract registration. It inserts the registration ordered in the
chain from earliest registered contract to latest. So if this is being called on a batch
of registrations its best to do this in order of latest to earliest to reduce recursions
of this function.
*/
let rec registerDynamicContract = (
  register: t,
  ~registeringEventBlockNumber,
  ~registeringEventLogIndex,
  ~dynamicContractRegistrations: array<TablesStatic.DynamicContractRegistry.t>,
  ~parentRegister=?,
) => {
  let handleParent = updated =>
    switch parentRegister {
    | Some({register, dynamicContractId}) => updated->addNextRegister(~register, ~dynamicContractId)
    | None => updated
    }

  let addToHead = updated =>
    updated
    ->addNewRegisterToHead(
      ~contractAddressMapping=dynamicContractRegistrations
      ->Array.map(d => (d.contractAddress, (d.contractType :> string)))
      ->ContractAddressingMap.fromArray,
      ~registeringEventLogIndex,
      ~registeringEventBlockNumber,
    )
    ->handleParent

  let latestFetchedBlockNumber = registeringEventBlockNumber - 1

  switch register.registerType {
  | RootRegister(_) => register->addToHead
  | DynamicContractRegister(_)
    if latestFetchedBlockNumber <= register.latestFetchedBlock.blockNumber =>
    register->addToHead
  | DynamicContractRegister(dynamicContractId, nextRegister) =>
    nextRegister->registerDynamicContract(
      ~registeringEventBlockNumber,
      ~registeringEventLogIndex,
      ~dynamicContractRegistrations,
      ~parentRegister={register, dynamicContractId},
    )
  }
}

/**
Calculates the cummulative queue sizes in all registers
*/
let rec queueSize = (self: t, ~accum=0) => {
  let accum = self.fetchedEventQueue->Array.length + accum
  switch self.registerType {
  | RootRegister(_) => accum
  | DynamicContractRegister(_, nextRegister) => nextRegister->queueSize(~accum)
  }
}

/**
Check the max queue size of the tip of the tree.

Don't use the cummulative queue sizes because otherwise there
could be a deadlock. With a very small buffer size of the actively
fetching registration
*/
let isReadyForNextQuery = (self: t, ~maxQueueSize) =>
  self.fetchedEventQueue->Array.length < maxQueueSize

let rec getAllAddressesForContract = (~addresses=Set.String.empty, ~contractName, self: t) => {
  let addresses =
    self.contractAddressMapping
    ->ContractAddressingMap.getAddresses(contractName)
    ->Option.mapWithDefault(addresses, newAddresses => {
      addresses->Set.String.union(newAddresses)
    })

  switch self.registerType {
  | RootRegister(_) => addresses
  | DynamicContractRegister(_, nextRegister) =>
    nextRegister->getAllAddressesForContract(~addresses, ~contractName)
  }
}

/**
Recurses through registers and determines whether a contract has already been registered with
the given name and address
*/
let checkContainsRegisteredContractAddress = (self: t, ~contractName, ~contractAddress) => {
  let allAddr = self->getAllAddressesForContract(~contractName)
  allAddr->Set.String.has(
    contractAddress
    ->//run formatEthAddress to be sure that the address is checksummed
    Ethers.formatEthAddress
    ->Ethers.ethAddressToString,
  )
}

/**
* Returns the latest block number fetched for the lowest fetcher queue (ie the earliest un-fetched dynamic contract)
*/
let getLatestFullyFetchedBlock = (self: t) => self.latestFetchedBlock

let rec pruneQueuePastValidBlock = (
  queue: array<Types.eventBatchQueueItem>,
  ~index=0,
  ~accum=[],
  ~lastKnownValidBlock,
) => {
  switch queue[index] {
  | Some(head) if head.blockNumber <= lastKnownValidBlock.blockNumber =>
    let _ = accum->Js.Array2.push(head)
    queue->pruneQueuePastValidBlock(~lastKnownValidBlock, ~accum, ~index=index + 1)
  | _ => accum
  }
}

let pruneDynamicContractAddressesPastValidBlock = (~lastKnownValidBlock, register: t) => {
  //get all dynamic contract addresses past valid blockNumber to remove along with
  //updated dynamicContracts map
  let (dynamicContracts, addressesToRemove) =
    register.dynamicContracts->DynamicContractsMap.removeContractAddressesPastValidBlock(
      ~lastKnownValidBlock,
    )

  //remove them from the contract address mapping and dynamic contract addresses mapping
  let contractAddressMapping =
    register.contractAddressMapping->ContractAddressingMap.removeAddresses(~addressesToRemove)

  {...register, contractAddressMapping, dynamicContracts}
}

/**
Rolls back registers to the given valid block
*/
let rec rollback = (self: t, ~lastKnownValidBlock: blockNumberAndTimestamp, ~parentRegister=?) => {
  let handleParent = updated =>
    switch parentRegister {
    | Some({register, dynamicContractId}) => {
        ...register,
        registerType: DynamicContractRegister(dynamicContractId, updated),
      }
    | None => updated
    }

  switch self.registerType {
  //Case 1 Root register that has only fetched up to a confirmed valid block number
  //Should just return itself unchanged
  | RootRegister(_) if self.latestFetchedBlock.blockNumber <= lastKnownValidBlock.blockNumber =>
    self->handleParent
  //Case 2 Dynamic register that has only fetched up to a confirmed valid block number
  //Should just return itself, with the next register rolled back recursively
  | DynamicContractRegister(id, nextRegister)
    if self.latestFetchedBlock.blockNumber <= lastKnownValidBlock.blockNumber =>
    nextRegister->rollback(
      ~lastKnownValidBlock,
      ~parentRegister={register: self, dynamicContractId: id},
    )

  //Case 3 Root register that has fetched further than the confirmed valid block number
  //Should prune its queue and set its latest fetched block data to the latest known confirmed block
  | RootRegister(_) =>
    {
      ...self,
      fetchedEventQueue: self.fetchedEventQueue->pruneQueuePastValidBlock(~lastKnownValidBlock),
      latestFetchedBlock: lastKnownValidBlock,
    }
    ->pruneDynamicContractAddressesPastValidBlock(~lastKnownValidBlock)
    ->handleParent
  //Case 4 DynamicContract register that has fetched further than the confirmed valid block number
  //Should prune its queue, set its latest fetched blockdata + pruned queue
  //And recursivle prune the nextRegister
  | DynamicContractRegister(id, nextRegister) =>
    let updatedWithRemovedDynamicContracts =
      self->pruneDynamicContractAddressesPastValidBlock(~lastKnownValidBlock)

    if updatedWithRemovedDynamicContracts.contractAddressMapping->ContractAddressingMap.isEmpty {
      //If the contractAddressMapping is empty after pruning dynamic contracts, then this
      //is a dead register. Simly return its next register rolled back
      nextRegister->rollback(~lastKnownValidBlock)
    } else {
      //If there are still values in the contractAddressMapping, we should keep the register but
      //prune queues and next register
      let parentRegister = {
        register: {
          ...updatedWithRemovedDynamicContracts,
          fetchedEventQueue: self.fetchedEventQueue->pruneQueuePastValidBlock(~lastKnownValidBlock),
          latestFetchedBlock: lastKnownValidBlock,
        },
        dynamicContractId: id,
      }
      nextRegister->rollback(~lastKnownValidBlock, ~parentRegister)
    }
  }
}

/**
* Returns a boolean indicating whether the fetch state is actively indexing
* used for comparing event queues in the chain manager
*/
let isActivelyIndexing = fetchState => {
  // nesting to limit additional unnecessary computation
  switch fetchState.registerType {
  | RootRegister({endBlock: Some(endBlock)}) =>
    let isPastEndblock = fetchState.latestFetchedBlock.blockNumber >= endBlock
    if isPastEndblock {
      fetchState->queueSize > 0
    } else {
      true
    }
  | _ => true
  }
}

let getNumContracts = (self: t) => self.contractAddressMapping->ContractAddressingMap.addressCount

/**
Helper functions for debugging and printing
*/
module DebugHelpers = {
  let registerToString = register =>
    switch register {
    | RootRegister(_) => "root"
    | DynamicContractRegister({blockNumber, logIndex}, _) =>
      `DC-${blockNumber->Int.toString}-${logIndex->Int.toString}`
    }

  let rec getQueueSizesInternal = (self: t, ~accum) => {
    let next = (self.registerType->registerToString, self.fetchedEventQueue->Array.length)
    let accum = list{next, ...accum}
    switch self.registerType {
    | RootRegister(_) => accum
    | DynamicContractRegister(_, nextRegister) => nextRegister->getQueueSizesInternal(~accum)
    }
  }

  let getQueueSizes = (self: t) =>
    self->getQueueSizesInternal(~accum=list{})->List.toArray->Js.Dict.fromArray

  let rec numberRegistered = (~accum=0, self: t) => {
    let accum = accum + 1
    switch self.registerType {
    | RootRegister(_) => accum
    | DynamicContractRegister(_, nextRegister) => nextRegister->numberRegistered(~accum)
    }
  }
}
