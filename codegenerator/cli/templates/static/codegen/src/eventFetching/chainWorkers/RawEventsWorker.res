/************
**CONSTANTS**
*************/
let pageLimitSize = 50_000

module PreviousDynamicContractAddresses: {
  type registration = {address: Ethers.ethAddress, eventId: Ethers.BigInt.t}
  type matchingRegistration = SameOrLater(registration) | Earlier(registration)
  type t
  let make: unit => t
  let add: (t, registration) => unit
  let getRegistration: (t, Ethers.ethAddress, Ethers.BigInt.t) => option<matchingRegistration>
  let getUnusedContractRegistrations: (t, ContractAddressingMap.mapping) => array<Ethers.ethAddress>
} = {
  type registration = {address: Ethers.ethAddress, eventId: Ethers.BigInt.t}
  type t = Js.Dict.t<registration>

  let make = () => Js.Dict.empty()

  let ethAddressToString = Ethers.ethAddressToString
  module BigInt = Ethers.BigInt

  let add = (self: t, registration: registration) =>
    self->Js.Dict.set(registration.address->ethAddressToString, registration)

  let get = (self: t, address: Ethers.ethAddress) => {
    self->Js.Dict.get(address->ethAddressToString)
  }

  type matchingRegistration = SameOrLater(registration) | Earlier(registration)

  let getRegistration = (self: t, address, eventId: BigInt.t) => {
    self
    ->get(address)
    ->Belt.Option.map(reg => {
      reg.eventId->Ethers.BigInt.gte(eventId) ? SameOrLater(reg) : Earlier(reg)
    })
  }

  let getUnusedContractRegistrations = (
    self: t,
    currentRegistrations: ContractAddressingMap.mapping,
  ) => {
    open Belt
    self
    ->Js.Dict.values
    ->Array.keepMap(({address}) =>
      switch currentRegistrations->ContractAddressingMap.getContractNameFromAddress(
        ~contractAddress=address,
      ) {
      | Some(_) => None
      | None => Some(address)
      }
    )
  }
}

type rec t = {
  mutable latestFetchedBlockTimestamp: int,
  mutable latestFetchedEventId: promise<Ethers.BigInt.t>,
  chain: ChainMap.Chain.t,
  newRangeQueriedCallBacks: SDSL.Queue.t<unit => unit>,
  previousDynamicContractAddresses: PreviousDynamicContractAddresses.t,
  contractAddressMapping: ContractAddressingMap.mapping,
  caughtUpToHeadHook: option<t => promise<unit>>,
  //Used for fetching new dynamic contract events
  sourceWorker: SourceWorker.sourceWorker,
}

let stopFetchingEvents = (_self: t) => {
  Promise.resolve()
}

let make = (~caughtUpToHeadHook=?, ~contractAddressMapping=?, chainConfig: Config.chainConfig) => {
  let logger = Logging.createChild(
    ~params={
      "chainId": chainConfig.chain,
      "workerType": "Raw Events",
      "loggerFor": "Used only in logging regestration of static contract addresses",
    },
  )

  let contractAddressMapping = switch contractAddressMapping {
  | None =>
    let m = ContractAddressingMap.make()
    //Add all contracts and addresses from config
    //Dynamic contracts are checked in DB on start
    m->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)
    m
  | Some(m) => m
  }

  //Worker used for fetching new dynamcic contract events
  let sourceWorker = {
    open SourceWorker
    switch chainConfig.syncSource {
    | Rpc(_) => SourceWorker.Rpc(RpcWorker.make(~contractAddressMapping, chainConfig))
    | HyperSync(_) => HyperSync(HyperSyncWorker.make(~contractAddressMapping, chainConfig))
    }
  }

  //Add all contracts and addresses from config
  //Dynamic contracts are checked in DB on start
  contractAddressMapping->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)
  {
    latestFetchedBlockTimestamp: 0,
    latestFetchedEventId: Ethers.BigInt.fromInt(0)->Promise.resolve,
    chain: chainConfig.chain,
    newRangeQueriedCallBacks: SDSL.Queue.make(),
    contractAddressMapping,
    caughtUpToHeadHook,
    previousDynamicContractAddresses: PreviousDynamicContractAddresses.make(), //Initially empty, populated on fetching
    sourceWorker,
  }
}

