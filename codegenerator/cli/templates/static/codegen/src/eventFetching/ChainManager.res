type t = {
  chainFetchers: ChainMap.t<ChainFetcher.t>,
  //The priority queue should only house the latest event from each chain
  //And potentially extra events that are pushed on by newly registered dynamic
  //contracts which missed being fetched by they chainFetcher
  arbitraryEventPriorityQueue: list<Types.eventBatchQueueItem>,
}

let getComparitorFromItem = (queueItem: Types.eventBatchQueueItem) => {
  let {timestamp, chain, blockNumber, logIndex} = queueItem
  EventUtils.getEventComparator({
    timestamp,
    chainId: chain->ChainMap.Chain.toChainId,
    blockNumber,
    logIndex,
  })
}

type multiChainEventComparitor = {
  chain: ChainMap.Chain.t,
  latestEventResponse: DynamicContractFetcher.latestEventResponse,
}

let getQueueItemComparitor = (latestQueueItem: DynamicContractFetcher.queueItem, ~chain) => {
  switch latestQueueItem {
  | Item(i) => i->getComparitorFromItem
  | NoItem(latestFetchedBlockTimestamp) => (
      latestFetchedBlockTimestamp,
      chain->ChainMap.Chain.toChainId,
      0,
      0,
    )
  }
}

let priorityQueueComparitor = (a: Types.eventBatchQueueItem, b: Types.eventBatchQueueItem) => {
  if a->getComparitorFromItem < b->getComparitorFromItem {
    -1
  } else {
    1
  }
}

let isQueueItemEarlier = (a: multiChainEventComparitor, b: multiChainEventComparitor): bool => {
  a.latestEventResponse.earliestQueueItem->getQueueItemComparitor(~chain=a.chain) <
    b.latestEventResponse.earliestQueueItem->getQueueItemComparitor(~chain=b.chain)
}

// This is similar to `chainFetcherPeekComparitorEarliestEvent`, but it prioritizes events over `NoItem` no matter what the timestamp of `NoItem` is.
let chainFetcherPeekComparitorEarliestEventPrioritizeEvents = (
  a: multiChainEventComparitor,
  b: multiChainEventComparitor,
): bool => {
  switch (a.latestEventResponse.earliestQueueItem, b.latestEventResponse.earliestQueueItem) {
  | (Item(_), NoItem(_)) => true
  | (NoItem(_), Item(_)) => false
  | _ => isQueueItemEarlier(a, b)
  }
}

exception NoItemsInArray

let createDetermineNextEventFunction = (
  ~isUnorderedHeadMode: bool,
  fetchers: ChainMap.t<DynamicContractFetcher.t>,
): result<multiChainEventComparitor, exn> => {
  open Belt
  let comparitorFunction = if isUnorderedHeadMode {
    chainFetcherPeekComparitorEarliestEventPrioritizeEvents
  } else {
    isQueueItemEarlier
  }

  let nextItem =
    fetchers
    ->ChainMap.entries
    ->Array.reduce(None, (accum, (chain, fetcher)) => {
      let latestEventResponse = fetcher->DynamicContractFetcher.getEarliestEvent
      let cmpA = {chain, latestEventResponse}
      switch accum {
      | None => cmpA
      | Some(cmpB) =>
        if comparitorFunction(cmpB, cmpA) {
          cmpB
        } else {
          cmpA
        }
      }->Some
    })

  switch nextItem {
  | None => Error(NoItemsInArray)
  | Some(item) => Ok(item)
  }
}

let determineNextEvent = createDetermineNextEventFunction(
  ~isUnorderedHeadMode=Config.isUnorderedHeadMode,
)

let make = (~configs: Config.chainConfigs, ~maxQueueSize, ~shouldSyncFromRawEvents: bool): t => {
  let chainFetchers = configs->ChainMap.map(chainConfig => {
    let lastBlockScannedHashes = ReorgDetection.LastBlockScannedHashes.empty(
      ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
    )

    ChainFetcher.make(
      ~chainConfig,
      ~maxQueueSize,
      ~shouldSyncFromRawEvents,
      ~lastBlockScannedHashes,
    )
  })

  {
    chainFetchers,
    arbitraryEventPriorityQueue: list{},
  }
}

exception NotASourceWorker
let toSourceWorker = (worker: ChainWorker.chainWorker): SourceWorker.sourceWorker =>
  switch worker {
  | HyperSync(w) => HyperSync(w)
  | Rpc(w) => Rpc(w)
  | RawEvents(_) => NotASourceWorker->raise
  }

