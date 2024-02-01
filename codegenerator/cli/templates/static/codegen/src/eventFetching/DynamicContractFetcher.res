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
  pendingDynamicContractRegistrations: option<t>,
}

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

let getEventCmp = (event: Types.eventBatchQueueItem) => {
  (event.timestamp, event.blockNumber, event.logIndex)
}

let eventCmp = (a, b) => a->getEventCmp <= b->getEventCmp

let mergeSortedEventList = mergeSortedList(~cmp=eventCmp)

let mergeChild = (self: t) => {
  switch self.pendingDynamicContractRegistrations {
  | Some(child) =>
    let fetchedEventQueue = mergeSortedEventList(self.fetchedEventQueue, child.fetchedEventQueue)
    let contractAddressMapping = ContractAddressingMap.combine(
      self.contractAddressMapping,
      child.contractAddressMapping,
    )
    {
      id: self.id,
      fetchedEventQueue,
      contractAddressMapping,
      latestFetchedBlockTimestamp: Pervasives.max(
        self.latestFetchedBlockTimestamp,
        child.latestFetchedBlockTimestamp,
      ),
      latestFetchedBlockNumber: Pervasives.max(
        self.latestFetchedBlockNumber,
        child.latestFetchedBlockNumber,
      ),
      pendingDynamicContractRegistrations: child.pendingDynamicContractRegistrations,
    }
  | None => self //already merged
  }
}

let rec getChild = (~id=Root, self: t) => {
  if self.id == id {
    Some(self)
  } else {
    switch self.pendingDynamicContractRegistrations {
    | None => None
    | Some(child) => child->getChild(~id)
    }
  }
}

exception UnexpectedDynamicContractExists(id)

let rec addDynamicContractNode = (root: t, val: t) => {
  if root.id == val.id {
    Error(UnexpectedDynamicContractExists(val.id))
  } else {
    switch root.pendingDynamicContractRegistrations {
    | None => {...root, pendingDynamicContractRegistrations: Some(val)}->Ok
    | Some(child) =>
      child
      ->addDynamicContractNode(val)
      ->Result.map(v => {
        ...root,
        pendingDynamicContractRegistrations: Some(v),
      })
    }
  }
}

let rec updateInternal = (
  ~id,
  ~latestFetchedBlockTimestamp,
  ~latestFetchedBlockNumber,
  ~newFetchedEvents,
  ~contractAddressMapping,
  self: t,
): t => {
  if self.id == id {
    {
      ...self,
      latestFetchedBlockNumber,
      latestFetchedBlockTimestamp,
      fetchedEventQueue: List.concat(newFetchedEvents, self.fetchedEventQueue),
    }
  } else {
    switch self.pendingDynamicContractRegistrations {
    | Some(child) =>
      //recurse through children to find the child with the matching id
      let pendingDynamicContractRegistrations =
        child
        ->updateInternal(
          ~newFetchedEvents,
          ~id,
          ~latestFetchedBlockNumber,
          ~latestFetchedBlockTimestamp,
          ~contractAddressMapping,
        )
        ->Some
      {
        ...self,
        pendingDynamicContractRegistrations,
      }
    | None =>
      //This means there is a new dynamic contract registration so add it
      //as a child
      let pendingDynamicContractRegistrations = {
        id,
        latestFetchedBlockTimestamp,
        latestFetchedBlockNumber,
        fetchedEventQueue: newFetchedEvents,
        contractAddressMapping,
        pendingDynamicContractRegistrations: None,
      }->Some
      {...self, pendingDynamicContractRegistrations}
    }
  }
}

let rec pruneAndMergeDynamicContractChildren = (self: t) => {
  switch self.pendingDynamicContractRegistrations {
  | None => self
  | Some(child) =>
    if child.latestFetchedBlockNumber >= self.latestFetchedBlockNumber {
      self->mergeChild->pruneAndMergeDynamicContractChildren
    } else {
      self
    }
  }
}

