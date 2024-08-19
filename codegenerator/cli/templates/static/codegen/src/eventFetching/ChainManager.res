open Belt
type t = {
  chainFetchers: ChainMap.t<ChainFetcher.t>,
  //Holds arbitrary events that were added when a batch ended processing early
  //due to contract registration
  arbitraryEventQueue: array<Types.eventBatchQueueItem>,
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
  earliestEventResponse: PartitionedFetchState.earliestEventResponse,
}

let getQueueItemComparitor = (earliestQueueItem: FetchState.queueItem, ~chain) => {
  switch earliestQueueItem {
  | Item(i) => i->getComparitorFromItem
  | NoItem({blockTimestamp, blockNumber}) => (
      blockTimestamp,
      chain->ChainMap.Chain.toChainId,
      blockNumber,
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

type noItemsInArray = NoItemsInArray

let determineNextEvent = (
  ~isUnorderedMultichainMode: bool,
  fetchStatesMap: ChainMap.t<PartitionedFetchState.t>,
): result<multiChainEventComparitor, noItemsInArray> => {
  let comparitorFunction = if isUnorderedMultichainMode {
    chainFetcherPeekComparitorEarliestEventPrioritizeEvents
  } else {
    isQueueItemEarlier
  }

  let nextItem =
    fetchStatesMap
    ->ChainMap.entries
    ->Array.reduce(None, (accum, (chain, partitionedFetchState)) => {
      // If the fetch state has reached the end block we don't need to consider it
      switch partitionedFetchState->PartitionedFetchState.getEarliestEvent {
      | Some(earliestEventResponse) =>
        let cmpA: multiChainEventComparitor = {chain, earliestEventResponse}
        switch accum {
        | None => cmpA
        | Some(cmpB) =>
          if comparitorFunction(cmpB, cmpA) {
            cmpB
          } else {
            cmpA
          }
        }->Some
      | None => accum
      }
    })

  switch nextItem {
  | None => Error(NoItemsInArray)
  | Some(item) => Ok(item)
  }
}

let makeFromConfig = (
  ~config: Config.t,
  ~maxAddrInPartition=Env.maxAddrInPartition,
): t => {
  let chainFetchers = config.chainMap->ChainMap.map(ChainFetcher.makeFromConfig(_, ~maxAddrInPartition))
  {
    chainFetchers,
    arbitraryEventQueue: [],
    isUnorderedMultichainMode: config.isUnorderedMultichainMode,
  }
}

let makeFromDbState = async (~config: Config.t, ~maxAddrInPartition=Env.maxAddrInPartition): t => {
  let chainFetchersArr =
    await config.chainMap
    ->ChainMap.entries
    ->Array.map(async ((chain, chainConfig)) => {
      (chain, await chainConfig->ChainFetcher.makeFromDbState(~maxAddrInPartition))
    })
    ->Promise.all

  let chainFetchers = ChainMap.fromArrayUnsafe(chainFetchersArr)

  {
    isUnorderedMultichainMode: config.isUnorderedMultichainMode,
    arbitraryEventQueue: [],
    chainFetchers,
  }
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
Adds latest "lastBlockScannedData" to LastBlockScannedHashes and prunes old unneeded data
*/
let addLastBlockScannedData = (
  chainManager: t,
  ~chain: ChainMap.Chain.t,
  ~lastBlockScannedData: ReorgDetection.blockData,
  ~currentHeight,
) => {
  let earliestMultiChainTimestampInThreshold =
    chainManager->getEarliestMultiChainTimestampInThreshold

  let chainFetchers = chainManager.chainFetchers->ChainMap.update(chain, cf => {
    let lastBlockScannedHashes =
      cf.lastBlockScannedHashes
      ->ReorgDetection.LastBlockScannedHashes.pruneStaleBlockData(
        ~currentHeight,
        ~earliestMultiChainTimestampInThreshold?,
      )
      ->ReorgDetection.LastBlockScannedHashes.addLatestLastBlockData(~lastBlockScannedData)
    {
      ...cf,
      lastBlockScannedHashes,
    }
  })

  {
    ...chainManager,
    chainFetchers,
  }
}

let getChainFetcher = (self: t, ~chain: ChainMap.Chain.t): ChainFetcher.t => {
  self.chainFetchers->ChainMap.get(chain)
}

let setChainFetcher = (self: t, chainFetcher: ChainFetcher.t) => {
  {
    ...self,
    chainFetchers: self.chainFetchers->ChainMap.set(chainFetcher.chainConfig.chain, chainFetcher),
  }
}

type earliestQueueItem =
  | ArbitraryEventQueue(Types.eventBatchQueueItem, array<Types.eventBatchQueueItem>)
  | EventFetchers(Types.eventBatchQueueItem, ChainMap.t<PartitionedFetchState.t>)

let rec getFirstArbitraryEventsItemForChain = (
  queue: array<Types.eventBatchQueueItem>,
  ~index=0,
  ~head=[],
  ~chain,
) => {
  switch queue[index] {
  | None => None
  | Some(first) =>
    let nextIndex = index + 1
    if first.chain == chain {
      Some((first, () => queue->Utils.Array.removeAtIndex(~index)))
    } else {
      let _ = head->Js.Array2.push(first)
      queue->getFirstArbitraryEventsItemForChain(~chain, ~index=nextIndex, ~head)
    }
  }
}

let getFirstArbitraryEventsItem = (queue: array<Types.eventBatchQueueItem>) =>
  switch queue[0] {
  | None => None
  | Some(first) => Some((first, () => Array.sliceToEnd(queue, 1)))
  }

let popBatchItem = (
  ~fetchStatesMap: ChainMap.t<PartitionedFetchState.t>,
  ~arbitraryEventQueue: array<Types.eventBatchQueueItem>,
  ~isUnorderedMultichainMode,
): option<earliestQueueItem> => {
  //Compare the peeked items and determine the next item
  switch fetchStatesMap->determineNextEvent(~isUnorderedMultichainMode) {
  | Ok({chain, earliestEventResponse: {getUpdatedPartitionedFetchState, earliestQueueItem}}) =>
    let maybeArbItem = if isUnorderedMultichainMode {
      arbitraryEventQueue->getFirstArbitraryEventsItemForChain(~chain)
    } else {
      arbitraryEventQueue->getFirstArbitraryEventsItem
    }
    switch maybeArbItem {
    //If there is item on the arbitray events queue, and it is earlier than
    //than the earlist event, take the item off from there
    | Some((qItem, getUpdatedArbQueue))
      if Item(qItem)->getQueueItemComparitor(~chain=qItem.chain) <
        earliestQueueItem->getQueueItemComparitor(~chain) =>
      Some(ArbitraryEventQueue(qItem, getUpdatedArbQueue()))
    | _ =>
      //Otherwise take the latest item from the fetchers
      switch earliestQueueItem {
      | NoItem(_) => None
      | Item(qItem) =>
        let updatedFetchStatesMap =
          fetchStatesMap->ChainMap.set(chain, getUpdatedPartitionedFetchState())
        EventFetchers(qItem, updatedFetchStatesMap)->Some
      }
    }
  | Error(NoItemsInArray) =>
    arbitraryEventQueue
    ->getFirstArbitraryEventsItem
    ->Option.map(((qItem, getUpdatedArbQueue)) => {
      ArbitraryEventQueue(qItem, getUpdatedArbQueue())
    })
  }
}

/**
Simply calls popBatchItem in isolation using the chain manager without
the context of a batch
*/
let peakNextBatchItem = (self: t): option<earliestQueueItem> => {
  popBatchItem(
    ~fetchStatesMap=self.chainFetchers->ChainMap.map(cf => cf.fetchState),
    ~arbitraryEventQueue=self.arbitraryEventQueue,
    ~isUnorderedMultichainMode=self.isUnorderedMultichainMode,
  )
}

type batchRes = {
  batch: array<Types.eventBatchQueueItem>,
  fetchStatesMap: ChainMap.t<PartitionedFetchState.t>,
  arbitraryEventQueue: array<Types.eventBatchQueueItem>,
}

let makeBatch = (~batch, ~fetchStatesMap, ~arbitraryEventQueue) => {
  batch,
  fetchStatesMap,
  arbitraryEventQueue,
}

let rec createBatchInternal = (
  ~maxBatchSize,
  ~fetchStatesMap: ChainMap.t<PartitionedFetchState.t>,
  ~arbitraryEventQueue,
  ~isUnorderedMultichainMode,
  ~batch=[],
) => {
  if batch->Array.length >= maxBatchSize {
    makeBatch(~batch, ~fetchStatesMap, ~arbitraryEventQueue)
  } else {
    switch popBatchItem(~fetchStatesMap, ~arbitraryEventQueue, ~isUnorderedMultichainMode) {
    | None => makeBatch(~batch, ~fetchStatesMap, ~arbitraryEventQueue)
    | Some(item) =>
      let (arbitraryEventQueue, fetchStatesMap, nextItem) = switch item {
      | ArbitraryEventQueue(item, arbitraryEventQueue) => (
          arbitraryEventQueue,
          fetchStatesMap,
          item,
        )
      | EventFetchers(item, fetchStatesMap) => (arbitraryEventQueue, fetchStatesMap, item)
      }
      let _ = batch->Js.Array2.push(nextItem)
      createBatchInternal(
        ~batch,
        ~maxBatchSize,
        ~arbitraryEventQueue,
        ~fetchStatesMap,
        ~isUnorderedMultichainMode,
      )
    }
  }
}

let createBatch = (self: t, ~maxBatchSize: int) => {
  let refTime = Hrtime.makeTimer()

  let {arbitraryEventQueue, chainFetchers} = self
  let fetchStatesMap = chainFetchers->ChainMap.map(cf => cf.fetchState)

  let response = createBatchInternal(
    ~maxBatchSize,
    ~fetchStatesMap,
    ~arbitraryEventQueue,
    ~isUnorderedMultichainMode=self.isUnorderedMultichainMode,
  )

  let batchSize = response.batch->Array.length

  if batchSize > 0 {
    let fetchedEventsBuffer =
      chainFetchers
      ->ChainMap.values
      ->Array.map(fetcher => (
        fetcher.chainConfig.chain->ChainMap.Chain.toString,
        fetcher.fetchState->PartitionedFetchState.queueSize,
      ))
      ->Array.concat([("arbitrary", self.arbitraryEventQueue->Array.length)])
      ->Js.Dict.fromArray

    let timeElapsed = refTime->Hrtime.timeSince->Hrtime.toMillis

    Logging.trace({
      "message": "New batch created for processing",
      "batch size": batchSize,
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