//TODO this needs to action a roll back
let reorgStub = async (chainManager: t, ~chainFetcher: ChainFetcher.t, ~lastBlockScannedData) => {
  //get a list of block hashes via the chainworker
  let blockNumbers =
    chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.getAllBlockNumbers
  let blockNumbersAndHashes =
    await chainFetcher.chainWorker.contents
    ->toSourceWorker
    ->SourceWorker.getBlockHashes(~blockNumbers)
    ->Promise.thenResolve(Belt.Result.getExn)

  let rolledBack =
    chainFetcher.lastBlockScannedHashes
    ->ReorgDetection.LastBlockScannedHashes.rollBackToValidHash(~blockNumbersAndHashes)
    ->Belt.Result.getExn

  let reorgStartPlace = rolledBack->ReorgDetection.LastBlockScannedHashes.getLatestLastBlockData

  switch reorgStartPlace {
  | Some({blockNumber, blockTimestamp}) => () //Rollback to here
  | None => () //roll back to start of chain. Can't really happen
  }
  //Stop workers
  //Roll back
  //Start workers again
  let _ = chainManager
  Logging.warn({
    "msg": "A Reorg Has occurred",
    "chainId": chainFetcher.chainConfig.chain->ChainMap.Chain.toChainId,
    "lastBlockScannedData": lastBlockScannedData,
  })
}

/**
For each chain with a confirmed block threshold, find the earliest block ranged scanned that exists
in that threshold

Returns None in the case of no block range entries and in the case that there is only 1 chain since
there is no need to consider other chains with prunining in this case
*/
let getEarliestMultiChainTimestampInThreshold = (chainManager: t) => {
  chainManager.chainFetchers
  ->ChainMap.values
  ->Belt.Array.map((cf): ReorgDetection.LastBlockScannedHashes.currentHeightAndLastBlockHashes => {
    lastBlockScannedHashes: cf.lastBlockScannedHashes,
    currentHeight: cf.chainWorker.contents->ChainWorker.getCurrentBlockHeight,
  })
  ->ReorgDetection.LastBlockScannedHashes.getEarliestMultiChainTimestampInThreshold
}

/**
Checks whether reorg has accured by comparing the parent hash with the last saved block hash.
*/
let hasReorgOccurred = (chainFetcher: ChainFetcher.t, ~parentHash) => {
  let recentLastBlockData =
    chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.getLatestLastBlockData

  switch (parentHash, recentLastBlockData) {
  | (None, None) => false
  | (None, Some(_)) | (Some(_), None) => true
  | (Some(parentHash), Some({blockHash})) => parentHash == blockHash
  }
}

/**
Adds latest "lastBlockScannedData" to LastBlockScannedHashes and prunes old unneeded data
*/
let addLastBlockScannedData = (
  chainFetcher: ChainFetcher.t,
  ~chainManager: t,
  ~lastBlockScannedData: ReorgDetection.lastBlockScannedData,
  ~currentHeight,
) => {
  let earliestMultiChainTimestampInThreshold =
    chainManager->getEarliestMultiChainTimestampInThreshold

  chainFetcher.lastBlockScannedHashes =
    chainFetcher.lastBlockScannedHashes
    ->ReorgDetection.LastBlockScannedHashes.pruneStaleBlockData(
      ~currentHeight,
      ~earliestMultiChainTimestampInThreshold?,
    )
    ->ReorgDetection.LastBlockScannedHashes.addLatestLastBlockData(~lastBlockScannedData)
}

/**
A function that gets partially applied as it is handed down from
chain manager to chain fetcher to chain worker
*/
let checkHasReorgOccurred = (
  chainManager: t,
  chainFetcher: ChainFetcher.t,
  lastBlockScannedData,
  ~parentHash,
  ~currentHeight,
) => {
  let hasReorgOccurred = chainFetcher->hasReorgOccurred(~parentHash)

  if hasReorgOccurred {
    chainManager->reorgStub(~chainFetcher, ~lastBlockScannedData)->ignore
  } else {
    chainFetcher->addLastBlockScannedData(~chainManager, ~currentHeight, ~lastBlockScannedData)
  }
}

// let startFetchers = (self: t) => {
//   self.chainFetchers
//   ->ChainMap.values
//   ->Belt.Array.forEach(fetcher => {
//     //Start the fetchers
//     fetcher
//     ->ChainFetcher.startFetchingEvents(~checkHasReorgOccurred=self->checkHasReorgOccurred)
//     ->ignore
//   })
// }

let getChainFetcher = (self: t, ~chain: ChainMap.Chain.t): ChainFetcher.t => {
  self.chainFetchers->ChainMap.get(chain)
}

