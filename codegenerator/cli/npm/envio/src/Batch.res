open Belt

type chainAfterBatch = {
  batchSize: int,
  progressBlockNumber: int,
  totalEventsProcessed: int,
  fetchState: FetchState.t,
  dcsToStore: option<array<FetchState.indexingContract>>,
  isProgressAtHeadWhenBatchCreated: bool,
}

type chainBeforeBatch = {
  fetchState: FetchState.t,
  progressBlockNumber: int,
  sourceBlockNumber: int,
  totalEventsProcessed: int,
}

type t = {
  items: array<Internal.item>,
  progressedChainsById: dict<chainAfterBatch>,
}

/**
 It either returnes an earliest item among all chains, or None if no chains are actively indexing
 */
let getOrderedNextChain = (fetchStates: ChainMap.t<FetchState.t>, ~batchSizePerChain) => {
  let earliestChain: ref<option<FetchState.t>> = ref(None)
  let earliestChainTimestamp = ref(0)
  let chainKeys = fetchStates->ChainMap.keys
  for idx in 0 to chainKeys->Array.length - 1 {
    let chain = chainKeys->Array.getUnsafe(idx)
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

let getProgressedChainsById = {
  let getChainAfterBatchIfProgressed = (
    ~chainBeforeBatch: chainBeforeBatch,
    ~updatedFetchState,
    ~batchSize,
    ~dcsToStore,
  ) => {
    let nextProgressBlockNumber = updatedFetchState->FetchState.getProgressBlockNumber

    // The check is sufficient, since we guarantee to include a full block in a batch
    // Also, this might be true even if batchSize is 0,
    // eg when indexing at the head and chain doesn't have items in a block
    if chainBeforeBatch.progressBlockNumber < nextProgressBlockNumber {
      Some(
        (
          {
            batchSize,
            progressBlockNumber: nextProgressBlockNumber,
            totalEventsProcessed: chainBeforeBatch.totalEventsProcessed + batchSize,
            dcsToStore,
            fetchState: updatedFetchState,
            isProgressAtHeadWhenBatchCreated: nextProgressBlockNumber >=
            chainBeforeBatch.sourceBlockNumber,
          }: chainAfterBatch
        ),
      )
    } else {
      None
    }
  }

  (~chainsBeforeBatch: ChainMap.t<chainBeforeBatch>, ~batchSizePerChain: dict<int>) => {
    let progressedChainsById = Js.Dict.empty()

    // Needed to:
    // - Recalculate the computed queue sizes
    // - Accumulate registered dynamic contracts to store in the db
    // - Trigger onBlock pointer update
    chainsBeforeBatch
    ->ChainMap.values
    ->Array.forEachU(chainBeforeBatch => {
      let fetchState = chainBeforeBatch.fetchState
      switch switch batchSizePerChain->Utils.Dict.dangerouslyGetNonOption(
        fetchState.chainId->Int.toString,
      ) {
      | Some(batchSize) =>
        let leftItems = fetchState.buffer->Js.Array2.sliceFrom(batchSize)
        switch fetchState.dcsToStore {
        | [] =>
          getChainAfterBatchIfProgressed(
            ~chainBeforeBatch,
            ~batchSize,
            ~dcsToStore=None,
            ~updatedFetchState=fetchState->FetchState.updateInternal(~mutItems=leftItems),
          )

        | dcs => {
            let leftDcsToStore = []
            let batchDcs = []
            let updatedFetchState =
              fetchState->FetchState.updateInternal(~mutItems=leftItems, ~dcsToStore=leftDcsToStore)
            let nextProgressBlockNumber = updatedFetchState->FetchState.getProgressBlockNumber

            dcs->Array.forEach(dc => {
              // Important: This should be a registering block number.
              // This works for now since dc.startBlock is a registering block number.
              if dc.startBlock <= nextProgressBlockNumber {
                batchDcs->Array.push(dc)
              } else {
                // Mutate the array we passed to the updateInternal beforehand
                leftDcsToStore->Array.push(dc)
              }
            })

            getChainAfterBatchIfProgressed(
              ~chainBeforeBatch,
              ~batchSize,
              ~dcsToStore=Some(batchDcs),
              ~updatedFetchState,
            )
          }
        }
      // Skip not affected chains
      | None =>
        getChainAfterBatchIfProgressed(
          ~chainBeforeBatch,
          ~batchSize=0,
          ~dcsToStore=None,
          ~updatedFetchState=chainBeforeBatch.fetchState,
        )
      } {
      | Some(progressedChain) =>
        progressedChainsById->Utils.Dict.setByInt(
          chainBeforeBatch.fetchState.chainId,
          progressedChain,
        )
      | None => ()
      }
    })

    progressedChainsById
  }
}

let prepareOrderedBatch = (~chainsBeforeBatch: ChainMap.t<chainBeforeBatch>, ~batchSizeTarget) => {
  let batchSize = ref(0)
  let isFinished = ref(false)
  let mutBatchSizePerChain = Js.Dict.empty()
  let items = []
  let fetchStates = chainsBeforeBatch->ChainMap.map(chainBeforeBatch => chainBeforeBatch.fetchState)

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
            items->Js.Array2.push(fetchState.buffer->Belt.Array.getUnsafe(idx))->ignore
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

  {
    items,
    progressedChainsById: getProgressedChainsById(
      ~chainsBeforeBatch,
      ~batchSizePerChain=mutBatchSizePerChain,
    ),
  }
}

let prepareUnorderedBatch = (
  ~chainsBeforeBatch: ChainMap.t<chainBeforeBatch>,
  ~batchSizeTarget,
) => {
  let preparedFetchStates =
    chainsBeforeBatch
    ->ChainMap.values
    ->Js.Array2.map(chainBeforeBatch => chainBeforeBatch.fetchState)
    ->FetchState.filterAndSortForUnorderedBatch(~batchSizeTarget)

  let chainIdx = ref(0)
  let preparedNumber = preparedFetchStates->Array.length
  let batchSize = ref(0)

  let mutBatchSizePerChain = Js.Dict.empty()
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
        items->Js.Array2.push(fetchState.buffer->Belt.Array.getUnsafe(idx))->ignore
      }
      batchSize := batchSize.contents + chainBatchSize
      mutBatchSizePerChain->Utils.Dict.setByInt(fetchState.chainId, chainBatchSize)
    }

    chainIdx := chainIdx.contents + 1
  }

  {
    items,
    progressedChainsById: getProgressedChainsById(
      ~chainsBeforeBatch,
      ~batchSizePerChain=mutBatchSizePerChain,
    ),
  }
}

let make = (
  ~chainsBeforeBatch: ChainMap.t<chainBeforeBatch>,
  ~multichain: InternalConfig.multichain,
  ~batchSizeTarget,
) => {
  if (
    switch multichain {
    | Unordered => true
    | Ordered => chainsBeforeBatch->ChainMap.size === 1
    }
  ) {
    prepareUnorderedBatch(~chainsBeforeBatch, ~batchSizeTarget)
  } else {
    prepareOrderedBatch(~chainsBeforeBatch, ~batchSizeTarget)
  }
}
