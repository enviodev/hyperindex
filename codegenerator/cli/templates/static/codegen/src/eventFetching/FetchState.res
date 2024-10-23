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
type registerData = {
  latestFetchedBlock: blockNumberAndTimestamp,
  contractAddressMapping: ContractAddressingMap.mapping,
  //Events ordered from latest to earliest
  fetchedEventQueue: array<Types.eventBatchQueueItem>,
  //Used to prune dynamic contract registrations in the event
  //of a rollback.
  dynamicContracts: DynamicContractsMap.t,
  firstEventBlockNumber: option<int>,
}

type rec register = {
  registerType: registerType,
  ...registerData,
}
and registerType =
  | RootRegister({endBlock: option<int>})
  | DynamicContractRegister({id: EventUtils.eventIndex, nextRegister: register})

type dynamicContractRegistration = {
  registeringEventBlockNumber: int,
  registeringEventLogIndex: int,
  registeringEventChain: ChainMap.Chain.t,
  dynamicContracts: array<TablesStatic.DynamicContractRegistry.t>,
}
type t = {
  baseRegister: register,
  pendingDynamicContracts: array<dynamicContractRegistration>,
  isFetchingAtHead: bool,
}

module Parent = {
  type fetchState = register
  type rec t = {
    dynamicContractId: dynamicContractId,
    parent: option<t>,
    ...registerData,
  }

  let make = (
    {
      latestFetchedBlock,
      contractAddressMapping,
      fetchedEventQueue,
      dynamicContracts,
      firstEventBlockNumber,
    }: fetchState,
    ~dynamicContractId,
    ~parent=None,
  ): t => {
    latestFetchedBlock,
    contractAddressMapping,
    fetchedEventQueue,
    dynamicContracts,
    firstEventBlockNumber,
    dynamicContractId,
    parent,
  }

  let rec joinChild = (
    {
      latestFetchedBlock,
      contractAddressMapping,
      fetchedEventQueue,
      dynamicContracts,
      firstEventBlockNumber,
      dynamicContractId,
      parent,
    }: t,
    child: fetchState,
  ) => {
    let joined: fetchState = {
      registerType: DynamicContractRegister({id: dynamicContractId, nextRegister: child}),
      latestFetchedBlock,
      contractAddressMapping,
      fetchedEventQueue,
      dynamicContracts,
      firstEventBlockNumber,
    }

    switch parent {
    | Some(parent) => parent->joinChild(joined)
    | None => joined
    }
  }
}

let shallowCopyRegister = (register: register) => {
  ...register,
  fetchedEventQueue: register.fetchedEventQueue->Array.copy,
}

let copy = (self: t) => {
  let rec loop = (register: register, ~parent=?) =>
    switch register.registerType {
    | RootRegister(_) =>
      let copied = register->shallowCopyRegister
      switch parent {
      | Some(parent) => parent->Parent.joinChild(copied)
      | None => copied
      }
    | DynamicContractRegister({id, nextRegister}) =>
      nextRegister->loop(
        ~parent=register->shallowCopyRegister->Parent.make(~dynamicContractId=id, ~parent),
      )
    }

  let baseRegister = loop(self.baseRegister)
  let pendingDynamicContracts = self.pendingDynamicContracts->Array.copy
  {
    baseRegister,
    pendingDynamicContracts,
    isFetchingAtHead: self.isFetchingAtHead,
  }
}
/**
Comapritor for two events from the same chain. No need for chain id or timestamp
*/
let getEventCmp = (event: Types.eventBatchQueueItem) => {
  (event.blockNumber, event.logIndex)
}

/**
Returns the latest of two events on the same chain
*/
let eventCmp = (a, b) => a->getEventCmp > b->getEventCmp

/**
Merges two event queues on a single event fetcher

Pass the shorter list into A for better performance
*/
let mergeSortedEventList = (a, b) => Utils.Array.mergeSorted(eventCmp, a, b)

