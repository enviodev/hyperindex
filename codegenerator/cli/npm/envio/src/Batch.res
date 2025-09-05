type progressedChain = {
  chainId: int,
  batchSize: int,
  progressBlockNumber: int,
  progressNextBlockLogIndex: option<int>,
  totalEventsProcessed: int,
}

type t = {
  items: array<Internal.item>,
  progressedChains: array<progressedChain>,
  fetchStates: ChainMap.t<FetchState.t>,
  dcsToStoreByChainId: dict<array<FetchState.indexingContract>>,
}

type multiChainEventComparitor = {
  chain: ChainMap.Chain.t,
  earliestEvent: FetchState.queueItem,
}

let getComparitorFromItem = (queueItem: Internal.item) => {
  let {timestamp, chain, blockNumber, logIndex} = queueItem
  EventUtils.getEventComparator({
    timestamp,
    chainId: chain->ChainMap.Chain.toChainId,
    blockNumber,
    logIndex,
  })
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
  ->Belt.Array.reduce(None, (accum, (chain, fetchState)) => {
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

let popOrderedBatchItems = (
  ~maxBatchSize,
  ~fetchStates: ChainMap.t<FetchState.t>,
  ~sizePerChain: dict<int>,
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
            sizePerChain->Utils.Dict.incrementByInt(item.chain->ChainMap.Chain.toChainId)
            loop()
          }
        }
      | _ => ()
      }
    }
  loop()

  items
}

let popUnorderedBatchItems = (
  ~maxBatchSize,
  ~fetchStates: ChainMap.t<FetchState.t>,
  ~sizePerChain: dict<int>,
) => {
  let items = []

  let preparedFetchStates =
    fetchStates
    ->ChainMap.values
    ->FetchState.filterAndSortForUnorderedBatch(~maxBatchSize)

  let idx = ref(0)
  let preparedNumber = preparedFetchStates->Array.length
  let batchSize = ref(0)

  // Accumulate items for all actively indexing chains
  // the way to group as many items from a single chain as possible
  // This way the loaders optimisations will hit more often
  while batchSize.contents < maxBatchSize && idx.contents < preparedNumber {
    let fetchState = preparedFetchStates->Js.Array2.unsafe_get(idx.contents)
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
      sizePerChain->Utils.Dict.setByInt(fetchState.chainId, chainBatchSize)
    }

    idx := idx.contents + 1
  }

  items
}