let startWorker = async (
  self: t,
  ~startBlock: int,
  ~logger: Pino.t,
  ~fetchedEventQueue: ChainEventQueue.t,
  ~checkHasReorgOccurred,
) => {
  //ignore these two values
  let _ = (startBlock, logger, checkHasReorgOccurred)

  let eventIdRef = ref(0->Ethers.BigInt.fromInt)

  let hasMoreRawEvents = ref(true)

  while hasMoreRawEvents.contents {
    //Lock the latest fetched eventId until page returns and
    //Lock is to prevent race condition when looking up from dynamic contract registration
    let {
      pendingPromise: latestEventIdPromise,
      resolve: latestEventIdResolve,
    } = Utils.createPromiseWithHandles()

    //Store the previous value before locking with a pending promise
    let lastFetchedEventId = await self.latestFetchedEventId
    self.latestFetchedEventId = latestEventIdPromise
    //Always filter for contract addresses on each loop in case dynamic registrations have changed
    let contractAddresses = self.contractAddressMapping->ContractAddressingMap.getAllAddresses

    let page =
      await DbFunctions.sql->DbFunctions.RawEvents.getRawEventsPageGtOrEqEventId(
        ~chainId=self.chain->ChainMap.Chain.toChainId,
        ~eventId=eventIdRef.contents,
        ~limit=pageLimitSize,
        ~contractAddresses,
      )

    let parsedEventsUnsafe =
      page
      ->Belt.Array.map(Converters.parseRawEvent(~chain=self.chain))
      ->Utils.mapArrayOfResults
      ->Belt.Result.getExn

    for i in 0 to parsedEventsUnsafe->Belt.Array.length - 1 {
      let parsedEvent = parsedEventsUnsafe[i]

      let queueItem: Types.eventBatchQueueItem = {
        timestamp: parsedEvent.timestamp,
        chain: self.chain,
        blockNumber: parsedEvent.blockNumber,
        logIndex: parsedEvent.logIndex,
        event: parsedEvent.event,
      }

      await fetchedEventQueue->ChainEventQueue.awaitQueueSpaceAndPushItem(queueItem)

      //Loop through any callbacks on the queue waiting for confirmation of a new
      //range queried and run callbacks needs to happen after each item is added
      //else this we could be blocked from adding items to the queue and from popping
      //items off without running callbacks
      self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())
    }

    let lastItemInPage = page->Belt.Array.get(page->Belt.Array.length - 1)

    switch lastItemInPage {
    | None =>
      latestEventIdResolve(lastFetchedEventId)
      hasMoreRawEvents := false
    | Some(item) =>
      let lastEventId = item.eventId->Ethers.BigInt.fromStringUnsafe
      latestEventIdResolve(lastEventId)
      eventIdRef := lastEventId->Ethers.BigInt.add(1->Ethers.BigInt.fromInt)
      self.latestFetchedBlockTimestamp = item.blockTimestamp
    }
  }

  //Loop through any callbacks on the queue waiting for confirmation of a new
  //range queried and run callbacks
  self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())

  self.caughtUpToHeadHook->Belt.Option.map(hook => hook(self))->ignore
}

let startFetchingEvents = async (
  self: t,
  ~logger: Pino.t,
  ~fetchedEventQueue: ChainEventQueue.t,
  ~checkHasReorgOccurred,
) => {
  logger->Logging.childTrace({
    "msg": "Starting resync from cached events.",
  })

  //Add all dynamic contracts from DB
  let dynamicContracts =
    await DbFunctions.sql->DbFunctions.DynamicContractRegistry.readDynamicContractsOnChainIdAtOrBeforeBlock(
      ~chainId=self.chain->ChainMap.Chain.toChainId,
      ~startBlock=0,
    )

  dynamicContracts->Belt.Array.forEach(({contractAddress, eventId}) =>
    self.previousDynamicContractAddresses->PreviousDynamicContractAddresses.add({
      address: contractAddress,
      eventId,
    })
  )

  await self->startWorker(
    //Start block is not used in this function
    //Its simply there to comply with the signature
    ~startBlock=0,
    ~logger,
    ~fetchedEventQueue,
    ~checkHasReorgOccurred,
  )
}

