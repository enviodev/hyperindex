open Belt

type t = {
  chainFetchers: ChainMap.t<ChainFetcher.t>,
  isUnorderedMultichainMode: bool,
  isInReorgThreshold: bool,
}

let getComparitorFromItem = (queueItem: Internal.eventItem) => {
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
  | NoItem({latestFetchedBlock: {blockTimestamp, blockNumber}}) => (
      blockTimestamp,
      chain->ChainMap.Chain.toChainId,
      blockNumber,
      0,
    )
  }
}

let priorityQueueComparitor = (a: Internal.eventItem, b: Internal.eventItem) => {
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
let isQueueItemEarlierUnorderedMultichain = (
  a: multiChainEventComparitor,
  b: multiChainEventComparitor,
): bool => {
  switch (a.earliestEvent, b.earliestEvent) {
  | (Item(_), NoItem(_)) => true
  | (NoItem(_), Item(_)) => false
  | _ => isQueueItemEarlier(a, b)
  }
}

type noActiveChains = NoActiveChains

type isInReorgThresholdRes<'payload> = {
  isInReorgThreshold: bool,
  val: 'payload,
}

type fetchStateWithData = {
  fetchState: FetchState.t,
  heighestBlockBelowThreshold: int,
  currentBlockHeight: int,
}

let isQueueItemEarlierUnorderedBelowReorgThreshold = (
  ~fetchStatesMap: ChainMap.t<fetchStateWithData>,
) => (a: multiChainEventComparitor, b: multiChainEventComparitor) => {
  let isItemBelowReorgThreshold = item => {
    let data = fetchStatesMap->ChainMap.get(item.chain)
    item.earliestEvent->FetchState.queueItemIsInReorgThreshold(
      ~currentBlockHeight=data.currentBlockHeight,
      ~heighestBlockBelowThreshold=data.heighestBlockBelowThreshold,
    )
  }
  // The idea here is if we are in undordered multichain mode, always prioritize queue
  // items that are below the reorg threshold. That way we can register contracts all
  // the way up to the threshold on all chains before starting.
  // Similarly we wait till all chains are at their threshold before saving entity history.
  switch (a->isItemBelowReorgThreshold, b->isItemBelowReorgThreshold) {
  | (false, true) => true
  | (true, false) => false
  | _ => isQueueItemEarlierUnorderedMultichain(a, b)
  }
}

let determineNextEvent = (
  fetchStatesMap: ChainMap.t<fetchStateWithData>,
  ~isUnorderedMultichainMode: bool,
  ~onlyBelowReorgThreshold: bool,
): result<isInReorgThresholdRes<multiChainEventComparitor>, noActiveChains> => {
  let comparitorFunction = if isUnorderedMultichainMode {
    if onlyBelowReorgThreshold {
      isQueueItemEarlierUnorderedBelowReorgThreshold(~fetchStatesMap)
    } else {
      isQueueItemEarlierUnorderedMultichain
    }
  } else {
    isQueueItemEarlier
  }

  let nextItem =
    fetchStatesMap
    ->ChainMap.entries
    ->Array.reduce({isInReorgThreshold: false, val: None}, (
      accum,
      (chain, {fetchState, currentBlockHeight, heighestBlockBelowThreshold}),
    ) => {
      // If the fetch state has reached the end block we don't need to consider it
      if fetchState->FetchState.isActivelyIndexing {
        let earliestEvent = fetchState->FetchState.getEarliestEvent
        let current: multiChainEventComparitor = {chain, earliestEvent}
        switch accum.val {
        | Some(previous) if comparitorFunction(previous, current) => accum
        | _ =>
          let isInReorgThreshold =
            earliestEvent->FetchState.queueItemIsInReorgThreshold(
              ~currentBlockHeight,
              ~heighestBlockBelowThreshold,
            )

          {
            val: Some(current),
            isInReorgThreshold,
          }
        }
      } else {
        accum
      }
    })

  switch nextItem {
  | {val: None} => Error(NoActiveChains)
  | {val: Some(item), isInReorgThreshold} => Ok({val: item, isInReorgThreshold})
  }
}

