open Belt
type t = {
  chainFetchers: ChainMap.t<ChainFetcher.t>,
  //The priority queue should only house the latest event from each chain
  //And potentially extra events that are pushed on by newly registered dynamic
  //contracts which missed being fetched by they chainFetcher
  arbitraryEventPriorityQueue: list<Types.eventBatchQueueItem>,
  isUnorderedMultichainMode: bool,
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
  earliestEventResponse: FetchState.earliestEventResponse,
}

let getQueueItemComparitor = (earliestQueueItem: FetchState.queueItem, ~chain) => {
  switch earliestQueueItem {
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
  a.earliestEventResponse.earliestQueueItem->getQueueItemComparitor(~chain=a.chain) <
    b.earliestEventResponse.earliestQueueItem->getQueueItemComparitor(~chain=b.chain)
}

// This is similar to `chainFetcherPeekComparitorEarliestEvent`, but it prioritizes events over `NoItem` no matter what the timestamp of `NoItem` is.
let chainFetcherPeekComparitorEarliestEventPrioritizeEvents = (
  a: multiChainEventComparitor,
  b: multiChainEventComparitor,
): bool => {
  switch (a.earliestEventResponse.earliestQueueItem, b.earliestEventResponse.earliestQueueItem) {
  | (Item(_), NoItem(_)) => true
  | (NoItem(_), Item(_)) => false
  | _ => isQueueItemEarlier(a, b)
  }
}

exception NoItemsInArray

let determineNextEvent = (
  ~isUnorderedMultichainMode: bool,
  fetchStatesMap: ChainMap.t<FetchState.t>,
): result<multiChainEventComparitor, exn> => {
  let comparitorFunction = if isUnorderedMultichainMode {
    chainFetcherPeekComparitorEarliestEventPrioritizeEvents
  } else {
    isQueueItemEarlier
  }

  let nextItem =
    fetchStatesMap
    ->ChainMap.entries
    ->Array.reduce(None, (accum, (chain, fetchState)) => {
      let earliestEventResponse = fetchState->FetchState.getEarliestEvent
      let cmpA = {chain, earliestEventResponse}
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
  | None => Error(NoItemsInArray) //Should not hit this case
  | Some(item) => Ok(item)
  }
}

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
    isUnorderedMultichainMode: Config.isUnorderedMultichainMode,
  }
}

