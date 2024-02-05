open Belt
type blockNumber = int
type logIndex = int
type id = Root | DynamicContract(blockNumber, logIndex)

type rec t = {
  id: id,
  latestFetchedBlockTimestamp: int,
  latestFetchedBlockNumber: int,
  contractAddressMapping: ContractAddressingMap.mapping,
  fetchedEventQueue: list<Types.eventBatchQueueItem>,
  nextRegistered: option<t>,
}

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
  switch self.nextRegistered {
  | Some(nextRegistered) =>
    let fetchedEventQueue = mergeSortedEventList(
      self.fetchedEventQueue,
      nextRegistered.fetchedEventQueue,
    )
    let contractAddressMapping = ContractAddressingMap.combine(
      self.contractAddressMapping,
      nextRegistered.contractAddressMapping,
    )
    {
      id: nextRegistered.id,
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
      nextRegistered: nextRegistered.nextRegistered,
    }
  | None => self //already merged
  }
}

exception UnexpectedNodeDoesNotExist(id)
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
  if self.id == id {
    {
      ...self,
      latestFetchedBlockNumber,
      latestFetchedBlockTimestamp,
      fetchedEventQueue: List.concat(newFetchedEvents, self.fetchedEventQueue),
    }->Ok
  } else {
    switch self.nextRegistered {
    | Some(child) =>
      //recurse through children to find the child with the matching id
      child
      ->updateInternal(
        ~newFetchedEvents,
        ~id,
        ~latestFetchedBlockNumber,
        ~latestFetchedBlockTimestamp,
      )
      ->Result.map(res => {
        ...self,
        nextRegistered: Some(res),
      })
    | None => Error(UnexpectedNodeDoesNotExist(id))
    }
  }
}

