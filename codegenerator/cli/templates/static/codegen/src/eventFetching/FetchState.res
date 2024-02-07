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
let rec mergeSortedListInternal = (a, b, ~cmp, ~sortedRev) => {
  switch (a, b) {
  | (list{aHead, ...aTail}, list{bHead, ...bTail}) =>
    let (nextA, nextB, nextItem) = if cmp(aHead, bHead) {
      (aTail, b, aHead)
    } else {
      (bTail, a, bHead)
    }
    mergeSortedListInternal(nextA, nextB, ~cmp, ~sortedRev=sortedRev->List.add(nextItem))
  | (rest, list{}) | (list{}, rest) => List.reverseConcat(sortedRev, rest)
  }
}

let mergeSortedList = mergeSortedListInternal(~sortedRev=list{})

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

exception UnexpectedNodeDoesNotExist(dynamicContractId)
let updateNode = (
  self: t,
  ~latestFetchedBlockNumber,
  ~latestFetchedBlockTimestamp,
  ~newFetchedEvents,
) => {
  ...self,
  latestFetchedBlockNumber,
  latestFetchedBlockTimestamp,
  fetchedEventQueue: List.concat(newFetchedEvents, self.fetchedEventQueue),
}

type id = Root | DynamicContract(dynamicContractId)
/**
Updates node at the given id with the values passed.
Errors if the node can't be found.
*/
let rec updateInternal = (
  ~id,
  ~latestFetchedBlockTimestamp,
  ~latestFetchedBlockNumber,
  ~newFetchedEvents,
  self: t,
): result<t, exn> => {
  switch (self.registerType, id) {
  | (RootRegister, Root) =>
    self->updateNode(~newFetchedEvents, ~latestFetchedBlockTimestamp, ~latestFetchedBlockNumber)->Ok
  | (DynamicContractRegister(id, _nextRegistered), DynamicContract(targetId)) if id == targetId =>
    self->updateNode(~newFetchedEvents, ~latestFetchedBlockTimestamp, ~latestFetchedBlockNumber)->Ok
  | (DynamicContractRegister(currentRegisterId, nextRegistered), id) =>
    nextRegistered
    ->updateInternal(
      ~newFetchedEvents,
      ~id,
      ~latestFetchedBlockNumber,
      ~latestFetchedBlockTimestamp,
    )
    ->Result.map(res => {
      ...self,
      registerType: DynamicContractRegister(currentRegisterId, res),
    })
  | (RootRegister, DynamicContract(id)) => Error(UnexpectedNodeDoesNotExist(id))
  }
}

