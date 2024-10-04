open Belt
type t = {
  chainFetchers: ChainMap.t<ChainFetcher.t>,
  //Holds arbitrary events that were added when a batch ended processing early
  //due to contract registration. Ordered from latest to earliest
  arbitraryEventQueue: array<Types.eventBatchQueueItem>,
  isUnorderedMultichainMode: bool,
  isInReorgThreshold: bool,
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
  earliestEvent: FetchState.queueItem,
}

let getQueueItemComparitor = (earliestQueueItem: FetchState.queueItem, ~chain) => {
  switch earliestQueueItem {
  | Item({item}) => item->getComparitorFromItem
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
  a.earliestEvent->getQueueItemComparitor(~chain=a.chain) <
    b.earliestEvent->getQueueItemComparitor(~chain=b.chain)
}

// This is similar to `chainFetcherPeekComparitorEarliestEvent`, but it prioritizes events over `NoItem` no matter what the timestamp of `NoItem` is.
let chainFetcherPeekComparitorEarliestEventPrioritizeEvents = (
  a: multiChainEventComparitor,
  b: multiChainEventComparitor,
): bool => {
  switch (a.earliestEvent, b.earliestEvent) {
  | (Item(_), NoItem(_)) => true
  | (NoItem(_), Item(_)) => false
  | _ => isQueueItemEarlier(a, b)
  }
}

type noItemsInArray = NoItemsInArray

type isInReorgThresholdRes<'payload> = {
  isInReorgThreshold: bool,
  val: 'payload,
}

type fetchStateWithData = {
  partitionedFetchState: PartitionedFetchState.t,
  heighestBlockBelowThreshold: int,
}

let determineNextEvent = (
  fetchStatesMap: ChainMap.t<fetchStateWithData>,
  ~isUnorderedMultichainMode: bool,
): result<isInReorgThresholdRes<multiChainEventComparitor>, noItemsInArray> => {
  let comparitorFunction = if isUnorderedMultichainMode {
    chainFetcherPeekComparitorEarliestEventPrioritizeEvents
  } else {
    isQueueItemEarlier
  }

  let nextItem =
    fetchStatesMap
    ->ChainMap.entries
    ->Array.reduce({isInReorgThreshold: false, val: None}, (
      accum,
      (chain, {partitionedFetchState, heighestBlockBelowThreshold}),
    ) => {
      // If the fetch state has reached the end block we don't need to consider it
      switch partitionedFetchState->PartitionedFetchState.getEarliestEvent {
      | Some(earliestEvent) =>
        let {val, isInReorgThreshold} = accum
        let mk = cmp => {
          {
            val: Some(cmp),
            isInReorgThreshold: isInReorgThreshold ||
            cmp.earliestEvent->FetchState.queueItemIsInReorgThreshold(~heighestBlockBelowThreshold),
          }
        }
        let cmpA: multiChainEventComparitor = {chain, earliestEvent}
        switch val {
        | None => mk(cmpA)
        | Some(cmpB) =>
          if comparitorFunction(cmpB, cmpA) {
            mk(cmpB)
          } else {
            mk(cmpA)
          }
        }
      | None => accum
      }
    })

  switch nextItem {
  | {val: None} => Error(NoItemsInArray)
  | {val: Some(item), isInReorgThreshold} => Ok({val: item, isInReorgThreshold})
  }
}

