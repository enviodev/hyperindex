open Belt

/**
The block number and log index of the event that registered a
dynamic contract
*/
type dynamicContractId = {
  blockNumber: int,
  logIndex: int,
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
  latestFetchedBlockTimestamp: int,
  latestFetchedBlockNumber: int,
  contractAddressMapping: ContractAddressingMap.mapping,
  fetchedEventQueue: list<Types.eventBatchQueueItem>,
}
and register = RootRegister | DynamicContractRegister(dynamicContractId, t)

/**
Merges two sorted/ordered lists. TCO

Pass the shorter list into A for better performance
*/
let rec mergeSortedList = (~sortedRev=list{}, ~cmp, a, b) => {
  switch (a, b) {
  | (list{aHead, ...aTail}, list{bHead, ...bTail}) =>
    let (nextA, nextB, nextItem) = if cmp(aHead, bHead) {
      (aTail, b, aHead)
    } else {
      (bTail, a, bHead)
    }
    mergeSortedList(nextA, nextB, ~cmp, ~sortedRev=sortedRev->List.add(nextItem))
  | (rest, list{}) | (list{}, rest) => List.reverseConcat(sortedRev, rest)
  }
}

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
let mergeSortedEventList = mergeSortedList(~cmp=eventCmp)

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
    {
      registerType: nextRegistered.registerType,
      fetchedEventQueue,
      contractAddressMapping,
      latestFetchedBlockTimestamp: Pervasives.max(
        self.latestFetchedBlockTimestamp,
        nextRegistered.latestFetchedBlockTimestamp,
      ),
      latestFetchedBlockNumber: Pervasives.max(
        self.latestFetchedBlockNumber,
        nextRegistered.latestFetchedBlockNumber,
      ),
    }
  | RootRegister => self //already merged
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
  | RootRegister => Root
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
  ~latestFetchedBlockNumber,
  ~latestFetchedBlockTimestamp,
  ~newFetchedEvents,
) => {
  ...self,
  latestFetchedBlockNumber,
  latestFetchedBlockTimestamp,
  fetchedEventQueue: List.concat(self.fetchedEventQueue, newFetchedEvents),
}

/**
Links next register to a dynamic contract register
*/
let addNextRegister = (~register: t, ~dynamicContractId, nextRegister: t) => {
  ...register,
  registerType: DynamicContractRegister(dynamicContractId, nextRegister),
}

/**
Updates node at the given id with the values passed.
Errors if the node can't be found.
*/
let rec updateInternal = (
  ~id,
  ~latestFetchedBlockTimestamp,
  ~latestFetchedBlockNumber,
  ~newFetchedEvents,
  register: t,
): result<t, exn> => {
  switch (register.registerType, id) {
  | (RootRegister, Root) =>
    register
    ->updateRegister(~newFetchedEvents, ~latestFetchedBlockTimestamp, ~latestFetchedBlockNumber)
    ->Ok
  | (DynamicContractRegister(id, _nextRegistered), DynamicContract(targetId)) if id == targetId =>
    register
    ->updateRegister(~newFetchedEvents, ~latestFetchedBlockTimestamp, ~latestFetchedBlockNumber)
    ->Ok
  | (DynamicContractRegister(dynamicContractId, nextRegistered), id) =>
    nextRegistered
    ->updateInternal(
      ~newFetchedEvents,
      ~id,
      ~latestFetchedBlockNumber,
      ~latestFetchedBlockTimestamp,
    )
    ->Result.map(addNextRegister(~register, ~dynamicContractId))
  | (RootRegister, DynamicContract(_)) => Error(UnexpectedRegisterDoesNotExist(id))
  }
}

/**
If a fetchState register has caught up to its next regisered node. Merge them and recurse.
If no merging happens, None is returned
*/
let rec pruneAndMergeNextRegistered = (self: t) => {
  switch self.registerType {
  | RootRegister => None
  | DynamicContractRegister(_, nextRegister)
    if self.latestFetchedBlockNumber < nextRegister.latestFetchedBlockNumber =>
    None
  | DynamicContractRegister(_) =>
    let mergedSelf = self->mergeIntoNextRegistered

    // Recursively look for other merges, if they affect the state, return that merged state otherwise, return the `mergedSelf`
    switch mergedSelf->pruneAndMergeNextRegistered {
    | Some(mergedNext) => Some(mergedNext)
    | None => Some(mergedSelf)
    }
  }
}