let makeFromDbState = async (~configs: Config.chainConfigs): t => {
  let chainFetchersArr =
    await configs
    ->ChainMap.entries
    ->Array.map(async ((chain, chainConfig)) => {
      let lastBlockScannedHashes = ReorgDetection.LastBlockScannedHashes.empty(
        ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
      )

      (chain, await chainConfig->ChainFetcher.makeFromDbState(~lastBlockScannedHashes))
    })
    ->Promise.all

  let chainFetchers = ChainMap.fromArray(chainFetchersArr)->Utils.unwrapResultExn //Can safely unwrap since it is being mapped from Config

  {
    isUnorderedMultichainMode: Config.isUnorderedMultichainMode,
    arbitraryEventPriorityQueue: list{},
    chainFetchers,
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
  | EventFetchers(Types.eventBatchQueueItem, ChainMap.t<FetchState.t>)

let rec getFirstArbitraryEventsItemForChain = (
  ~revHead=list{},
  ~chain,
  queue: list<Types.eventBatchQueueItem>,
) => {
  switch queue {
  | list{} => None
  | list{first, ...tail} =>
    if first.chain == chain {
      let rest = revHead->List.reverseConcat(tail)
      Some((first, rest))
    } else {
      tail->getFirstArbitraryEventsItemForChain(~chain, ~revHead=list{first, ...revHead})
    }
  }
}

let getFirstArbitraryEventsItem = (queue: list<Types.eventBatchQueueItem>) =>
  switch queue {
  | list{} => None
  | list{first, ...tail} => Some((first, tail))
  }

let popBatchItem = (
  ~fetchStatesMap: ChainMap.t<FetchState.t>,
  ~arbitraryEventQueue: list<Types.eventBatchQueueItem>,
  ~isUnorderedMultichainMode,
): option<earliestQueueItem> => {
  //Compare the peeked items and determine the next item
  let {chain, earliestEventResponse: {updatedFetchState, earliestQueueItem}} =
    fetchStatesMap->determineNextEvent(~isUnorderedMultichainMode)->Utils.unwrapResultExn

  let maybeArbItem = if isUnorderedMultichainMode {
    arbitraryEventQueue->getFirstArbitraryEventsItemForChain(~chain)
  } else {
    arbitraryEventQueue->getFirstArbitraryEventsItem
  }
  switch maybeArbItem {
  //If there is item on the arbitray events queue, and it is earlier than
  //than the earlist event, take the item off from there
  | Some((qItem, updatedArbQueue))
    if Item(qItem)->getQueueItemComparitor(~chain=qItem.chain) <
      earliestQueueItem->getQueueItemComparitor(~chain) =>
    Some(ArbitraryEventQueue(qItem, updatedArbQueue))
  | _ =>
    //Otherwise take the latest item from the fetchers
    switch earliestQueueItem {
    | NoItem(_) => None
    | Item(qItem) =>
      let updatedFetchStatesMap = fetchStatesMap->ChainMap.set(chain, updatedFetchState)
      EventFetchers(qItem, updatedFetchStatesMap)->Some
    }
  }
}

type batchRes = {
  batch: list<Types.eventBatchQueueItem>,
  batchSize: int,
  fetchStatesMap: ChainMap.t<FetchState.t>,
  arbitraryEventQueue: list<Types.eventBatchQueueItem>,
}

let makeBatch = (~batchRev, ~currentBatchSize, ~fetchStatesMap, ~arbitraryEventQueue) => {
  batch: batchRev->List.reverse,
  fetchStatesMap,
  arbitraryEventQueue,
  batchSize: currentBatchSize,
}

let rec createBatchInternal = (
  ~maxBatchSize,
  ~currentBatchSize,
  ~fetchStatesMap,
  ~arbitraryEventQueue,
  ~batchRev,
  ~isUnorderedMultichainMode,
) => {
  if currentBatchSize >= maxBatchSize {
    makeBatch(~batchRev, ~currentBatchSize, ~fetchStatesMap, ~arbitraryEventQueue)
  } else {
    switch popBatchItem(~fetchStatesMap, ~arbitraryEventQueue, ~isUnorderedMultichainMode) {
    | None => makeBatch(~batchRev, ~currentBatchSize, ~fetchStatesMap, ~arbitraryEventQueue)
    | Some(item) =>
      let (arbitraryEventQueue, fetchStatesMap, nextItem) = switch item {
      | ArbitraryEventQueue(item, arbitraryEventQueue) => (
          arbitraryEventQueue,
          fetchStatesMap,
          item,
        )
      | EventFetchers(item, fetchStatesMap) => (arbitraryEventQueue, fetchStatesMap, item)
      }
      createBatchInternal(
        //TODO make this use a list with reverse rather than array concat
        ~batchRev=list{nextItem, ...batchRev},
        ~maxBatchSize,
        ~arbitraryEventQueue,
        ~fetchStatesMap,
        ~currentBatchSize=currentBatchSize + 1,
        ~isUnorderedMultichainMode,
      )
    }
  }
}

let createBatch = (self: t, ~maxBatchSize: int) => {
  let refTime = Hrtime.makeTimer()

  let {arbitraryEventPriorityQueue, chainFetchers} = self
  let fetchStatesMap = chainFetchers->ChainMap.map(cf => cf.fetchState)

  let response = createBatchInternal(
    ~maxBatchSize,
    ~batchRev=list{},
    ~currentBatchSize=0,
    ~fetchStatesMap,
    ~arbitraryEventQueue=arbitraryEventPriorityQueue,
    ~isUnorderedMultichainMode=self.isUnorderedMultichainMode,
  )

  if response.batchSize > 0 {
    let fetchedEventsBuffer =
      chainFetchers
      ->ChainMap.values
      ->Array.map(fetcher => (
        fetcher.chainConfig.chain->ChainMap.Chain.toString,
        fetcher.fetchState->FetchState.queueSize,
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
  let createDetermineNextEventFunction = determineNextEvent
}