let update = (
  self: t,
  ~id,
  ~latestFetchedBlockTimestamp,
  ~latestFetchedBlockNumber,
  ~contractAddressMapping,
  ~newFetchedEvents,
): t =>
  self
  ->updateInternal(
    ~id,
    ~latestFetchedBlockTimestamp,
    ~latestFetchedBlockNumber,
    ~newFetchedEvents,
    ~contractAddressMapping,
  )
  ->pruneAndMergeDynamicContractChildren

type nextQuery = {
  fetcherId: id,
  fromBlock: int,
  contractAddressMapping: ContractAddressingMap.mapping,
  currentLatestBlockTimestamp: int,
}

let rec getNextQuery = (self: t) =>
  switch self.pendingDynamicContractRegistrations {
  | None => {
      fetcherId: self.id,
      fromBlock: self.latestFetchedBlockNumber + 1,
      contractAddressMapping: self.contractAddressMapping,
      currentLatestBlockTimestamp: self.latestFetchedBlockTimestamp,
    }
  | Some(child) => child->getNextQuery
  }

type latestFetchedBlockTimestamp = int
type queueItem =
  | Item(Types.eventBatchQueueItem)
  | NoItem(latestFetchedBlockTimestamp)

let getCmp = qItem =>
  switch qItem {
  | Item({timestamp, blockNumber, logIndex}) => (timestamp, blockNumber, logIndex)
  | NoItem(timestamp) => (timestamp, 0, 0)
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
  | list{} => (self, NoItem(self.latestFetchedBlockTimestamp))
  | list{head, ...fetchedEventQueue} => ({...self, fetchedEventQueue}, Item(head))
  }

  {updatedFetcher, earliestQueueItem}
}

let getSelfWithChildResponse = (self: t, {updatedFetcher, earliestQueueItem}) => {
  let updatedFetcher = {
    ...self,
    pendingDynamicContractRegistrations: Some(updatedFetcher),
  }
  {updatedFetcher, earliestQueueItem}
}

let rec getEarliestEvent = (self: t) => {
  switch self.pendingDynamicContractRegistrations {
  | None => self->getNodeEarliestEvent
  | Some(child) =>
    let currentEarliest = child->getNodeEarliestEvent
    let nextEarliest = child->getEarliestEvent

    let nextChild = if currentEarliest.earliestQueueItem->qItemLt(nextEarliest.earliestQueueItem) {
      currentEarliest
    } else {
      nextEarliest
    }

    self->getSelfWithChildResponse(nextChild)
  }
}

let makeInternal = (~id, ~contractAddressMapping): t => {
  id,
  latestFetchedBlockTimestamp: 0,
  latestFetchedBlockNumber: 0,
  contractAddressMapping,
  fetchedEventQueue: list{},
  pendingDynamicContractRegistrations: None,
}

let makeRoot = makeInternal(~id=Root)

let registerDynamicContract = (
  self: t,
  ~registeringEventBlockNumber,
  ~registeringEventLogIndex,
  ~contractAddressMapping,
) => {
  let node = {
    id: DynamicContract(registeringEventBlockNumber, registeringEventLogIndex),
    latestFetchedBlockNumber: registeringEventBlockNumber - 1,
    latestFetchedBlockTimestamp: 0,
    contractAddressMapping,
    fetchedEventQueue: list{},
    pendingDynamicContractRegistrations: None,
  }
  self->addDynamicContractNode(node)
}

let rec queueSizeInternal = (self: t, ~accum) => {
  let accum = self.fetchedEventQueue->List.size + accum
  switch self.pendingDynamicContractRegistrations {
  | None => accum
  | Some(child) => child->queueSizeInternal(~accum)
  }
}

let queueSize = queueSizeInternal(~accum=0)

let isReadyForNextQuery = (self: t, ~maxQueueSize) =>
  switch self.pendingDynamicContractRegistrations {
  | Some(_) => true
  | None => self.fetchedEventQueue->List.size < maxQueueSize
  }
