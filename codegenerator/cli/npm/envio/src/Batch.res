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
  updatedFetchStates: ChainMap.t<FetchState.t>,
  dcsToStoreByChainId: dict<array<FetchState.indexingContract>>,
  creationTimeMs: int,
}

/**
 It either returnes an earliest item among all chains, or None if no chains are actively indexing
 */
let getOrderedNextChain = (fetchStates: ChainMap.t<FetchState.t>, ~batchSizePerChain) => {
  let earliestChain: ref<option<FetchState.t>> = ref(None)
  let earliestChainTimestamp = ref(0)
  let chainKeys = fetchStates->ChainMap.keys
  for idx in 0 to chainKeys->Array.length - 1 {
    let chain = chainKeys->Array.get(idx)
    let fetchState = fetchStates->ChainMap.get(chain)
    if fetchState->FetchState.isActivelyIndexing {
      let timestamp = fetchState->FetchState.getTimestampAt(
        ~index=switch batchSizePerChain->Utils.Dict.dangerouslyGetByIntNonOption(
          chain->ChainMap.Chain.toChainId,
        ) {
        | Some(batchSize) => batchSize
        | None => 0
        },
      )
      switch earliestChain.contents {
      | Some(earliestChain)
        if timestamp > earliestChainTimestamp.contents ||
          (timestamp === earliestChainTimestamp.contents &&
            chain->ChainMap.Chain.toChainId > earliestChain.chainId) => ()
      | _ => {
          earliestChain := Some(fetchState)
          earliestChainTimestamp := timestamp
        }
      }
    }
  }
  earliestChain.contents
}

// Save overhead of recreating the dict every time
let immutableEmptyBatchSizePerChain: dict<int> = Js.Dict.empty()
let hasOrderedReadyItem = (fetchStates: ChainMap.t<FetchState.t>) => {
  switch fetchStates->getOrderedNextChain(~batchSizePerChain=immutableEmptyBatchSizePerChain) {
  | Some(fetchState) => fetchState->FetchState.hasReadyItem
  | None => false
  }
}

let hasUnorderedReadyItem = (fetchStates: ChainMap.t<FetchState.t>) => {
  fetchStates
  ->ChainMap.values
  ->Js.Array2.some(fetchState => {
    fetchState->FetchState.isActivelyIndexing && fetchState->FetchState.hasReadyItem
  })
}

let hasMultichainReadyItem = (
  fetchStates: ChainMap.t<FetchState.t>,
  ~multichain: InternalConfig.multichain,
) => {
  switch multichain {
  | Ordered => hasOrderedReadyItem(fetchStates)
  | Unordered => hasUnorderedReadyItem(fetchStates)
  }
}

let prepareOrderedBatch = (
  ~batchSizeTarget,
  ~fetchStates: ChainMap.t<FetchState.t>,
  ~mutBatchSizePerChain: dict<int>,
) => {
  let batchSize = ref(0)
  let isFinished = ref(false)
  let items = []

  while batchSize.contents < batchSizeTarget && !isFinished.contents {
    switch fetchStates->getOrderedNextChain(~batchSizePerChain=mutBatchSizePerChain) {
    | Some(fetchState) => {
        let itemsCountBefore = switch mutBatchSizePerChain->Utils.Dict.dangerouslyGetByIntNonOption(
          fetchState.chainId,
        ) {
        | Some(batchSize) => batchSize
        | None => 0
        }
        let newItemsCount =
          fetchState->FetchState.getReadyItemsCount(
            ~targetSize=batchSizeTarget - batchSize.contents,
            ~fromItem=itemsCountBefore,
          )

        if newItemsCount > 0 {
          for idx in itemsCountBefore to itemsCountBefore + newItemsCount - 1 {
            items->Js.Array2.push(fetchState->FetchState.getUnsafeItemAt(~index=idx))->ignore
          }
          batchSize := batchSize.contents + newItemsCount
          mutBatchSizePerChain->Utils.Dict.setByInt(
            fetchState.chainId,
            itemsCountBefore + newItemsCount,
          )
        } else {
          isFinished := true
        }
      }

    | None => isFinished := true
    }
  }

  items
}

let prepareUnorderedBatch = (
  ~batchSizeTarget,
  ~fetchStates: ChainMap.t<FetchState.t>,
  ~mutBatchSizePerChain: dict<int>,
) => {
  let preparedFetchStates =
    fetchStates
    ->ChainMap.values
    ->FetchState.filterAndSortForUnorderedBatch(~batchSizeTarget)

  let chainIdx = ref(0)
  let preparedNumber = preparedFetchStates->Array.length
  let batchSize = ref(0)

  let items = []

  // Accumulate items for all actively indexing chains
  // the way to group as many items from a single chain as possible
  // This way the loaders optimisations will hit more often
  while batchSize.contents < batchSizeTarget && chainIdx.contents < preparedNumber {
    let fetchState = preparedFetchStates->Js.Array2.unsafe_get(chainIdx.contents)
    let chainBatchSize =
      fetchState->FetchState.getReadyItemsCount(
        ~targetSize=batchSizeTarget - batchSize.contents,
        ~fromItem=0,
      )
    if chainBatchSize > 0 {
      for idx in 0 to chainBatchSize - 1 {
        items->Js.Array2.push(fetchState->FetchState.getUnsafeItemAt(~index=idx))->ignore
      }
      batchSize := batchSize.contents + chainBatchSize
      mutBatchSizePerChain->Utils.Dict.setByInt(fetchState.chainId, chainBatchSize)
    }

    chainIdx := chainIdx.contents + 1
  }

  items
}