/**
If a fethcer has caught up to its next regisered node. Merge them and recurse.
*/
let rec pruneAndMergeNextRegistered = (self: t) => {
  switch self.nextRegistered {
  | None => self
  | Some(child) =>
    if self.latestFetchedBlockNumber < child.latestFetchedBlockNumber {
      self
    } else {
      self->mergeIntoNextRegistered->pruneAndMergeNextRegistered
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
  ->Result.map(pruneAndMergeNextRegistered)

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
  {id, latestFetchedBlockNumber, contractAddressMapping, latestFetchedBlockTimestamp}: t,
  ~toBlock,
) => {
  fetcherId: id,
  fromBlock: latestFetchedBlockNumber + 1,
  toBlock,
  contractAddressMapping,
  currentLatestBlockTimestamp: latestFetchedBlockTimestamp,
}

/**
Gets the next query either with a to block of the current height if it is the root node.
Or with a toBlock of the nextRegistered latestBlockNumber to catch up and merge with the next regisetered.
*/
let getNextQuery = (self: t, ~currentBlockHeight) =>
  switch self.nextRegistered {
  | None => self->getNextQueryFromNode(~toBlock=currentBlockHeight)
  | Some({latestFetchedBlockNumber}) =>
    self->getNextQueryFromNode(~toBlock=latestFetchedBlockNumber)
  }

type latestFetchedData = {
  timestamp: int,
  blockNumber: int,
}

type queueItem =
  | Item(Types.eventBatchQueueItem)
  | NoItem(latestFetchedData)

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

type latestEventResponse = {
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

let getSelfWithChildResponse = (self: t, {updatedFetcher, earliestQueueItem}) => {
  let updatedFetcher = {
    ...self,
    nextRegistered: Some(updatedFetcher),
  }
  {updatedFetcher, earliestQueueItem}
}

let rec getEarliestEvent = (self: t) => {
  let currentEarliestEvent = self->getNodeEarliestEvent
  switch self.nextRegistered {
  | None => currentEarliestEvent
  | Some(child) =>
    let childEarliestEvent = child->getNodeEarliestEvent

    if currentEarliestEvent.earliestQueueItem->qItemLt(childEarliestEvent.earliestQueueItem) {
      currentEarliestEvent
    } else {
      self->getSelfWithChildResponse(child->getEarliestEvent)
    }
  }
}

let makeInternal = (~id, ~contractAddressMapping): t => {
  id,
  latestFetchedBlockTimestamp: 0,
  latestFetchedBlockNumber: 0,
  contractAddressMapping,
  fetchedEventQueue: list{},
  nextRegistered: None,
}

let makeRoot = makeInternal(~id=Root)

/**
compares two node ids to see which one was regisetered earlier
*/
let nodeIdLte = (a, b) =>
  switch (a, b) {
  | (Root, _) => true
  | (DynamicContract(_), Root) => false
  | (
      DynamicContract(dynABlockNumber, dynALogIndex),
      DynamicContract(dynBBlockNumber, dynBLogIndex),
    ) =>
    (dynABlockNumber, dynALogIndex) <= (dynBBlockNumber, dynBLogIndex)
  }

/**
Adds a new dynamic contract registration. Returns an error in the case that there
is already a registration that came later than the current one. This is unexpected.
*/
let rec registerDynamicContract = (
  self: t,
  ~registeringEventBlockNumber,
  ~registeringEventLogIndex,
  ~contractAddressMapping,
) => {
  let id = DynamicContract(registeringEventBlockNumber, registeringEventLogIndex)

  let insertFront = {
    id,
    latestFetchedBlockNumber: registeringEventBlockNumber - 1,
    latestFetchedBlockTimestamp: 0,
    contractAddressMapping,
    fetchedEventQueue: list{},
    nextRegistered: Some(self),
  }

  //cases:
  //no value and we only have root -> always insert front
  //all other cases id is dynamic contract.
  //registration is less than previous add to front
  //otherwise recurse
  switch self {
  | {id: Root, nextRegistered: None} => insertFront
  | {id: DynamicContract(blockNumber, logIndex), nextRegistered: Some(next)} =>
    if (registeringEventBlockNumber, registeringEventLogIndex) <= (blockNumber, logIndex) {
      insertFront
    } else {
      let nextRegistered =
        next
        ->registerDynamicContract(
          ~contractAddressMapping,
          ~registeringEventBlockNumber,
          ~registeringEventLogIndex,
        )
        ->Some
      {...self, nextRegistered}
    }
  | _ =>
    //TODO: can change structure to have nextRegistered inside id enum
    Js.Exn.raiseError(
      "Unexpected invalid case of dynamic contract with no nextRegistration or root with registration",
    )
  }
}

let rec queueSizeInternal = (self: t, ~accum) => {
  let accum = self.fetchedEventQueue->List.size + accum
  switch self.nextRegistered {
  | None => accum
  | Some(child) => child->queueSizeInternal(~accum)
  }
}

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

  switch self.nextRegistered {
  | None => addresses
  | Some(child) => child->getAllAddressesForContract(~addresses, ~contractName)
  }
}

let checkContainsRegisteredContractAddress = (self: t, ~contractName, ~contractAddress) => {
  let allAddr = self->getAllAddressesForContract(~contractName)
  allAddr->Set.String.has(contractAddress->Ethers.ethAddressToString)
}

let idToString = id =>
  switch id {
  | Root => "root"
  | DynamicContract(bn, li) => `DC-${bn->Int.toString}-${li->Int.toString}`
  }

let rec getQueueSizesInternal = (self: t, ~accum) => {
  let next = (self.id->idToString, self.fetchedEventQueue->List.size)
  let accum = list{next, ...accum}
  switch self.nextRegistered {
  | None => accum
  | Some(child) => child->getQueueSizesInternal(~accum)
  }
}

let getQueueSizes = (self: t) =>
  self->getQueueSizesInternal(~accum=list{})->List.toArray->Js.Dict.fromArray

let rec numberRegistered = (~accum=0, self: t) => {
  let accum = accum + 1
  switch self.nextRegistered {
  | None => accum
  | Some(child) => child->numberRegistered(~accum)
  }
}