/**
Updates node at given id with given values and checks to see if it can be merged into its next register.
Returns Error if the node with given id cannot be found (unexpected)
*/
let update = (
  self: t,
  ~id,
  ~latestFetchedBlockTimestamp,
  ~latestFetchedBlockNumber,
  ~fetchedEvents,
): result<t, exn> =>
  self
  ->updateInternal(
    ~id,
    ~latestFetchedBlockTimestamp,
    ~latestFetchedBlockNumber,
    ~newFetchedEvents=fetchedEvents,
  )
  ->Result.map(result => pruneAndMergeNextRegistered(result)->Option.getWithDefault(result))

type nextQuery = {
  fetchStateRegisterId: id,
  fromBlock: int,
  toBlock: int,
  contractAddressMapping: ContractAddressingMap.mapping,
  currentLatestBlockTimestamp: int,
}

/**
Constructs `nextQuery` from a given node
*/
let getNextQueryFromNode = (
  {registerType, latestFetchedBlockNumber, contractAddressMapping, latestFetchedBlockTimestamp}: t,
  ~toBlock,
) => {
  let id = switch registerType {
  | RootRegister => Root
  | DynamicContractRegister(id, _) => DynamicContract(id)
  }
  let fromBlock = switch latestFetchedBlockNumber {
  | 0 => 0
  | latestFetchedBlockNumber => latestFetchedBlockNumber + 1
  }
  {
    fetchStateRegisterId: id,
    fromBlock,
    toBlock,
    contractAddressMapping,
    currentLatestBlockTimestamp: latestFetchedBlockTimestamp,
  }
}

type nextQueryOrWaitForBlock = NextQuery(nextQuery) | WaitForNewBlock

exception FromBlockIsHigherThanToBlock(int, int) //from and to block respectively
/**
Gets the next query either with a to block of the current height if it is the root node.
Or with a toBlock of the nextRegistered latestBlockNumber to catch up and merge with the next regisetered.

Errors if nextRegistered dynamic contract has a lower latestFetchedBlock than the current as this would be
an invalid state.
*/
let getNextQuery = (self: t, ~currentBlockHeight) => {
  let maybeMerged = self->pruneAndMergeNextRegistered
  let self = maybeMerged->Option.getWithDefault(self)

  let nextQuery = switch self.registerType {
  | RootRegister => self->getNextQueryFromNode(~toBlock=currentBlockHeight)
  | DynamicContractRegister(_, {latestFetchedBlockNumber}) =>
    self->getNextQueryFromNode(~toBlock=latestFetchedBlockNumber)
  }

  switch nextQuery {
  | {fromBlock} if fromBlock > currentBlockHeight || currentBlockHeight == 0 =>
    (WaitForNewBlock, maybeMerged)->Ok
  | {fromBlock, toBlock} if fromBlock <= toBlock => (NextQuery(nextQuery), maybeMerged)->Ok
  //This is an invalid case. We should never arrive at this match arm but it would be
  //detrimental if it were the case.
  | {fromBlock, toBlock} => Error(FromBlockIsHigherThanToBlock(fromBlock, toBlock))
  }
}

type latestFetchedBlockData = {
  timestamp: int,
  blockNumber: int,
}

/**
Represents a fetchState registers head of the  fetchedEventQueue as either
an existing item, or no item with latest fetched block data
*/
type queueItem =
  | Item(Types.eventBatchQueueItem)
  | NoItem(latestFetchedBlockData)

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
let makeNoItem = ({latestFetchedBlockNumber, latestFetchedBlockTimestamp}) => NoItem({
  timestamp: latestFetchedBlockTimestamp,
  blockNumber: latestFetchedBlockNumber,
})

let qItemLt = (a, b) => a->getCmpVal < b->getCmpVal

type earliestEventResponse = {
  updatedFetchState: t,
  earliestQueueItem: queueItem,
}

/**
Returns queue item WITHOUT the updated fetch state. Used for checking values
not updating state
*/
let getEarliestEventInRegister = (self: t) => {
  switch self.fetchedEventQueue->List.head {
  | Some(head) => Item(head)
  | None => makeNoItem(self)
  }
}

/**
Returns queue item WITH the updated fetch state. 
*/
let getEarliestEventInRegisterWithUpdatedQueue = (self: t) => {
  let (updatedFetchState, earliestQueueItem) = switch self.fetchedEventQueue {
  | list{} => (self, makeNoItem(self))
  | list{head, ...fetchedEventQueue} => ({...self, fetchedEventQueue}, Item(head))
  }

  {updatedFetchState, earliestQueueItem}
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
  | RootRegister => currentEarliestRegister->getRegisterId
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
  {updatedFetchState, earliestQueueItem},
) => {
  {
    updatedFetchState: updatedFetchState->addNextRegister(~register, ~dynamicContractId),
    earliestQueueItem,
  }
}

