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

/**
 It either returnes an earliest item among all chains, or None if no chains are actively indexing
 */
let getOrderedNextItem = (fetchStatesMap: ChainMap.t<fetchStateWithData>): option<
  multiChainEventComparitor,
> => {
  fetchStatesMap
  ->ChainMap.entries
  ->Array.reduce(None, (accum, (chain, {fetchState})) => {
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
  ~fetchStatesMap: ChainMap.t<fetchStateWithData>,
  ~onlyBelowReorgThreshold,
  ~mutProcessingMetricsByChainId: dict<processingChainMetrics>,
) => {
  let isInReorgThresholdRef = ref(false)
  let items = []

  let rec loop = () =>
    if items->Array.length < maxBatchSize {
      switch fetchStatesMap->getOrderedNextItem {
      | Some({earliestEvent, chain}) =>
        isInReorgThresholdRef :=
          isInReorgThresholdRef.contents || {
            let {currentBlockHeight, highestBlockBelowThreshold} =
              fetchStatesMap->ChainMap.get(chain)
            earliestEvent->FetchState.queueItemIsInReorgThreshold(
              ~currentBlockHeight,
              ~highestBlockBelowThreshold,
            )
          }

        switch earliestEvent {
        | NoItem(_) => ()
        | Item({item, popItemOffQueue}) => {
            // To ensure history saving only starts when all chains have reached their reorg threshold
            let shouldNotAddItem = onlyBelowReorgThreshold && isInReorgThresholdRef.contents
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
      | _ => ()
      }
    }
  loop()

  (items, isInReorgThresholdRef.contents)
}

// Use a global pointer to spread the processing across chains
let nextChainIdx = ref(0)

let createUnorderedBatch = (
  ~maxBatchSize,
  ~fetchStatesMap: ChainMap.t<fetchStateWithData>,
  ~onlyBelowReorgThreshold,
  ~mutProcessingMetricsByChainId: dict<processingChainMetrics>,
) => {
  let items = []

  let chains = fetchStatesMap->ChainMap.keys
  let unprocessedChains = ref(chains->Array.length) // Prevent entering the same chain twice
  let batchSize = ref(0) // Faster than Array.length

  // Accumulate items for all actively indexing chains
  // the way to group as many items from a single chain as possible
  // This way the loaders optimisations will hit more often
  // Also, keep the nextChainIdx global, so we start with a new chain every batch
  while batchSize.contents < maxBatchSize && unprocessedChains.contents > 0 {
    let chainIdx = nextChainIdx.contents
    switch chains->Array.get(chainIdx) {
    | None => nextChainIdx := 0
    | Some(chain) => {
        let {fetchState, currentBlockHeight, highestBlockBelowThreshold} =
          fetchStatesMap->ChainMap.get(chain)

        // If the fetch state has reached the end block we don't need to consider it
        if fetchState->FetchState.isActivelyIndexing {
          let batchSizeBeforeTheChain = batchSize.contents

          let rec loop = () =>
            if batchSize.contents < maxBatchSize {
              let earliestEvent = fetchState->FetchState.getEarliestEvent
              switch earliestEvent {
              | NoItem(_) => ()
              | Item({item, popItemOffQueue}) =>
                // To ensure history saving only starts when all chains have reached their reorg threshold
                let shouldNotAddItem =
                  onlyBelowReorgThreshold &&
                  earliestEvent->FetchState.queueItemIsInReorgThreshold(
                    ~currentBlockHeight,
                    ~highestBlockBelowThreshold,
                  )
                if !shouldNotAddItem {
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
              chain->ChainMap.Chain.toChainId->Int.toString,
              {
                batchSize: chainBatchSize,
                // If there's the chainBatchSize,
                // then it's guaranteed that the last item belongs to the chain
                targetBlockNumber: (items->Utils.Array.last->Option.getUnsafe).blockNumber,
              },
            )
          }
        }

        nextChainIdx := nextChainIdx.contents + 1
        unprocessedChains := unprocessedChains.contents - 1
      }
    }
  }

  (
    items,
    // For unordered mode need to perform the check at the end of the batch
    // using getOrderedNextItem, so we can determine that all chains reached unordered threshold
    switch fetchStatesMap->getOrderedNextItem {
    | None => false
    | Some({earliestEvent, chain}) =>
      let {currentBlockHeight, highestBlockBelowThreshold} = fetchStatesMap->ChainMap.get(chain)
      earliestEvent->FetchState.queueItemIsInReorgThreshold(
        ~currentBlockHeight,
        ~highestBlockBelowThreshold,
      )
    },
  )
}

type batch = {
  items: array<Internal.eventItem>,
  processingMetricsByChainId: dict<processingChainMetrics>,
  fetchStatesMap: ChainMap.t<fetchStateWithData>,
  dcsToStoreByChainId: dict<array<FetchState.indexingContract>>,
  isInReorgThreshold: bool,
}

let createBatch = (self: t, ~maxBatchSize: int, ~onlyBelowReorgThreshold: bool) => {
  let refTime = Hrtime.makeTimer()

  //Make a copy of the queues and fetch states since we are going to mutate them
  let fetchStatesMap = self->getFetchStateWithData(~shouldDeepCopy=true)

  let mutProcessingMetricsByChainId = Js.Dict.empty()
  let (items, isInReorgThreshold) = if (
    self.isUnorderedMultichainMode || fetchStatesMap->ChainMap.size === 1
  ) {
    createUnorderedBatch(
      ~maxBatchSize,
      ~fetchStatesMap,
      ~onlyBelowReorgThreshold,
      ~mutProcessingMetricsByChainId,
    )
  } else {
    createOrderedBatch(
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

  let batchSize = items->Array.length
  if batchSize > 0 {
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