/**
Merges a node into its next registered branch. Combines contract address mappings and queues
*/
let mergeIntoNextRegistered = (self: register) => {
  switch self.registerType {
  | DynamicContractRegister({nextRegister}) =>
    let fetchedEventQueue = mergeSortedEventList(
      self.fetchedEventQueue,
      nextRegister.fetchedEventQueue,
    )
    let contractAddressMapping = ContractAddressingMap.combine(
      self.contractAddressMapping,
      nextRegister.contractAddressMapping,
    )

    let dynamicContracts = DynamicContractsMap.merge(
      self.dynamicContracts,
      nextRegister.dynamicContracts,
    )

    {
      registerType: nextRegister.registerType,
      fetchedEventQueue,
      contractAddressMapping,
      dynamicContracts,
      firstEventBlockNumber: Utils.Math.minOptInt(
        self.firstEventBlockNumber,
        nextRegister.firstEventBlockNumber,
      ),
      latestFetchedBlock: {
        blockTimestamp: Pervasives.max(
          self.latestFetchedBlock.blockTimestamp,
          nextRegister.latestFetchedBlock.blockTimestamp,
        ),
        blockNumber: Pervasives.max(
          self.latestFetchedBlock.blockNumber,
          nextRegister.latestFetchedBlock.blockNumber,
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

let idSchema = S.union([
  S.literal(Root),
  S.schema(s => DynamicContract(s.matches(EventUtils.eventIndexSchema))),
])

/**
Constructs id from a register
*/
let getRegisterId = (self: register) => {
  switch self.registerType {
  | RootRegister(_) => Root
  | DynamicContractRegister({id}) => DynamicContract(id)
  }
}

exception UnexpectedRegisterDoesNotExist(id)

/**
Updates a given register with new latest block values and new fetched
events.
*/
let updateRegister = (
  register: register,
  ~latestFetchedBlock,
  //Events ordered latest to earliest
  ~reversedNewItems: array<Types.eventBatchQueueItem>,
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

/**
Updates node at the given id with the values passed.
Errors if the node can't be found.
*/
let rec updateInternal = (
  register: register,
  ~id,
  ~latestFetchedBlock,
  ~reversedNewItems,
  ~parent: option<Parent.t>=?,
): result<register, exn> => {
  let handleParent = (updated: register) => {
    switch parent {
    | Some(parent) => parent->Parent.joinChild(updated)->Ok
    | None => updated->Ok
    }
  }

  switch (register.registerType, id) {
  | (RootRegister(_), Root) =>
    register
    ->updateRegister(~reversedNewItems, ~latestFetchedBlock)
    ->handleParent
  | (DynamicContractRegister({id}), DynamicContract(targetId)) if id == targetId =>
    register
    ->updateRegister(~reversedNewItems, ~latestFetchedBlock)
    ->handleParent
  | (DynamicContractRegister({id: dynamicContractId, nextRegister}), id) =>
    nextRegister->updateInternal(
      ~id,
      ~latestFetchedBlock,
      ~reversedNewItems,
      ~parent=register->Parent.make(~dynamicContractId, ~parent),
    )
  | (RootRegister(_), DynamicContract(_)) => Error(UnexpectedRegisterDoesNotExist(id))
  }
}

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
  let registerType = DynamicContractRegister({id, nextRegister: self})

  let dynamicContracts =
    DynamicContractsMap.empty->DynamicContractsMap.add(
      id,
      contractAddressMapping->ContractAddressingMap.getAllAddresses,
    )

  {
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
let rec addDynamicContractRegister = (
  self: register,
  ~registeringEventBlockNumber,
  ~registeringEventLogIndex,
  ~dynamicContractRegistrations: array<TablesStatic.DynamicContractRegistry.t>,
  ~parent: option<Parent.t>=?,
) => {
  let handleParent = updated =>
    switch parent {
    | Some(parent) => parent->Parent.joinChild(updated)
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

  switch self.registerType {
  | RootRegister(_) => self->addToHead
  | DynamicContractRegister(_) if latestFetchedBlockNumber <= self.latestFetchedBlock.blockNumber =>
    self->addToHead
  | DynamicContractRegister({id: dynamicContractId, nextRegister}) =>
    nextRegister->addDynamicContractRegister(
      ~registeringEventBlockNumber,
      ~registeringEventLogIndex,
      ~dynamicContractRegistrations,
      ~parent=self->Parent.make(~dynamicContractId, ~parent),
    )
  }
}

/**
Adds a new dynamic contract registration. It appends the registration to the pending dynamic
contract registrations. These pending registrations are applied to the base register when next
query is called.
*/
let registerDynamicContract = (self: t, registration: dynamicContractRegistration) => {
  ...self,
  pendingDynamicContracts: self.pendingDynamicContracts->Array.concat([registration]),
  isFetchingAtHead: false,
}

let addDynamicContractRegisters = (baseRegister, pendingDynamicContracts) => {
  pendingDynamicContracts->Array.reduce(baseRegister, (
    baseRegister,
    {registeringEventBlockNumber, registeringEventLogIndex, dynamicContracts},
  ) => {
    baseRegister->addDynamicContractRegister(
      ~registeringEventBlockNumber,
      ~registeringEventLogIndex,
      ~dynamicContractRegistrations=dynamicContracts,
    )
  })
}

/**
If a fetchState register has caught up to its next regisered node. Merge them and recurse.
If no merging happens, None is returned
*/
let rec pruneAndMergeNextRegistered = (register: register, ~isMerged=false) => {
  let merged = isMerged ? Some(register) : None
  switch register.registerType {
  | RootRegister(_) => merged
  | DynamicContractRegister({nextRegister})
    if register.latestFetchedBlock.blockNumber <
    nextRegister.latestFetchedBlock.blockNumber => merged
  | DynamicContractRegister(_) =>
    // Recursively look for other merges
    register->mergeIntoNextRegistered->pruneAndMergeNextRegistered(~isMerged=true)
  }
}

let applyPendingDynamicContractRegistrations = (self: t) => {
  switch self.pendingDynamicContracts {
  | [] => None
  | pendingDynamicContracts =>
    Some({
      ...self,
      baseRegister: self.baseRegister->addDynamicContractRegisters(pendingDynamicContracts),
      pendingDynamicContracts: [],
    })
  }
}
/**
Updates node at given id with given values and checks to see if it can be merged into its next register.
Returns Error if the node with given id cannot be found (unexpected)

newItems are ordered earliest to latest (as they are returned from the worker)
*/
let update = (
  {baseRegister, pendingDynamicContracts, isFetchingAtHead}: t,
  ~id,
  ~latestFetchedBlock,
  ~newItems,
  ~currentBlockHeight,
): result<t, exn> => {
  let isFetchingAtHead = isFetchingAtHead || currentBlockHeight <= latestFetchedBlock.blockNumber

  baseRegister
  ->updateInternal(~id, ~latestFetchedBlock, ~reversedNewItems=newItems->Array.reverse)
  ->Result.map(updatedRegister => {
    let withNewDynamicContracts =
      updatedRegister->addDynamicContractRegisters(pendingDynamicContracts)
    let maybeMerged = withNewDynamicContracts->pruneAndMergeNextRegistered
    {
      baseRegister: maybeMerged->Option.getWithDefault(withNewDynamicContracts),
      pendingDynamicContracts: [],
      isFetchingAtHead,
    }
  })
}

type nextQuery = {
  fetchStateRegisterId: id,
  //used to id the partition of the fetchstate
  partitionId: int,
  fromBlock: int,
  toBlock: int,
  contractAddressMapping: ContractAddressingMap.mapping,
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
      (Array.concat(currentDisplay, [addr->Address.toString]), restCount)
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
  {registerType, latestFetchedBlock, contractAddressMapping}: register,
  ~toBlock,
  ~partitionId,
) => {
  let (id, endBlock) = switch registerType {
  | RootRegister({endBlock}) => (Root, endBlock)
  | DynamicContractRegister({id}) => (DynamicContract(id), None)
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

let rec getEndBlock = (self: register) => {
  switch self.registerType {
  | RootRegister({endBlock}) => endBlock
  | DynamicContractRegister({nextRegister}) => nextRegister->getEndBlock
  }
}

type itemWithPopFn = {item: Types.eventBatchQueueItem, popItemOffQueue: unit => unit}

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
let getEarliestEventInRegister = (self: register) => {
  switch self.fetchedEventQueue->Utils.Array.last {
  | Some(head) =>
    Item({item: head, popItemOffQueue: () => self.fetchedEventQueue->Js.Array2.pop->ignore})
  | None => makeNoItem(self)
  }
}

/**
Recurses through all registers and finds the register with the earliest queue item,
then returns its id.
*/
let rec findRegisterIdWithEarliestQueueItem = (~currentEarliestRegister=?, register: register) => {
  let currentEarliestRegister = switch currentEarliestRegister {
  | None => register
  | Some(currentEarliestRegister) =>
    if (
      register
      ->getEarliestEventInRegister
      ->qItemLt(currentEarliestRegister->getEarliestEventInRegister)
    ) {
      register
    } else {
      currentEarliestRegister
    }
  }

  switch register.registerType {
  | RootRegister(_) => currentEarliestRegister->getRegisterId
  | DynamicContractRegister({nextRegister}) =>
    nextRegister->findRegisterIdWithEarliestQueueItem(~currentEarliestRegister)
  }
}

/**
Given a register id, pop a queue item off of that register and return the entire updated
fetch state with that item.

Recurses through registers and Errors if ID does not exist
*/
let rec popQItemAtRegisterId = (register: register, ~id) => {
  switch register.registerType {
  | RootRegister(_)
  | DynamicContractRegister(_) if id == register->getRegisterId =>
    register->getEarliestEventInRegister->Ok
  | DynamicContractRegister({nextRegister}) => nextRegister->popQItemAtRegisterId(~id)
  | RootRegister(_) => Error(UnexpectedRegisterDoesNotExist(id))
  }
}

/**
Gets the earliest queueItem from thgetNodeEarliestEventWithUpdatedQueue.

Finds the earliest queue item across all registers and then returns that
queue item with an update fetch state.
*/
let getEarliestEvent = (self: t) => {
  let registerWithEarliestQItem = self.baseRegister->findRegisterIdWithEarliestQueueItem
  //Can safely unwrap here since the id is returned from self and so is guarenteed to exist
  self.baseRegister->popQItemAtRegisterId(~id=registerWithEarliestQItem)->Utils.unwrapResultExn
}

let makeInternal = (
  ~registerType,
  ~staticContracts,
  ~dynamicContractRegistrations: array<TablesStatic.DynamicContractRegistry.t>,
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

  let baseRegister = {
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

  {
    baseRegister,
    pendingDynamicContracts: [],
    isFetchingAtHead,
  }
}

/**
Instantiates a fetch state with root register
*/
let makeRoot = (~endBlock) => makeInternal(~registerType=RootRegister({endBlock: endBlock}), ...)

/**
Gets the next query either with a to block of the current height if it is the root node.
Or with a toBlock of the nextRegistered latestBlockNumber to catch up and merge with the next regisetered.

Errors if nextRegistered dynamic contract has a lower latestFetchedBlock than the current as this would be
an invalid state.
*/
let getNextQuery = (self: t, ~currentBlockHeight, ~partitionId) => {
  let mapMaybeMerge = (fetchState: t) =>
    fetchState.baseRegister
    ->pruneAndMergeNextRegistered
    ->Option.map(merged => {
      ...fetchState,
      baseRegister: merged,
    })

  //First apply pending dynamic contracts, then try and merge
  //These steps should only happen on getNextQuery, to avoid in between states where a
  //query is in flight and the underlying registers are changing
  let maybeUpdatedFetchState = switch self->applyPendingDynamicContractRegistrations {
  | Some(updatedWithDynamicContracts) =>
    //After adding the pending dynamic contracts, try and merge registers
    switch updatedWithDynamicContracts->mapMaybeMerge {
    //Pass through the merged value if it updated anything
    | Some(merged) => Some(merged)
    //Even if the merge returned none, the pending dynamic contracts should be applied
    //as an updated
    | None => Some(updatedWithDynamicContracts)
    }
  //If no dynamic contracts were added just try and merge
  | None => self->mapMaybeMerge
  }

  let {baseRegister} = maybeUpdatedFetchState->Option.getWithDefault(self)

  let nextQuery = switch baseRegister.registerType {
  | RootRegister({endBlock}) =>
    baseRegister->getNextQueryFromNode(
      ~toBlock={minOfOption(currentBlockHeight, endBlock)},
      ~partitionId,
    )
  | DynamicContractRegister({nextRegister: {latestFetchedBlock}}) =>
    baseRegister->getNextQueryFromNode(~toBlock=latestFetchedBlock.blockNumber, ~partitionId)
  }

  switch nextQuery {
  | {fromBlock} if fromBlock > currentBlockHeight || currentBlockHeight == 0 =>
    (WaitForNewBlock, maybeUpdatedFetchState)->Ok
  | {fromBlock, toBlock} if fromBlock <= toBlock =>
    (NextQuery(nextQuery), maybeUpdatedFetchState)->Ok
  | {fromBlock} if fromBlock->isGreaterThanOpt(getEndBlock(baseRegister)) =>
    (Done, maybeUpdatedFetchState)->Ok
  //This is an invalid case. We should never arrive at this match arm but it would be
  //detrimental if it were the case.
  | {fromBlock, toBlock} => Error(FromBlockIsHigherThanToBlock(fromBlock, toBlock))
  }
}

/**
Calculates the cummulative queue sizes in all registers
*/
let rec registerQueueSize = (register: register, ~accum=0) => {
  let accum = register.fetchedEventQueue->Array.length + accum
  switch register.registerType {
  | RootRegister(_) => accum
  | DynamicContractRegister({nextRegister}) => nextRegister->registerQueueSize(~accum)
  }
}

let queueSize = (self: t) => self.baseRegister->registerQueueSize

/**
Check the max queue size of the tip of the tree.

Don't use the cummulative queue sizes because otherwise there
could be a deadlock. With a very small buffer size of the actively
fetching registration
*/
let isReadyForNextQuery = (self: t, ~maxQueueSize) =>
  self.baseRegister.fetchedEventQueue->Array.length < maxQueueSize

let rec getAllAddressesForContract = (
  ~addresses=Set.String.empty,
  ~contractName,
  self: register,
) => {
  let addresses =
    self.contractAddressMapping
    ->ContractAddressingMap.getAddresses(contractName)
    ->Option.mapWithDefault(addresses, newAddresses => {
      addresses->Set.String.union(newAddresses)
    })

  switch self.registerType {
  | RootRegister(_) => addresses
  | DynamicContractRegister({nextRegister}) =>
    nextRegister->getAllAddressesForContract(~addresses, ~contractName)
  }
}

/**
Recurses through registers and determines whether a contract has already been registered with
the given name and address
*/
let checkContainsRegisteredContractAddress = (self: t, ~contractName, ~contractAddress) => {
  let allAddr = self.baseRegister->getAllAddressesForContract(~contractName)
  allAddr->Set.String.has(contractAddress->Address.toString)
}

/**
* Returns the latest block number fetched for the lowest fetcher queue (ie the earliest un-fetched dynamic contract)
*/
let getLatestFullyFetchedBlock = (self: t) => {
  //Consider pending dynamic contracts when calculating the latest fully fetched block
  //Since they are now registered lazily on query or update of the fetchstate, not when
  //the register function is called
  let minPendingDynamicContracts = self.pendingDynamicContracts->Belt.Array.reduce(None, (
    acc,
    contract,
  ) => {
    let {registeringEventBlockNumber} = contract
    minOfOption(registeringEventBlockNumber - 1, acc)->Some
  })

  switch (self.baseRegister.latestFetchedBlock, minPendingDynamicContracts) {
  | ({blockNumber}, Some(pendingDynamicContractBlockNumber))
    if pendingDynamicContractBlockNumber < blockNumber => {
      blockNumber: pendingDynamicContractBlockNumber,
      blockTimestamp: 0,
    }
  | (baseRegisterLatest, _) => baseRegisterLatest
  }
}

let pruneQueuePastValidBlock = (queue: array<Types.eventBatchQueueItem>, ~lastKnownValidBlock) => {
  let prunedQueue = []
  let rec loop = index => {
    switch queue[index] {
    | Some(head) =>
      if head.blockNumber <= lastKnownValidBlock.blockNumber {
        prunedQueue->Js.Array2.push(head)->ignore
      }
      loop(index + 1)
    | None => prunedQueue
    }
  }
  loop(0)
}

let pruneDynamicContractAddressesPastValidBlock = (~lastKnownValidBlock, register: register) => {
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
let rec rollbackRegisterList = (
  self: register,
  ~lastKnownValidBlock: blockNumberAndTimestamp,
  ~parent: option<Parent.t>=?,
) => {
  let handleParent = updated =>
    switch parent {
    | Some(parent) => parent->Parent.joinChild(updated)
    | None => updated
    }

  switch self.registerType {
  //Case 1 Root register that has only fetched up to a confirmed valid block number
  //Should just return itself unchanged
  | RootRegister(_) if self.latestFetchedBlock.blockNumber <= lastKnownValidBlock.blockNumber =>
    self->handleParent
  //Case 2 Dynamic register that has only fetched up to a confirmed valid block number
  //Should just return itself, with the next register rolled back recursively
  | DynamicContractRegister({id, nextRegister})
    if self.latestFetchedBlock.blockNumber <= lastKnownValidBlock.blockNumber =>
    nextRegister->rollbackRegisterList(
      ~lastKnownValidBlock,
      ~parent=self->Parent.make(~dynamicContractId=id, ~parent),
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
  | DynamicContractRegister({id, nextRegister}) =>
    let updatedWithRemovedDynamicContracts =
      self->pruneDynamicContractAddressesPastValidBlock(~lastKnownValidBlock)

    if updatedWithRemovedDynamicContracts.contractAddressMapping->ContractAddressingMap.isEmpty {
      //If the contractAddressMapping is empty after pruning dynamic contracts, then this
      //is a dead register. Simly return its next register rolled back
      nextRegister->rollbackRegisterList(~lastKnownValidBlock, ~parent?)
    } else {
      //If there are still values in the contractAddressMapping, we should keep the register but
      //prune queues and next register
      let updated = {
        ...updatedWithRemovedDynamicContracts,
        fetchedEventQueue: self.fetchedEventQueue->pruneQueuePastValidBlock(~lastKnownValidBlock),
        latestFetchedBlock: lastKnownValidBlock,
      }
      nextRegister->rollbackRegisterList(
        ~lastKnownValidBlock,
        ~parent=updated->Parent.make(~dynamicContractId=id, ~parent),
      )
    }
  }
}

let rollback = (self: t, ~lastKnownValidBlock) => {
  let baseRegister = rollbackRegisterList(self.baseRegister, ~lastKnownValidBlock)
  //TODO rollback pending dynamic contract registrations
  {
    ...self,
    baseRegister,
  }
}

/**
* Returns a boolean indicating whether the fetch state is actively indexing
* used for comparing event queues in the chain manager
*/
let isActivelyIndexing = ({baseRegister}: t) => {
  // nesting to limit additional unnecessary computation
  switch baseRegister.registerType {
  | RootRegister({endBlock: Some(endBlock)}) =>
    let isPastEndblock = baseRegister.latestFetchedBlock.blockNumber >= endBlock
    if isPastEndblock {
      baseRegister->registerQueueSize > 0
    } else {
      true
    }
  | _ => true
  }
}

let getNumContracts = (self: t) => {
  let rec loop = (register: register, ~accum=0) => {
    let accum = accum + register.contractAddressMapping->ContractAddressingMap.addressCount
    switch register.registerType {
    | RootRegister(_) => accum
    | DynamicContractRegister({nextRegister}) => nextRegister->loop(~accum)
    }
  }
  loop(self.baseRegister)
}

/**
Helper functions for debugging and printing
*/
module DebugHelpers = {
  let registerToString = register =>
    switch register {
    | RootRegister(_) => "root"
    | DynamicContractRegister({id: {blockNumber, logIndex}}) =>
      `DC-${blockNumber->Int.toString}-${logIndex->Int.toString}`
    }

  let rec getQueueSizesInternal = (register: register, ~accum) => {
    let next = (register.registerType->registerToString, register.fetchedEventQueue->Array.length)
    let accum = list{next, ...accum}
    switch register.registerType {
    | RootRegister(_) => accum
    | DynamicContractRegister({nextRegister}) => nextRegister->getQueueSizesInternal(~accum)
    }
  }

  let getQueueSizes = (self: t) =>
    self.baseRegister->getQueueSizesInternal(~accum=list{})->List.toArray->Js.Dict.fromArray

  let rec numberRegistered = (~accum=0, self: register) => {
    let accum = accum + 1
    switch self.registerType {
    | RootRegister(_) => accum
    | DynamicContractRegister({nextRegister}) => nextRegister->numberRegistered(~accum)
    }
  }

  let rec getRegisterAddressMaps = (self: register, ~accum=[]) => {
    accum->Js.Array2.push(self.contractAddressMapping.nameByAddress)->ignore
    switch self.registerType {
    | RootRegister(_) => accum
    | DynamicContractRegister({nextRegister}) => nextRegister->getRegisterAddressMaps(~accum)
    }
  }
}
