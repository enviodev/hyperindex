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

type noActiveChains = NoActiveChains

type isInReorgThresholdRes<'payload> = {
  isInReorgThreshold: bool,
  val: 'payload,
}

type fetchStateWithData = {
  fetchState: FetchState.t,
  highestBlockBelowThreshold: int,
  currentBlockHeight: int,
}

let isQueueItemEarlier = (a: multiChainEventComparitor, b: multiChainEventComparitor): bool => {
  a.earliestEvent->getQueueItemComparitor(~chain=a.chain) <
    b.earliestEvent->getQueueItemComparitor(~chain=b.chain)
}

let determineNextEvent = (fetchStatesMap: ChainMap.t<fetchStateWithData>): result<
  isInReorgThresholdRes<multiChainEventComparitor>,
  noActiveChains,
> => {
  let nextItem =
    fetchStatesMap
    ->ChainMap.entries
    ->Array.reduce({isInReorgThreshold: false, val: None}, (
      accum,
      (chain, {fetchState, currentBlockHeight, highestBlockBelowThreshold}),
    ) => {
      // If the fetch state has reached the end block we don't need to consider it
      if fetchState->FetchState.isActivelyIndexing {
        let earliestEvent = fetchState->FetchState.getEarliestEvent
        let current: multiChainEventComparitor = {chain, earliestEvent}
        switch accum.val {
        | Some(previous) if isQueueItemEarlier(previous, current) => accum
        | _ =>
          let isInReorgThreshold =
            earliestEvent->FetchState.queueItemIsInReorgThreshold(
              ~currentBlockHeight,
              ~highestBlockBelowThreshold,
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

let popOrderedBatchItem = (~fetchStatesMap: ChainMap.t<fetchStateWithData>): isInReorgThresholdRes<
  option<FetchState.itemWithPopFn>,
> => {
  //Compare the peeked items and determine the next item
  switch fetchStatesMap->determineNextEvent {
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
      highestBlockBelowThreshold: cf->ChainFetcher.getHighestBlockBelowThreshold,
      currentBlockHeight: cf.currentBlockHeight,
    }
  })
}

/**
Simply calls popOrderedBatchItem in isolation using the chain manager without
the context of a batch
*/
let nextItemIsNone = (self: t): bool => {
  popOrderedBatchItem(~fetchStatesMap=self->getFetchStateWithData).val->Option.isNone
}

type processingPartition = {
  // Either for specific chain or for all chains (ordered)
  chain: option<ChainMap.Chain.t>,
  items: array<Internal.eventItem>,
}

type processingChainMetrics = {
  batchSize: int,
  targetBlockNumber: int,
}

let createOrderedBatchItems = (
  ~maxBatchSize,
  ~fetchStatesMap: ChainMap.t<fetchStateWithData>,
  ~onlyBelowReorgThreshold,
  ~mutProcessingMetricsByChainId: dict<processingChainMetrics>,
) => {
  let isInReorgThresholdRef = ref(false)
  let items = []

  let rec loop = () =>
    if items->Array.length < maxBatchSize {
      let {val, isInReorgThreshold} = popOrderedBatchItem(~fetchStatesMap)

      isInReorgThresholdRef := isInReorgThresholdRef.contents || isInReorgThreshold

      switch val {
      | None => ()
      | Some({item, popItemOffQueue}) =>
        //For dynamic contract pre registration, allow creating a batch up to the reorg threshold
        let shouldNotAddItem = isInReorgThreshold && onlyBelowReorgThreshold
        if !shouldNotAddItem {
          popItemOffQueue()
          items->Js.Array2.push(item)->ignore
          mutProcessingMetricsByChainId->Js.Dict.set(
            item.chain->ChainMap.Chain.toChainId->Int.toString,
            {
              batchSize: switch mutProcessingMetricsByChainId->Utils.Dict.dangerouslyGetNonOption(
                item.chain->ChainMap.Chain.toChainId->Int.toString,
              ) {
              | Some(metrics) => metrics.batchSize + 1
              | None => 1
              },
              targetBlockNumber: item.blockNumber,
            },
          )
          loop()
        }
      }
    }
  loop()

  (
    [
      {
        chain: None,
        items,
      },
    ],
    items->Array.length,
    isInReorgThresholdRef.contents,
  )
}

let createUnorderedBatchItems = (
  ~maxBatchSize,
  ~fetchStatesMap: ChainMap.t<fetchStateWithData>,
  ~onlyBelowReorgThreshold,
  ~mutProcessingMetricsByChainId: dict<processingChainMetrics>,
) => {
  let isInReorgThresholdRef = ref(false)
  let totalBatchSize = ref(0)

  let processingPartitions =
    fetchStatesMap
    ->ChainMap.entries
    ->Array.keepMap(((chain, {fetchState, currentBlockHeight, highestBlockBelowThreshold})) => {
      let items = []

      // If the fetch state has reached the end block we don't need to consider it
      if fetchState->FetchState.isActivelyIndexing {
        let rec loop = () =>
          if items->Array.length < maxBatchSize {
            let earliestEvent = fetchState->FetchState.getEarliestEvent
            let isInReorgThreshold =
              earliestEvent->FetchState.queueItemIsInReorgThreshold(
                ~currentBlockHeight,
                ~highestBlockBelowThreshold,
              )

            isInReorgThresholdRef := isInReorgThresholdRef.contents || isInReorgThreshold

            switch earliestEvent {
            | NoItem(_) => ()
            | Item({item, popItemOffQueue}) =>
              //For dynamic contract pre registration, allow creating a batch up to the reorg threshold
              let shouldNotAddItem = isInReorgThreshold && onlyBelowReorgThreshold
              if !shouldNotAddItem {
                popItemOffQueue()
                items->Js.Array2.push(item)->ignore
                loop()
                totalBatchSize := totalBatchSize.contents + 1
              }
            }
          }
        loop()
      }

      switch items {
      | [] => None
      | _ =>
        mutProcessingMetricsByChainId->Js.Dict.set(
          chain->ChainMap.Chain.toChainId->Int.toString,
          {
            batchSize: items->Array.length,
            targetBlockNumber: (items->Utils.Array.last->Option.getUnsafe).blockNumber,
          },
        )
        Some({
          chain: Some(chain),
          items,
        })
      }
    })

  (processingPartitions, totalBatchSize.contents, isInReorgThresholdRef.contents)
}

type batch = {
  processingPartitions: array<processingPartition>,
  processingMetricsByChainId: dict<processingChainMetrics>,
  totalBatchSize: int,
  fetchStatesMap: ChainMap.t<fetchStateWithData>,
  dcsToStoreByChainId: dict<array<FetchState.indexingContract>>,
  isInReorgThreshold: bool,
}

let createBatch = (self: t, ~maxBatchSize: int, ~onlyBelowReorgThreshold: bool) => {
  let refTime = Hrtime.makeTimer()

  //Make a copy of the queues and fetch states since we are going to mutate them
  let fetchStatesMap = self->getFetchStateWithData(~shouldDeepCopy=true)

  let mutProcessingMetricsByChainId = Js.Dict.empty()
  let (processingPartitions, totalBatchSize, isInReorgThreshold) = if (
    self.isUnorderedMultichainMode
  ) {
    createUnorderedBatchItems(
      ~maxBatchSize,
      ~fetchStatesMap,
      ~onlyBelowReorgThreshold,
      ~mutProcessingMetricsByChainId,
    )
  } else {
    createOrderedBatchItems(
      ~maxBatchSize,
      ~fetchStatesMap,
      ~onlyBelowReorgThreshold,
      ~mutProcessingMetricsByChainId,
    )
  }

  let dcsToStoreByChainId = Js.Dict.empty()
  // Needed to recalculate the computed queue sizes
  let fetchStatesMap = fetchStatesMap->ChainMap.map(v => {
    switch v.fetchState.dcsToStore {
    | Some(dcs) => dcsToStoreByChainId->Js.Dict.set(v.fetchState.chainId->Int.toString, dcs)
    | None => ()
    }
    {
      ...v,
      fetchState: v.fetchState->FetchState.updateInternal(~dcsToStore=None),
    }
  })

  if totalBatchSize > 0 {
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
      "totalBatchSize": totalBatchSize,
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
      Benchmark.addSummaryData(~group, ~label=`Batch Size`, ~value=totalBatchSize->Belt.Int.toFloat)
    }
  }

  {
    processingPartitions,
    processingMetricsByChainId: mutProcessingMetricsByChainId,
    totalBatchSize,
    fetchStatesMap,
    dcsToStoreByChainId,
    isInReorgThreshold,
  }
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
    blockNumber: cf->ChainFetcher.getHighestBlockBelowThreshold,
  })
}

module ExposedForTesting_Hidden = {
  let priorityQueueComparitor = priorityQueueComparitor
  let getComparitorFromItem = getComparitorFromItem
  let createDetermineNextEventFunction = determineNextEvent
}
