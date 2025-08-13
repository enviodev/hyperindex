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

let isQueueItemEarlier = (a: multiChainEventComparitor, b: multiChainEventComparitor): bool => {
  a.earliestEvent->getQueueItemComparitor(~chain=a.chain) <
    b.earliestEvent->getQueueItemComparitor(~chain=b.chain)
}

/**
 It either returnes an earliest item among all chains, or None if no chains are actively indexing
 */
let getOrderedNextItem = (fetchStates: ChainMap.t<FetchState.t>): option<
  multiChainEventComparitor,
> => {
  fetchStates
  ->ChainMap.entries
  ->Array.reduce(None, (accum, (chain, fetchState)) => {
    // If the fetch state has reached the end block we don't need to consider it
    if fetchState->FetchState.isActivelyIndexing {
      let earliestEvent = fetchState->FetchState.getEarliestEvent
      let current: multiChainEventComparitor = {chain, earliestEvent}
      switch accum {
      | Some(previous) if isQueueItemEarlier(previous, current) => accum
      | _ => Some(current)
      }
    } else {
      accum
    }
  })
}

let makeFromConfig = (~config: Config.t, ~maxAddrInPartition=Env.maxAddrInPartition): t => {
  let chainFetchers =
    config.chainMap->ChainMap.map(ChainFetcher.makeFromConfig(_, ~maxAddrInPartition, ~config))
  {
    chainFetchers,
    isUnorderedMultichainMode: config.isUnorderedMultichainMode,
    isInReorgThreshold: false,
  }
}