/**
If a fethcer has caught up to its next regisered node. Merge them and recurse.
*/
let rec pruneAndMergeNextRegistered = (self: t) => {
  switch self.registerType {
  | RootRegister => None
  | DynamicContractRegister(_, nextRegister) =>
    if self.latestFetchedBlockNumber < nextRegister.latestFetchedBlockNumber {
      None
    } else {
      let mergedSelf = self->mergeIntoNextRegistered

      // Recursively look for other merges, if they affect the state, return that merged state otherwise, return the `mergedSelf`
      switch mergedSelf->pruneAndMergeNextRegistered {
      | Some(mergedNext) => Some(mergedNext)
      | None => Some(mergedSelf)
      }
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
  fetcherId: id,
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
    fetcherId: id,
    fromBlock,
    toBlock,
    contractAddressMapping,
    currentLatestBlockTimestamp: latestFetchedBlockTimestamp,
  }
}

type nextQueryOrWaitForBlock = NextQuery(nextQuery) | WaitForNewBlock

/**
Gets the next query either with a to block of the current height if it is the root node.
Or with a toBlock of the nextRegistered latestBlockNumber to catch up and merge with the next regisetered.
*/
let getNextQuery = (self: t, ~currentBlockHeight) => {
  let maybeMerged = self->pruneAndMergeNextRegistered
  let self = maybeMerged->Option.getWithDefault(self)

  let nextQuery = switch self.registerType {
  | RootRegister => self->getNextQueryFromNode(~toBlock=currentBlockHeight)
  | DynamicContractRegister(_, {latestFetchedBlockNumber}) =>
    self->getNextQueryFromNode(~toBlock=latestFetchedBlockNumber)
  }

  // Todo refine condition
  if nextQuery.fromBlock > nextQuery.toBlock || currentBlockHeight == 0 {
    (WaitForNewBlock, maybeMerged)
  } else {
    (NextQuery(nextQuery), maybeMerged)
  }
}

type earliestFetchedData = {
  timestamp: int,
  blockNumber: int, // NOTE: this value isn't needed for this code to work,
}

type queueItem =
  | Item(Types.eventBatchQueueItem)
  | NoItem(earliestFetchedData)

let getCmp = qItem =>
  switch qItem {
  | Item({blockNumber, logIndex}) => (blockNumber, logIndex)
  | NoItem({blockNumber}) => (blockNumber, 0)
  }

let qItemLt = (a, b) => a->getCmp < b->getCmp

let earlierQItem = (a, b) =>
  if a->qItemLt(b) {
    a
  } else {
    b
  }

type earliestEventResponse = {
  updatedFetcher: t,
  earliestQueueItem: queueItem,
}

let getNodeEarliestEvent = (self: t) => {
  let (updatedFetcher, earliestQueueItem) = switch self.fetchedEventQueue {
  | list{} => (
      self,
      NoItem({
        timestamp: self.latestFetchedBlockTimestamp,
        blockNumber: self.latestFetchedBlockNumber,
      }),
    )
  | list{head, ...fetchedEventQueue} => ({...self, fetchedEventQueue}, Item(head))
  }

  {updatedFetcher, earliestQueueItem}
}

let getRegisterWithNextResponse = (
  self: t,
  {updatedFetcher, earliestQueueItem},
  ~dynamicContractId,
) => {
  let updatedFetcher = {
    ...self,
    registerType: DynamicContractRegister(dynamicContractId, updatedFetcher),
  }
  {updatedFetcher, earliestQueueItem}
}

/**
Gets the earliest queueItem from the register passed in.
If this is the head register (the register with the lowest latestFetchedBlockNumber), then this will always be the next event for processing the batch.
*/
let rec getEarliestEvent = (self: t) => {
  let currentEarliestEvent = self->getNodeEarliestEvent
  switch self.registerType {
  | RootRegister => currentEarliestEvent
  | DynamicContractRegister(dynamicContractId, nextRegister) =>
    let nextRegisterEarliestEvent = nextRegister->getNodeEarliestEvent

    if (
      currentEarliestEvent.earliestQueueItem->qItemLt(nextRegisterEarliestEvent.earliestQueueItem)
    ) {
      // TODO: check on other queues for edge case that they have other earlier events from previous hypersync requests.
      currentEarliestEvent
    } else {
      self->getRegisterWithNextResponse(nextRegister->getEarliestEvent, ~dynamicContractId)
    }
  }
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
let addRegisterToHead = (
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
  self: t,
  ~registeringEventBlockNumber,
  ~registeringEventLogIndex,
  ~contractAddressMapping,
) => {
  let latestFetchedBlockNumber = registeringEventBlockNumber - 1

  switch self.registerType {
  | RootRegister =>
    self->addRegisterToHead(
      ~contractAddressMapping,
      ~registeringEventLogIndex,
      ~registeringEventBlockNumber,
    )
  | DynamicContractRegister(_) if latestFetchedBlockNumber <= self.latestFetchedBlockNumber =>
    self->addRegisterToHead(
      ~contractAddressMapping,
      ~registeringEventLogIndex,
      ~registeringEventBlockNumber,
    )
  | DynamicContractRegister(id, next) =>
    let nextRegistered =
      next->registerDynamicContract(
        ~contractAddressMapping,
        ~registeringEventBlockNumber,
        ~registeringEventLogIndex,
      )
    {...self, registerType: DynamicContractRegister(id, nextRegistered)}
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