//Synchronus operation that returns an optional value and will not wait
//for a value to be on the queue
//TODO: investigate can this function + Async version below be combined to share
//logic
type earliestQueueItem =
  | ArbitraryEventQueue(Types.eventBatchQueueItem, list<Types.eventBatchQueueItem>)
  | EventFetchers(Types.eventBatchQueueItem, ChainMap.t<DynamicContractFetcher.t>)

let popBatchItem = (
  ~fetchers: ChainMap.t<DynamicContractFetcher.t>,
  ~arbitraryEventQueue: list<Types.eventBatchQueueItem>,
): option<earliestQueueItem> => {
  open Belt

  //Compare the peeked items and determine the next item
  let {chain, latestEventResponse: {updatedFetcher, earliestQueueItem}} =
    fetchers->determineNextEvent->Result.getExn

  switch arbitraryEventQueue {
  //If there is item on the arbitray events queue, and it is earlier than
  //than the earlist event, take the item off from there
  | list{item, ...tail}
    if Item(item)->getQueueItemComparitor(~chain=item.chain) <
      earliestQueueItem->getQueueItemComparitor(~chain) =>
    Some(ArbitraryEventQueue(item, tail))
  | _ =>
    //Otherwise take the latest item from the fetchers
    switch earliestQueueItem {
    | NoItem(_) => None
    | Item(qItem) =>
      let updatedFetchers = fetchers->ChainMap.set(chain, updatedFetcher)
      EventFetchers(qItem, updatedFetchers)->Some
    }
  }
}

let getChainIdFromBufferPeekItem = (peekItem: ChainFetcher.queueFront) => {
  switch peekItem {
  | ChainFetcher.NoItem(_, chainId) => chainId
  | ChainFetcher.Item(batchItem) => batchItem.chain
  }
}
let getBlockNumberFromBufferPeekItem = (peekItem: ChainFetcher.queueFront) => {
  switch peekItem {
  | ChainFetcher.NoItem(_, _) => None
  | ChainFetcher.Item(batchItem) => Some(batchItem.blockNumber)
  }
}

// /**
// Async pop function that will wait for an item to be available before returning
// */
// let rec popAndAwaitBatchItem: t => promise<Types.eventBatchQueueItem> = async (
//   self: t,
// ): Types.eventBatchQueueItem => {
//   //Peek all next fetched event queue items on all chain fetchers
//   let peekChainFetcherFrontItems =
//     self.chainFetchers
//     ->ChainMap.values
//     ->Belt.Array.map(fetcher => fetcher->ChainFetcher.peekFrontItemOfQueue)
//
//   //Compare the peeked items and determine the next item
//   let nextItemFromBuffer = peekChainFetcherFrontItems->determineNextEvent->Belt.Result.getExn
//
//   //Callback for handling popping of chain fetcher events
//   let popNextItemAndAwait = async () => {
//     switch nextItemFromBuffer {
//     | ChainFetcher.NoItem(_, chain) =>
//       //If higest priority is a "NoItem", it means we need to wait for
//       //that chain fetcher to fetch blocks of a higher timestamp
//       let fetcher = self->getChainFetcher(~chain)
//       //Add a callback and wait for a new block range to finish being queried
//       await fetcher->ChainFetcher.addNewRangeQueriedCallback
//       //Once there is confirmation from the chain fetcher that a new range has been
//       //queried retry the popAwait batch function
//       await self->popAndAwaitBatchItem
//     | ChainFetcher.Item(batchItem) =>
//       //If there is an item pop it off of the chain fetcher queue and return
//       let fetcher = self->getChainFetcher(~chain=batchItem.chain)
//       await fetcher->ChainFetcher.popAndAwaitQueueItem
//     }
//   }
//
//   //Peek arbitraty events queue
//   let peekedArbTopItem = self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.top
//
//   switch peekedArbTopItem {
//   //If there is item on the arbitray events queue, pop the relevant item from
//   //the chain fetcher queue
//   | None => await popNextItemAndAwait()
//   | Some(peekedArbItem) =>
//     //If there is an item on the arbitrary events queue, compare it to the next
//     //item from the chain fetchers
//     let arbItemIsEarlier = chainFetcherPeekComparitorEarliestEvent(
//       ChainFetcher.Item(peekedArbItem),
//       nextItemFromBuffer,
//     )
//
//     //If the arbitrary item is earlier, return that
//     if arbItemIsEarlier {
//       //safely pop the item since we have already checked there's one at the front
//       self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.pop->Belt.Option.getUnsafe
//     } else {
//       //Else pop the next item from chain fetchers
//       await popNextItemAndAwait()
//     }
//   }
// }