let makeFromDbState = async (~config: Config.t, ~maxAddrInPartition=Env.maxAddrInPartition): t => {
  // Since now it's possible not to have rows in the history table
  // even after the indexer started saving history (entered reorg threshold),
  // This rows check might incorrectly return false for recovering the isInReorgThreshold option.
  // But this is not a problem. There's no history anyways, and the indexer will be able to
  // correctly calculate isInReorgThreshold as it starts.
  let hasStartedSavingHistory = await Db.sql->DbFunctions.EntityHistory.hasRows
  //If we have started saving history, continue to save history
  //as regardless of whether we are still in a reorg threshold
  let isInReorgThreshold = hasStartedSavingHistory

  let chainFetchersArr =
    await config.chainMap
    ->ChainMap.entries
    ->Array.map(async ((chain, chainConfig)) => {
      (
        chain,
        await chainConfig->ChainFetcher.makeFromDbState(
          ~maxAddrInPartition,
          ~isInReorgThreshold,
          ~config,
        ),
      )
    })
    ->Promise.all

  let chainFetchers = ChainMap.fromArrayUnsafe(chainFetchersArr)

  {
    isUnorderedMultichainMode: config.isUnorderedMultichainMode,
    chainFetchers,
    isInReorgThreshold,
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

let getFetchStateWithData = (self: t, ~shouldDeepCopy=false): ChainMap.t<FetchState.t> => {
  self.chainFetchers->ChainMap.map(cf => {
    shouldDeepCopy ? cf.fetchState->FetchState.copy : cf.fetchState
  })
}

/**
Simply calls getOrderedNextItem in isolation using the chain manager without
the context of a batch
*/
let nextItemIsNone = (self: t): bool => {
  self->getFetchStateWithData->getOrderedNextItem === None
}

type processingChainMetrics = {
  batchSize: int,
  targetBlockNumber: int,
}

let createOrderedBatch = (
  ~maxBatchSize,
  ~fetchStates: ChainMap.t<FetchState.t>,
  ~mutProcessingMetricsByChainId: dict<processingChainMetrics>,
) => {
  let items = []

  let rec loop = () =>
    if items->Array.length < maxBatchSize {
      switch fetchStates->getOrderedNextItem {
      | Some({earliestEvent}) =>
        switch earliestEvent {
        | NoItem(_) => ()
        | Item({item, popItemOffQueue}) => {
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
      | _ => ()
      }
    }
  loop()

  items
}

let createUnorderedBatch = (
  ~maxBatchSize,
  ~fetchStates: ChainMap.t<FetchState.t>,
  ~mutProcessingMetricsByChainId: dict<processingChainMetrics>,
) => {
  let items = []

  let preparedFetchStates =
    fetchStates
    ->ChainMap.values
    ->FetchState.filterAndSortForUnorderedBatch

  let idx = ref(0)
  let preparedNumber = preparedFetchStates->Array.length
  let batchSize = ref(0)

  // Accumulate items for all actively indexing chains
  // the way to group as many items from a single chain as possible
  // This way the loaders optimisations will hit more often
  while batchSize.contents < maxBatchSize && idx.contents < preparedNumber {
    let fetchState = preparedFetchStates->Array.getUnsafe(idx.contents)
    let batchSizeBeforeTheChain = batchSize.contents

    let rec loop = () =>
      if batchSize.contents < maxBatchSize {
        let earliestEvent = fetchState->FetchState.getEarliestEvent
        switch earliestEvent {
        | NoItem(_) => ()
        | Item({item, popItemOffQueue}) => {
            popItemOffQueue()
            items->Js.Array2.push(item)->ignore
            batchSize := batchSize.contents + 1
            loop()
          }
        }
      }
    loop()

    let chainBatchSize = batchSize.contents - batchSizeBeforeTheChain
    if chainBatchSize > 0 {
      mutProcessingMetricsByChainId->Js.Dict.set(
        fetchState.chainId->Int.toString,
        {
          batchSize: chainBatchSize,
          // If there's the chainBatchSize,
          // then it's guaranteed that the last item belongs to the chain
          targetBlockNumber: (items->Utils.Array.last->Option.getUnsafe).blockNumber,
        },
      )
    }

    idx := idx.contents + 1
  }

  items
}

type batch = {
  items: array<Internal.eventItem>,
  processingMetricsByChainId: dict<processingChainMetrics>,
  fetchStates: ChainMap.t<FetchState.t>,
  dcsToStoreByChainId: dict<array<FetchState.indexingContract>>,
}

let createBatch = (self: t, ~maxBatchSize: int) => {
  let refTime = Hrtime.makeTimer()

  //Make a copy of the queues and fetch states since we are going to mutate them
  let fetchStates = self->getFetchStateWithData(~shouldDeepCopy=true)

  let mutProcessingMetricsByChainId = Js.Dict.empty()
  let items = if self.isUnorderedMultichainMode || fetchStates->ChainMap.size === 1 {
    createUnorderedBatch(~maxBatchSize, ~fetchStates, ~mutProcessingMetricsByChainId)
  } else {
    createOrderedBatch(~maxBatchSize, ~fetchStates, ~mutProcessingMetricsByChainId)
  }

  let dcsToStoreByChainId = Js.Dict.empty()
  // Needed to recalculate the computed queue sizes
  let fetchStates = fetchStates->ChainMap.map(fetchState => {
    switch fetchState.dcsToStore {
    | Some(dcs) => dcsToStoreByChainId->Js.Dict.set(fetchState.chainId->Int.toString, dcs)
    | None => ()
    }
    fetchState->FetchState.updateInternal(~dcsToStore=None)
  })

  let batchSize = items->Array.length
  if batchSize > 0 {
    let fetchedEventsBuffer =
      fetchStates
      ->ChainMap.entries
      ->Array.map(((chain, fetchState)) => (
        chain->ChainMap.Chain.toString,
        fetchState->FetchState.bufferSize,
      ))
      ->Js.Dict.fromArray

    let timeElapsed = refTime->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    Logging.trace({
      "msg": "New batch created for processing",
      "batchSize": batchSize,
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
  }

  {
    items,
    processingMetricsByChainId: mutProcessingMetricsByChainId,
    fetchStates,
    dcsToStoreByChainId,
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
