open Belt
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
  | NoItem({timestamp, blockNumber}) => (timestamp, chain->ChainMap.Chain.toChainId, blockNumber, 0)
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

let makeFromConfig = (~configs: Config.chainConfigs): t => {
  let chainFetchers = configs->ChainMap.map(chainConfig => {
    let lastBlockScannedHashes = ReorgDetection.LastBlockScannedHashes.empty(
      ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
    )

    chainConfig->ChainFetcher.makeFromConfig(~lastBlockScannedHashes)
  })

  {
    chainFetchers,
    arbitraryEventPriorityQueue: list{},
  }
}

let makeFromDbState = async (~configs: Config.chainConfigs): t => {
  let initial = makeFromConfig(~configs)
  let dbStateInitialized =
    await configs
    ->ChainMap.values
    ->Array.map(chainConfig => {
      let lastBlockScannedHashes = ReorgDetection.LastBlockScannedHashes.empty(
        ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
      )

      chainConfig->ChainFetcher.makeFromDbState(~lastBlockScannedHashes)
    })
    ->Promise.all

  let chainFetchers =
    dbStateInitialized->Array.reduce(initial.chainFetchers, (accum, chainFetcher) =>
      accum->ChainMap.set(chainFetcher.chainConfig.chain, chainFetcher)
    )

  {
    chainFetchers,
    arbitraryEventPriorityQueue: list{},
  }
}

exception NotASourceWorker
let toSourceWorker = (worker: SourceWorker.sourceWorker): SourceWorker.sourceWorker => worker

//TODO this needs to action a roll back
let reorgStub = async (chainManager: t, ~chainFetcher: ChainFetcher.t, ~lastBlockScannedData) => {
  //get a list of block hashes via the chainworker
  let blockNumbers =
    chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.getAllBlockNumbers
  let blockNumbersAndHashes =
    await chainFetcher.chainWorker
    ->toSourceWorker
    ->SourceWorker.getBlockHashes(~blockNumbers)
    ->Promise.thenResolve(Result.getExn)

  let rolledBack =
    chainFetcher.lastBlockScannedHashes
    ->ReorgDetection.LastBlockScannedHashes.rollBackToValidHash(~blockNumbersAndHashes)
    ->Result.getExn

  let reorgStartPlace = rolledBack->ReorgDetection.LastBlockScannedHashes.getLatestLastBlockData

  switch reorgStartPlace {
  | Some({blockNumber, blockTimestamp}) => (blockNumber, blockTimestamp)->ignore //Rollback to here
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
  ->Array.map((cf): ReorgDetection.LastBlockScannedHashes.currentHeightAndLastBlockHashes => {
    lastBlockScannedHashes: cf.lastBlockScannedHashes,
    currentHeight: cf.currentBlockHeight,
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

let getChainFetcher = (self: t, ~chain: ChainMap.Chain.t): ChainFetcher.t => {
  self.chainFetchers->ChainMap.get(chain)
}

type earliestQueueItem =
  | ArbitraryEventQueue(Types.eventBatchQueueItem, list<Types.eventBatchQueueItem>)
  | EventFetchers(Types.eventBatchQueueItem, ChainMap.t<DynamicContractFetcher.t>)

let popBatchItem = (
  ~fetchers: ChainMap.t<DynamicContractFetcher.t>,
  ~arbitraryEventQueue: list<Types.eventBatchQueueItem>,
): option<earliestQueueItem> => {
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

type batchRes = {
  batch: list<Types.eventBatchQueueItem>,
  batchSize: int,
  fetchers: ChainMap.t<DynamicContractFetcher.t>,
  arbitraryEventQueue: list<Types.eventBatchQueueItem>,
}

let makeBatch = (~batchRev, ~currentBatchSize, ~fetchers, ~arbitraryEventQueue) => {
  batch: batchRev->List.reverse,
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