let makeFromConfig = (~config: Config.t, ~maxAddrInPartition=Env.maxAddrInPartition): t => {
  let chainFetchers =
    config.chainMap->ChainMap.map(ChainFetcher.makeFromConfig(_, ~maxAddrInPartition))
  {
    chainFetchers,
    arbitraryEventQueue: [],
    isUnorderedMultichainMode: config.isUnorderedMultichainMode,
    isInReorgThreshold: false,
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

  let hasStartedSavingHistory = await DbFunctions.EntityHistory.hasRows()

  {
    isUnorderedMultichainMode: config.isUnorderedMultichainMode,
    arbitraryEventQueue: [],
    chainFetchers,
    //If we have started saving history, continue to save history
    //as regardless of whether we are still in a reorg threshold
    isInReorgThreshold: hasStartedSavingHistory,
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

let getFirstArbitraryEventsItemForChain = (
  queue: array<Types.eventBatchQueueItem>,
  ~chain,
  ~fetchStatesMap: ChainMap.t<fetchStateWithData>,
): option<isInReorgThresholdRes<FetchState.itemWithPopFn>> =>
  queue
  ->Utils.Array.findReverseWithIndex((item: Types.eventBatchQueueItem) => {
    item.chain == chain
  })
  ->Option.map(((item, index)) => {
    let {heighestBlockBelowThreshold} = fetchStatesMap->ChainMap.get(item.chain)
    let isInReorgThreshold = item.blockNumber > heighestBlockBelowThreshold
    {
      val: {
        FetchState.item,
        popItemOffQueue: () => queue->Utils.Array.spliceInPlace(~pos=index, ~remove=1)->ignore,
      },
      isInReorgThreshold,
    }
  })

let getFirstArbitraryEventsItem = (
  queue: array<Types.eventBatchQueueItem>,
  ~fetchStatesMap: ChainMap.t<fetchStateWithData>,
): option<isInReorgThresholdRes<FetchState.itemWithPopFn>> =>
  queue
  ->Utils.Array.last
  ->Option.map(item => {
    let {heighestBlockBelowThreshold} = fetchStatesMap->ChainMap.get(item.chain)
    let isInReorgThreshold = item.blockNumber > heighestBlockBelowThreshold
    {
      val: {FetchState.item, popItemOffQueue: () => queue->Js.Array2.pop->ignore},
      isInReorgThreshold,
    }
  })

let popBatchItem = (
  ~fetchStatesMap: ChainMap.t<fetchStateWithData>,
  ~arbitraryEventQueue: array<Types.eventBatchQueueItem>,
  ~isUnorderedMultichainMode,
): isInReorgThresholdRes<option<FetchState.itemWithPopFn>> => {
  //Compare the peeked items and determine the next item
  switch fetchStatesMap->determineNextEvent(~isUnorderedMultichainMode) {
  | Ok({val: {chain, earliestEvent}, isInReorgThreshold}) =>
    let maybeArbItem = if isUnorderedMultichainMode {
      arbitraryEventQueue->getFirstArbitraryEventsItemForChain(~chain, ~fetchStatesMap)
    } else {
      arbitraryEventQueue->getFirstArbitraryEventsItem(~fetchStatesMap)
    }
    switch maybeArbItem {
    //If there is item on the arbitray events queue, and it is earlier than
    //than the earlist event, take the item off from there
    | Some({val: itemWithPopFn, isInReorgThreshold})
      if Item(itemWithPopFn)->getQueueItemComparitor(~chain=itemWithPopFn.item.chain) <
        earliestEvent->getQueueItemComparitor(~chain) => {
        isInReorgThreshold,
        val: Some(itemWithPopFn),
      }
    | _ =>
      switch earliestEvent {
      | NoItem(_) => {
          isInReorgThreshold,
          val: None,
        }
      | Item(itemWithPopFn) => {
          isInReorgThreshold,
          val: Some(itemWithPopFn),
        }
      }
    }
  | Error(NoItemsInArray) =>
    arbitraryEventQueue
    ->getFirstArbitraryEventsItem(~fetchStatesMap)
    ->Option.mapWithDefault({val: None, isInReorgThreshold: false}, ({val, isInReorgThreshold}) => {
      isInReorgThreshold,
      val: Some(val),
    })
  }
}

let getFetchStateWithData = (self: t, ~shouldDeepCopy=false): ChainMap.t<fetchStateWithData> => {
  self.chainFetchers->ChainMap.map(cf => {
    partitionedFetchState: shouldDeepCopy
      ? cf.fetchState->PartitionedFetchState.copy
      : cf.fetchState,
    heighestBlockBelowThreshold: cf.currentBlockHeight - cf.chainConfig.confirmedBlockThreshold,
  })
}

/**
Simply calls popBatchItem in isolation using the chain manager without
the context of a batch
*/
let nextItemIsNone = (self: t): bool => {
  popBatchItem(
    ~fetchStatesMap=self->getFetchStateWithData,
    ~arbitraryEventQueue=self.arbitraryEventQueue,
    ~isUnorderedMultichainMode=self.isUnorderedMultichainMode,
  ).val->Option.isNone
}

let hasChainItemsOnArbQueue = (self: t, ~chain): bool => {
  self.arbitraryEventQueue->Js.Array2.find(item => item.chain == chain)->Option.isSome
}

let createBatchInternal = (
  ~maxBatchSize,
  ~fetchStatesMap: ChainMap.t<fetchStateWithData>,
  ~arbitraryEventQueue,
  ~isUnorderedMultichainMode,
) => {
  let isInReorgThresholdRef = ref(false)
  let batch = []
  let rec loop = () =>
    if batch->Array.length < maxBatchSize {
      let {val, isInReorgThreshold} = popBatchItem(
        ~fetchStatesMap,
        ~arbitraryEventQueue,
        ~isUnorderedMultichainMode,
      )

      isInReorgThresholdRef := isInReorgThresholdRef.contents || isInReorgThreshold

      switch val {
      | None => ()
      | Some({item, popItemOffQueue}) =>
        popItemOffQueue()
        batch->Js.Array2.push(item)->ignore
        loop()
      }
    }
  loop()

  {val: batch, isInReorgThreshold: isInReorgThresholdRef.contents}
}

type batchRes = {
  batch: array<Types.eventBatchQueueItem>,
  fetchStatesMap: ChainMap.t<fetchStateWithData>,
  arbitraryEventQueue: array<Types.eventBatchQueueItem>,
}

let createBatch = (self: t, ~maxBatchSize: int) => {
  let refTime = Hrtime.makeTimer()

  let {arbitraryEventQueue, chainFetchers} = self
  //Make a copy of the queues and fetch states since we are going to mutate them
  let arbitraryEventQueue = arbitraryEventQueue->Array.copy
  let fetchStatesMap = self->getFetchStateWithData(~shouldDeepCopy=true)

  let {val: batch, isInReorgThreshold} = createBatchInternal(
    ~maxBatchSize,
    ~fetchStatesMap,
    ~arbitraryEventQueue,
    ~isUnorderedMultichainMode=self.isUnorderedMultichainMode,
  )

  let batchSize = batch->Array.length

  let val = if batchSize > 0 {
    let fetchedEventsBuffer =
      chainFetchers
      ->ChainMap.values
      ->Array.map(fetcher => (
        fetcher.chainConfig.chain->ChainMap.Chain.toString,
        fetcher.fetchState->PartitionedFetchState.queueSize,
      ))
      ->Array.concat([("arbitrary", self.arbitraryEventQueue->Array.length)])
      ->Js.Dict.fromArray

    let timeElapsed = refTime->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    Logging.trace({
      "message": "New batch created for processing",
      "batch size": batchSize,
      "buffers": fetchedEventsBuffer,
      "time taken (ms)": timeElapsed,
    })

    if Env.saveBenchmarkData {
      let group = "Other"
      Benchmark.addSummaryData(
        ~group,
        ~label=`Batch Creation Time (ms)`,
        ~value=timeElapsed->Belt.Int.toFloat,
      )
      Benchmark.addSummaryData(~group, ~label=`Batch Size`, ~value=batchSize->Belt.Int.toFloat)
    }

    Some({batch, fetchStatesMap, arbitraryEventQueue})
  } else {
    None
  }

  {val, isInReorgThreshold}
}

let isFetchingAtHead = self =>
  self.chainFetchers
  ->ChainMap.values
  ->Array.reduce(true, (accum, cf) => accum && cf->ChainFetcher.isFetchingAtHead)

let isPreRegisteringDynamicContracts = self =>
  self.chainFetchers
  ->ChainMap.values
  ->Array.reduce(false, (accum, cf) => accum || cf.isPreRegisteringDynamicContracts)

module ExposedForTesting_Hidden = {
  let priorityQueueComparitor = priorityQueueComparitor
  let getComparitorFromItem = getComparitorFromItem
  let createDetermineNextEventFunction = determineNextEvent
}