/**
Given a register id, pop a queue item off of that register and return the entire updated
fetch state with that item.

Recurses through registers and Errors if ID does not exist
*/
let rec popQItemAtRegisterId = (self: t, ~id) =>
  switch self.registerType {
  | RootRegister
  | DynamicContractRegister(_) if id == self->getRegisterId =>
    self->getEarliestEventInRegisterWithUpdatedQueue->Ok
  | DynamicContractRegister(dynamicContractId, nextRegister) =>
    nextRegister
    ->popQItemAtRegisterId(~id)
    ->Result.map(getRegisterWithNextResponse(self, ~dynamicContractId))
  | RootRegister => Error(UnexpectedRegisterDoesNotExist(id))
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

let makeInternal = (~registerType, ~contractAddressMapping, ~startBlock): t => {
  registerType,
  latestFetchedBlockTimestamp: 0,
  latestFetchedBlockNumber: Pervasives.max(startBlock - 1, 0),
  contractAddressMapping,
  fetchedEventQueue: list{},
}

/**
Instantiates a fetch state with root register
*/
let makeRoot = makeInternal(~registerType=RootRegister)

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
  let id = {
    blockNumber: registeringEventBlockNumber,
    logIndex: registeringEventLogIndex,
  }
  let registerType = DynamicContractRegister(id, self)

  {
    registerType,
    latestFetchedBlockNumber: registeringEventBlockNumber - 1,
    latestFetchedBlockTimestamp: 0,
    contractAddressMapping,
    fetchedEventQueue: list{},
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
  ~contractAddressMapping,
) => {
  let latestFetchedBlockNumber = registeringEventBlockNumber - 1
  let addToHead = addNewRegisterToHead(
    ~contractAddressMapping,
    ~registeringEventLogIndex,
    ~registeringEventBlockNumber,
  )

  switch register.registerType {
  | RootRegister => register->addToHead
  | DynamicContractRegister(_) if latestFetchedBlockNumber <= register.latestFetchedBlockNumber =>
    register->addToHead
  | DynamicContractRegister(dynamicContractId, nextRegister) =>
    nextRegister
    ->registerDynamicContract(
      ~contractAddressMapping,
      ~registeringEventBlockNumber,
      ~registeringEventLogIndex,
    )
    ->addNextRegister(~register, ~dynamicContractId)
  }
}

let rec queueSizeInternal = (self: t, ~accum) => {
  let accum = self.fetchedEventQueue->List.size + accum
  switch self.registerType {
  | RootRegister => accum
  | DynamicContractRegister(_, nextRegister) => nextRegister->queueSizeInternal(~accum)
  }
}

/**
Calculates the cummulative queue sizes in all registers
*/
let queueSize = queueSizeInternal(~accum=0)

/**
Check the max queue size of the tip of the tree.

Don't use the cummulative queue sizes because otherwise there
could be a deadlock. With a very small buffer size of the actively
fetching registration
*/
let isReadyForNextQuery = (self: t, ~maxQueueSize) =>
  self.fetchedEventQueue->List.size < maxQueueSize

let rec getAllAddressesForContract = (~addresses=Set.String.empty, ~contractName, self: t) => {
  let addresses =
    self.contractAddressMapping
    ->ContractAddressingMap.getAddresses(contractName)
    ->Option.mapWithDefault(addresses, newAddresses => {
      addresses->Set.String.union(newAddresses)
    })

  switch self.registerType {
  | RootRegister => addresses
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
  allAddr->Set.String.has(contractAddress->Ethers.ethAddressToString)
}

/**
* Returns the latest block number fetched for the lowest fetcher queue (ie the earliest un-fetched dynamic contract)
*/
let getLatestFullyFetchedBlock = (self: t) => self.latestFetchedBlockNumber

/**
Helper functions for debugging and printing
*/
module DebugHelpers = {
  let registerToString = register =>
    switch register {
    | RootRegister => "root"
    | DynamicContractRegister({blockNumber, logIndex}, _) =>
      `DC-${blockNumber->Int.toString}-${logIndex->Int.toString}`
    }

  let rec getQueueSizesInternal = (self: t, ~accum) => {
    let next = (self.registerType->registerToString, self.fetchedEventQueue->List.size)
    let accum = list{next, ...accum}
    switch self.registerType {
    | RootRegister => accum
    | DynamicContractRegister(_, nextRegister) => nextRegister->getQueueSizesInternal(~accum)
    }
  }

  let getQueueSizes = (self: t) =>
    self->getQueueSizesInternal(~accum=list{})->List.toArray->Js.Dict.fromArray

  let rec numberRegistered = (~accum=0, self: t) => {
    let accum = accum + 1
    switch self.registerType {
    | RootRegister => accum
    | DynamicContractRegister(_, nextRegister) => nextRegister->numberRegistered(~accum)
    }
  }
}