// let createBatch = async (self: t, ~minBatchSize: int, ~maxBatchSize: int): array<
//   Types.eventBatchQueueItem,
// > => {
//   let refTime = Hrtime.makeTimer()
//
//   let batch = []
//   while batch->Belt.Array.length < minBatchSize {
//     let item = await self->popAndAwaitBatchItem
//     batch->Js.Array2.push(item)->ignore
//   }
//
//   let moreItemsToPop = ref(true)
//   while moreItemsToPop.contents && batch->Belt.Array.length < maxBatchSize {
//     let optItem = self->popBatchItem(~shouldAwaitArbQueueItem=false)
//     switch optItem {
//     | None => moreItemsToPop := false
//     | Some(item) => batch->Js.Array2.push(item)->ignore
//     }
//   }
//   let fetchedEventsBuffer =
//     self.chainFetchers
//     ->ChainMap.values
//     ->Belt.Array.map(fetcher => (
//       fetcher.chainConfig.chain->ChainMap.Chain.toString,
//       fetcher.fetchedEventQueue.queue->SDSL.Queue.size,
//     ))
//     ->Belt.Array.concat([
//       ("arbitrary", self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.length),
//     ])
//     ->Js.Dict.fromArray
//
//   let timeElapsed = refTime->Hrtime.timeSince->Hrtime.toMillis
//
//   Logging.trace({
//     "message": "New batch created for processing",
//     "batch size": batch->Array.length,
//     "buffers": fetchedEventsBuffer,
//     "time taken (ms)": timeElapsed,
//   })
//
//   batch
// }

type batchRes = {
  batch: list<Types.eventBatchQueueItem>,
  batchSize: int,
  fetchers: ChainMap.t<DynamicContractFetcher.t>,
  arbitraryEventQueue: list<Types.eventBatchQueueItem>,
}

let makeBatch = (~batchRev, ~currentBatchSize, ~fetchers, ~arbitraryEventQueue) => {
  batch: batchRev->Belt.List.reverse,
  fetchers,
  arbitraryEventQueue,
  batchSize: currentBatchSize,
}

let rec createBatchInternal = (
  ~maxBatchSize,
  ~currentBatchSize,
  ~fetchers,
  ~arbitraryEventQueue,
  ~batchRev,
) => {
  open Belt
  if currentBatchSize >= maxBatchSize {
    makeBatch(~batchRev, ~currentBatchSize, ~fetchers, ~arbitraryEventQueue)
  } else {
    switch popBatchItem(~fetchers, ~arbitraryEventQueue) {
    | None => makeBatch(~batchRev, ~currentBatchSize, ~fetchers, ~arbitraryEventQueue)
    | Some(item) =>
      let (arbitraryEventQueue, fetchers, nextItem) = switch item {
      | ArbitraryEventQueue(item, arbitraryEventQueue) => (arbitraryEventQueue, fetchers, item)
      | EventFetchers(item, fetchers) => (arbitraryEventQueue, fetchers, item)
      }
      createBatchInternal(
        //TODO make this use a list with reverse rather than array concat
        ~batchRev=list{nextItem, ...batchRev},
        ~maxBatchSize,
        ~arbitraryEventQueue,
        ~fetchers,
        ~currentBatchSize=currentBatchSize + 1,
      )
    }
  }
}

let createBatch = (self: t, ~maxBatchSize: int) => {
  open Belt
  let refTime = Hrtime.makeTimer()

  let {arbitraryEventPriorityQueue, chainFetchers} = self
  let fetchers = chainFetchers->ChainMap.map(cf => cf.fetcher)

  let response = createBatchInternal(
    ~maxBatchSize,
    ~batchRev=list{},
    ~currentBatchSize=0,
    ~fetchers,
    ~arbitraryEventQueue=arbitraryEventPriorityQueue,
  )

  if response.batchSize > 0 {
    let fetchedEventsBuffer =
      chainFetchers
      ->ChainMap.values
      ->Array.map(fetcher => (
        fetcher.chainConfig.chain->ChainMap.Chain.toString,
        fetcher.fetcher->DynamicContractFetcher.queueSize,
      ))
      ->Array.concat([("arbitrary", self.arbitraryEventPriorityQueue->List.size)])
      ->Js.Dict.fromArray

    let timeElapsed = refTime->Hrtime.timeSince->Hrtime.toMillis

    Logging.trace({
      "message": "New batch created for processing",
      "batch size": response.batchSize,
      "buffers": fetchedEventsBuffer,
      "time taken (ms)": timeElapsed,
    })

    Some(response)
  } else {
    None
  }
}

module ExposedForTesting_Hidden = {
  let priorityQueueComparitor = priorityQueueComparitor
  let getComparitorFromItem = getComparitorFromItem
  let createDetermineNextEventFunction = createDetermineNextEventFunction
}