let addNewRangeQueriedCallback = (self: t): promise<unit> => {
  self.newRangeQueriedCallBacks->ChainEventQueue.insertCallbackAwaitPromise
}

let getLatestFetchedBlockTimestamp = (self: t): int => self.latestFetchedBlockTimestamp

let getContractAddressMapping = (self: t) => self.contractAddressMapping

let compare = ({timestamp, chain, blockNumber, logIndex}: Types.eventBatchQueueItem) =>
  EventUtils.getEventComparator({
    timestamp,
    chainId: chain->ChainMap.Chain.toChainId,
    blockNumber,
    logIndex,
  })

let mergeSortEventBatches = (itemsA, itemsB) => compare->Utils.mergeSorted(itemsA, itemsB)

let sortOrderedEventBatchArrays = (batches: array<array<Types.eventBatchQueueItem>>) =>
  batches->Belt.Array.reduce([], (accum, nextBatch) => {
    accum->mergeSortEventBatches(nextBatch)
  })

let addDynamicContractAndFetchMissingEvents = async (
  self: t,
  ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ~fromBlock,
  ~fromLogIndex,
  ~logger,
): array<Types.eventBatchQueueItem> => {
  //Await for the lock on this before adding dynamic contracts to the
  //mapping
  let latestFetchedEventId = await self.latestFetchedEventId

  let eventIdOfStartOfBlock = EventUtils.packEventIndex(~blockNumber=fromBlock, ~logIndex=0)

  open Belt
  let unaddedDynamicContracts =
    dynamicContracts->Array.keep(({contractType, contractAddress}) =>
      self.contractAddressMapping->ContractAddressingMap.addAddressIfNotExists(
        ~name=contractType,
        ~address=contractAddress,
      )
    )

  //Sort unaddedDynamicContracts into 3 arrays for separate cases
  let (existingDynamicContracts, existingDynamicContractsWithMissingEvents, newDynamicContracts): (
    array<Ethers.ethAddress>,
    array<Types.dynamicContractRegistryEntity>,
    array<Types.dynamicContractRegistryEntity>,
  ) = unaddedDynamicContracts->Array.reduce(([], [], []), (
    (existingDynamicContracts, existingDynamicContractsWithMissingEvents, newDynamicContracts),
    contract,
  ) => {
    let previousDynamicContractRegistered =
      self.previousDynamicContractAddresses->PreviousDynamicContractAddresses.getRegistration(
        contract.contractAddress,
        contract.eventId,
      )

    switch previousDynamicContractRegistered {
    | Some(reg) =>
      switch reg {
      | SameOrLater(
          _,
        ) => //If the contract was registered at the same event or a later event as before,
        //We can continue because we have the events stored

        (
          existingDynamicContracts->Array.concat([contract.contractAddress]),
          existingDynamicContractsWithMissingEvents,
          newDynamicContracts,
        )
      | Earlier(
          _,
        ) => //If it was registered at an earlier event we need to fetch all the missing events up until
        //the time it was registered previously
        //Add the address to existing dynamic contracts and add to the missing events array
        (
          existingDynamicContracts->Array.concat([contract.contractAddress]),
          existingDynamicContractsWithMissingEvents->Array.concat([contract]),
          newDynamicContracts,
        )
      }
    //If there was no previously regiestered contract we need to fetch all events up until
    //the most recently stored event
    | None => (
        existingDynamicContracts,
        existingDynamicContractsWithMissingEvents,
        newDynamicContracts->Array.concat([contract]),
      )
    }
  })

  //Get raw events from the given event id up to where the latest fetched event id was
  //since the worker will handle fetching the rest of the dynamic contract events
  //In the next iteration
  let getPageFromRawEvents = (~fromEventId) =>
    DbFunctions.sql->DbFunctions.RawEvents.getRawEventsPageWithinEventIdRangeInclusive(
      ~limit=pageLimitSize,
      ~contractAddresses=existingDynamicContracts,
      ~chainId=self.chain->ChainMap.Chain.toChainId,
      ~fromEventIdInclusive=fromEventId,
      ~toEventIdInclusive=latestFetchedEventId,
    )

  //Recursively collect all existing raw events in relation to dynamic contracts
  let rec getExistingFromRawEvents: (
    ~queueItems: array<Types.eventBatchQueueItem>=?,
    ~fromEventId: Ethers.BigInt.t,
    unit,
  ) => promise<array<Types.eventBatchQueueItem>> = async (
    ~queueItems: option<array<Types.eventBatchQueueItem>>=?,
    ~fromEventId: Ethers.BigInt.t,
    (),
  ) => {
    let page = await getPageFromRawEvents(~fromEventId)
    let currentQueueItems = queueItems->Option.getWithDefault([])

    switch page {
    | [] => currentQueueItems
    | page =>
      let newQueueItems = page->Belt.Array.map(rawEvent => {
        let parsedEvent = rawEvent->Converters.parseRawEvent(~chain=self.chain)->Result.getExn
        let queueItem: Types.eventBatchQueueItem = {
          timestamp: parsedEvent.timestamp,
          chain: self.chain,
          blockNumber: parsedEvent.blockNumber,
          logIndex: parsedEvent.logIndex,
          event: parsedEvent.event,
        }
        queueItem
      })

      let lastItemInPage = page[page->Array.length - 1]->Option.getUnsafe
      let nextEventId = EventUtils.packEventIndex(
        ~blockNumber=lastItemInPage.blockNumber,
        ~logIndex=lastItemInPage.logIndex + 1,
      )

      let queueItems = currentQueueItems->Array.concat(newQueueItems)
      await getExistingFromRawEvents(~queueItems, ~fromEventId=nextEventId, ())
    }
  }

  let existingDynamicContractsQueueItems = getExistingFromRawEvents(
    ~fromEventId=eventIdOfStartOfBlock,
    (),
  )

  let missingDynamicContractQueueItems =
    existingDynamicContractsWithMissingEvents
    ->Array.map(dynamicContract => {
      //Fetch all missing events up until the block before the previous registration
      //where we already have stored events
      let {blockNumber} = dynamicContract.eventId->EventUtils.unpackEventIndex
      self.sourceWorker->SourceWorker.fetchArbitraryEvents(
        ~fromBlock,
        ~fromLogIndex,
        ~toBlock=blockNumber - 1,
        ~logger,
        ~dynamicContracts=[dynamicContract],
      )
    })
    ->Promise.all
    //Sort the responses
    ->Promise.thenResolve(sortOrderedEventBatchArrays)

  //Use the source worker to fetch all events up until the latest stored raw event
  //for new dynamic contract registrations
  let newDynamicContractsQueueItems = DbFunctions.RawEvents.getLatestProcessedBlockNumber(
    ~chainId=self.chain->ChainMap.Chain.toChainId,
  )->Promise.then(latestRawEventBlock =>
    switch latestRawEventBlock {
    | Some(toBlock) =>
      self.sourceWorker->SourceWorker.fetchArbitraryEvents(
        ~fromBlock,
        ~fromLogIndex,
        ~toBlock,
        ~logger,
        ~dynamicContracts=newDynamicContracts,
      )
    | None => Promise.resolve([])
    }
  )

  //Sort responses from raw events and source worker
  await Promise.all([
    existingDynamicContractsQueueItems,
    missingDynamicContractQueueItems,
    newDynamicContractsQueueItems,
  ])->Promise.thenResolve(sortOrderedEventBatchArrays)
}

let getCurrentBlockHeight = (_self: t) => {
  Js.Exn.raiseError("Current block height not implemented for raw events worker")
}