let makeFromConfig = (~config: Config.t, ~maxAddrInPartition=Env.maxAddrInPartition): t => {
  let chainFetchers =
    config.chainMap->ChainMap.map(
      ChainFetcher.makeFromConfig(_, ~maxAddrInPartition, ~enableRawEvents=config.enableRawEvents),
    )
  {
    chainFetchers,
    isUnorderedMultichainMode: config.isUnorderedMultichainMode,
    isInReorgThreshold: false,
  }
}

let makeFromDbState = async (~config: Config.t, ~maxAddrInPartition=Env.maxAddrInPartition): t => {
  let chainFetchersArr =
    await config.chainMap
    ->ChainMap.entries
    ->Array.map(async ((chain, chainConfig)) => {
      (
        chain,
        await chainConfig->ChainFetcher.makeFromDbState(
          ~maxAddrInPartition,
          ~enableRawEvents=config.enableRawEvents,
        ),
      )
    })
    ->Promise.all

  let chainFetchers = ChainMap.fromArrayUnsafe(chainFetchersArr)

  // Since now it's possible not to have rows in the history table
  // even after the indexer started saving history (entered reorg threshold),
  // This rows check might incorrectly return false for recovering the isInReorgThreshold option.
  // But this is not a problem. There's no history anyways, and the indexer will be able to
  // correctly calculate isInReorgThreshold as it starts.
  let hasStartedSavingHistory = await Db.sql->DbFunctions.EntityHistory.hasRows

  {
    isUnorderedMultichainMode: config.isUnorderedMultichainMode,
    chainFetchers,
    //If we have started saving history, continue to save history
    //as regardless of whether we are still in a reorg threshold
    isInReorgThreshold: hasStartedSavingHistory,
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

let popBatchItem = (
  ~fetchStatesMap: ChainMap.t<fetchStateWithData>,
  ~isUnorderedMultichainMode,
  ~onlyBelowReorgThreshold,
): isInReorgThresholdRes<option<FetchState.itemWithPopFn>> => {
  //Compare the peeked items and determine the next item
  switch fetchStatesMap->determineNextEvent(~isUnorderedMultichainMode, ~onlyBelowReorgThreshold) {
  | Ok({val: {earliestEvent}, isInReorgThreshold}) =>
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
  | Error(NoActiveChains) => {val: None, isInReorgThreshold: false}
  }
}

let getFetchStateWithData = (self: t, ~shouldDeepCopy=false): ChainMap.t<fetchStateWithData> => {
  self.chainFetchers->ChainMap.map(cf => {
    {
      fetchState: shouldDeepCopy ? cf.fetchState->FetchState.copy : cf.fetchState,
      heighestBlockBelowThreshold: cf->ChainFetcher.getHeighestBlockBelowThreshold,
      currentBlockHeight: cf.currentBlockHeight,
    }
  })
}

/**
Simply calls popBatchItem in isolation using the chain manager without
the context of a batch
*/
let nextItemIsNone = (self: t): bool => {
  popBatchItem(
    ~fetchStatesMap=self->getFetchStateWithData,
    ~isUnorderedMultichainMode=self.isUnorderedMultichainMode,
    ~onlyBelowReorgThreshold=false,
  ).val->Option.isNone
}

let createBatchInternal = (
  ~maxBatchSize,
  ~fetchStatesMap: ChainMap.t<fetchStateWithData>,
  ~isUnorderedMultichainMode,
  ~onlyBelowReorgThreshold,
) => {
  let isInReorgThresholdRef = ref(false)
  let batch = []
  let rec loop = () =>
    if batch->Array.length < maxBatchSize {
      let {val, isInReorgThreshold} = popBatchItem(
        ~fetchStatesMap,
        ~isUnorderedMultichainMode,
        ~onlyBelowReorgThreshold,
      )

      isInReorgThresholdRef := isInReorgThresholdRef.contents || isInReorgThreshold

      switch val {
      | None => ()
      | Some({item, popItemOffQueue}) =>
        //For dynamic contract pre registration, allow creating a batch up to the reorg threshold
        let shouldNotAddItem = isInReorgThreshold && onlyBelowReorgThreshold
        if !shouldNotAddItem {
          popItemOffQueue()
          batch->Js.Array2.push(item)->ignore
          loop()
        }
      }
    }
  loop()

  {val: batch, isInReorgThreshold: isInReorgThresholdRef.contents}
}

type batchRes = {
  batch: array<Internal.eventItem>,
  fetchStatesMap: ChainMap.t<fetchStateWithData>,
  dcsToStore: array<TablesStatic.DynamicContractRegistry.t>,
}

let createBatch = (self: t, ~maxBatchSize: int, ~onlyBelowReorgThreshold: bool) => {
  let refTime = Hrtime.makeTimer()

  //Make a copy of the queues and fetch states since we are going to mutate them
  let fetchStatesMap = self->getFetchStateWithData(~shouldDeepCopy=true)

  let {val: batch, isInReorgThreshold} = createBatchInternal(
    ~maxBatchSize,
    ~fetchStatesMap,
    ~isUnorderedMultichainMode=self.isUnorderedMultichainMode,
    ~onlyBelowReorgThreshold,
  )

  let dcsToStore = []
  // Needed to recalculate the computed queue sizes
  let fetchStatesMap = fetchStatesMap->ChainMap.map(v => {
    let fs = switch v.fetchState.dcsToStore {
    | Some(dcs) => {
        dcsToStore->Js.Array2.pushMany(dcs)->ignore
        {
          ...v.fetchState,
          dcsToStore: ?None,
        }
      }
    | None => v.fetchState
    }
    {
      ...v,
      fetchState: fs->FetchState.updateInternal,
    }
  })

  let batchSize = batch->Array.length

  let val = if batchSize > 0 {
    let fetchedEventsBuffer =
      fetchStatesMap
      ->ChainMap.entries
      ->Array.map(((chain, v)) => (
        chain->ChainMap.Chain.toString,
        v.fetchState->FetchState.queueSize,
      ))
      ->Js.Dict.fromArray

    let timeElapsed = refTime->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    Logging.trace({
      "msg": "New batch created for processing",
      "batch size": batchSize,
      "buffers": fetchedEventsBuffer,
      "time taken (ms)": timeElapsed,
    })

    if Env.Benchmark.shouldSaveData {
      let group = "Other"
      Benchmark.addSummaryData(
        ~group,
        ~label=`Batch Creation Time (ms)`,
        ~value=timeElapsed->Belt.Int.toFloat,
      )
      Benchmark.addSummaryData(~group, ~label=`Batch Size`, ~value=batchSize->Belt.Int.toFloat)
    }

    Some({batch, fetchStatesMap, dcsToStore})
  } else {
    None
  }

  {val, isInReorgThreshold}
}

let isFetchingAtHead = self =>
  self.chainFetchers
  ->ChainMap.values
  ->Js.Array2.every(ChainFetcher.isFetchingAtHead)

let isActivelyIndexing = self =>
  self.chainFetchers
  ->ChainMap.values
  ->Js.Array2.every(ChainFetcher.isActivelyIndexing)

let getSafeChainIdAndBlockNumberArray = (self: t): array<
  DbFunctions.EntityHistory.chainIdAndBlockNumber,
> => {
  self.chainFetchers
  ->ChainMap.values
  ->Array.map((cf): DbFunctions.EntityHistory.chainIdAndBlockNumber => {
    chainId: cf.chainConfig.chain->ChainMap.Chain.toChainId,
    blockNumber: cf->ChainFetcher.getHeighestBlockBelowThreshold,
  })
}

module ExposedForTesting_Hidden = {
  let priorityQueueComparitor = priorityQueueComparitor
  let getComparitorFromItem = getComparitorFromItem
  let createDetermineNextEventFunction = determineNextEvent
}
