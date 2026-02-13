open Belt

@@warning("-44")
open Utils.UnsafeIntOperators

type chainAfterBatch = {
  batchSize: int,
  progressBlockNumber: int,
  sourceBlockNumber: int,
  totalEventsProcessed: int,
  fetchState: FetchState.t,
  isProgressAtHeadWhenBatchCreated: bool,
}

type chainBeforeBatch = {
  fetchState: FetchState.t,
  reorgDetection: ReorgDetection.t,
  progressBlockNumber: int,
  sourceBlockNumber: int,
  totalEventsProcessed: int,
}

type t = {
  totalBatchSize: int,
  items: array<Internal.item>,
  progressedChainsById: dict<chainAfterBatch>,
  // Unnest-like checkpoint fields:
  checkpointIds: array<float>,
  checkpointChainIds: array<int>,
  checkpointBlockNumbers: array<int>,
  checkpointBlockHashes: array<Js.Null.t<string>>,
  checkpointEventsProcessed: array<int>,
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
  ~multichain: Config.multichain,
) => {
  switch multichain {
  | Ordered => hasOrderedReadyItem(fetchStates)
  | Unordered => hasUnorderedReadyItem(fetchStates)
  }
}

let getProgressedChainsById = {
  let getChainAfterBatchIfProgressed = (
    ~chainBeforeBatch: chainBeforeBatch,
    ~progressBlockNumberAfterBatch,
    ~fetchStateAfterBatch,
    ~batchSize,
  ) => {
    // The check is sufficient, since we guarantee to include a full block in a batch
    // Also, this might be true even if batchSize is 0,
    // eg when indexing at the head and chain doesn't have items in a block
    if chainBeforeBatch.progressBlockNumber < progressBlockNumberAfterBatch {
      Some(
        (
          {
            batchSize,
            progressBlockNumber: progressBlockNumberAfterBatch,
            sourceBlockNumber: chainBeforeBatch.sourceBlockNumber,
            totalEventsProcessed: chainBeforeBatch.totalEventsProcessed + batchSize,
            fetchState: fetchStateAfterBatch,
            isProgressAtHeadWhenBatchCreated: progressBlockNumberAfterBatch >=
            chainBeforeBatch.sourceBlockNumber,
          }: chainAfterBatch
        ),
      )
    } else {
      None
    }
  }

  (
    ~chainsBeforeBatch: ChainMap.t<chainBeforeBatch>,
    ~batchSizePerChain: dict<int>,
    ~progressBlockNumberPerChain: dict<int>,
  ) => {
    let progressedChainsById = Js.Dict.empty()

    // Needed to:
    // - Recalculate the computed queue sizes
    // - Accumulate registered dynamic contracts to store in the db
    // - Trigger onBlock pointer update
    chainsBeforeBatch
    ->ChainMap.values
    ->Array.forEachU(chainBeforeBatch => {
      let fetchState = chainBeforeBatch.fetchState

      let progressBlockNumberAfterBatch = switch progressBlockNumberPerChain->Utils.Dict.dangerouslyGetNonOption(
        fetchState.chainId->Int.toString,
      ) {
      | Some(progressBlockNumber) => progressBlockNumber
      | None =>
        // If the chain has buffered items, we know there are no events before the first item,
        // so we can advance progress to firstItemBlockNumber - 1
        switch fetchState.buffer->Belt.Array.get(0) {
        | Some(item) =>
          Pervasives.max(
            chainBeforeBatch.progressBlockNumber,
            item->Internal.getItemBlockNumber - 1,
          )
        | None => chainBeforeBatch.progressBlockNumber
        }
      }

      switch switch batchSizePerChain->Utils.Dict.dangerouslyGetNonOption(
        fetchState.chainId->Int.toString,
      ) {
      | Some(batchSize) =>
        let leftItems = fetchState.buffer->Js.Array2.sliceFrom(batchSize)
        getChainAfterBatchIfProgressed(
          ~chainBeforeBatch,
          ~batchSize,
          ~fetchStateAfterBatch=fetchState->FetchState.updateInternal(~mutItems=leftItems),
          ~progressBlockNumberAfterBatch,
        )
      // Skip not affected chains
      | None =>
        getChainAfterBatchIfProgressed(
          ~chainBeforeBatch,
          ~batchSize=0,
          ~fetchStateAfterBatch=chainBeforeBatch.fetchState,
          ~progressBlockNumberAfterBatch,
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

@inline
let addReorgCheckpoints = (
  ~prevCheckpointId,
  ~reorgDetection: ReorgDetection.t,
  ~fromBlockExclusive,
  ~toBlockExclusive,
  ~chainId,
  ~mutCheckpointIds,
  ~mutCheckpointChainIds,
  ~mutCheckpointBlockNumbers,
  ~mutCheckpointBlockHashes,
  ~mutCheckpointEventsProcessed,
) => {
  if (
    reorgDetection.shouldRollbackOnReorg && !(reorgDetection.dataByBlockNumber->Utils.Dict.isEmpty)
  ) {
    let prevCheckpointId = ref(prevCheckpointId)
    for blockNumber in fromBlockExclusive + 1 to toBlockExclusive - 1 {
      switch reorgDetection->ReorgDetection.getHashByBlockNumber(~blockNumber) {
      | Js.Null.Value(hash) =>
        let checkpointId = prevCheckpointId.contents +. 1.
        prevCheckpointId := checkpointId

        mutCheckpointIds->Js.Array2.push(checkpointId)->ignore
        mutCheckpointChainIds->Js.Array2.push(chainId)->ignore
        mutCheckpointBlockNumbers->Js.Array2.push(blockNumber)->ignore
        mutCheckpointBlockHashes->Js.Array2.push(Js.Null.Value(hash))->ignore
        mutCheckpointEventsProcessed->Js.Array2.push(0)->ignore
      | Js.Null.Null => ()
      }
    }
    prevCheckpointId.contents
  } else {
    prevCheckpointId
  }
}

let prepareOrderedBatch = (
  ~checkpointIdBeforeBatch,
  ~chainsBeforeBatch: ChainMap.t<chainBeforeBatch>,
  ~batchSizeTarget,
) => {
  let totalBatchSize = ref(0)
  let isFinished = ref(false)
  let prevCheckpointId = ref(checkpointIdBeforeBatch)
  let mutBatchSizePerChain = Js.Dict.empty()
  let mutProgressBlockNumberPerChain = Js.Dict.empty()

  let fetchStates = chainsBeforeBatch->ChainMap.map(chainBeforeBatch => chainBeforeBatch.fetchState)

  let items = []
  let checkpointIds = []
  let checkpointChainIds = []
  let checkpointBlockNumbers = []
  let checkpointBlockHashes = []
  let checkpointEventsProcessed = []

  while totalBatchSize.contents < batchSizeTarget && !isFinished.contents {
    switch fetchStates->getOrderedNextChain(~batchSizePerChain=mutBatchSizePerChain) {
    | Some(fetchState) => {
        let chainBeforeBatch =
          chainsBeforeBatch->ChainMap.get(ChainMap.Chain.makeUnsafe(~chainId=fetchState.chainId))
        let itemsCountBefore = switch mutBatchSizePerChain->Utils.Dict.dangerouslyGetByIntNonOption(
          fetchState.chainId,
        ) {
        | Some(batchSize) => batchSize
        | None => 0
        }

        let prevBlockNumber = switch mutProgressBlockNumberPerChain->Utils.Dict.dangerouslyGetByIntNonOption(
          fetchState.chainId,
        ) {
        | Some(progressBlockNumber) => progressBlockNumber
        | None => chainBeforeBatch.progressBlockNumber
        }

        let newItemsCount = fetchState->FetchState.getReadyItemsCount(
          // We should get items only for a single block
          // Since for the ordered mode next block could be after another chain's block
          ~targetSize=1,
          ~fromItem=itemsCountBefore,
        )

        if newItemsCount > 0 {
          let item0 = fetchState.buffer->Array.getUnsafe(itemsCountBefore)
          let blockNumber = item0->Internal.getItemBlockNumber

          prevCheckpointId :=
            addReorgCheckpoints(
              ~chainId=fetchState.chainId,
              ~reorgDetection=chainBeforeBatch.reorgDetection,
              ~prevCheckpointId=prevCheckpointId.contents,
              ~fromBlockExclusive=prevBlockNumber,
              ~toBlockExclusive=blockNumber,
              ~mutCheckpointIds=checkpointIds,
              ~mutCheckpointChainIds=checkpointChainIds,
              ~mutCheckpointBlockNumbers=checkpointBlockNumbers,
              ~mutCheckpointBlockHashes=checkpointBlockHashes,
              ~mutCheckpointEventsProcessed=checkpointEventsProcessed,
            )

          let checkpointId = prevCheckpointId.contents +. 1.

          items
          ->Js.Array2.push(item0)
          ->ignore
          for idx in 1 to newItemsCount - 1 {
            items
            ->Js.Array2.push(fetchState.buffer->Belt.Array.getUnsafe(itemsCountBefore + idx))
            ->ignore
          }

          checkpointIds
          ->Js.Array2.push(checkpointId)
          ->ignore
          checkpointChainIds
          ->Js.Array2.push(fetchState.chainId)
          ->ignore
          checkpointBlockNumbers
          ->Js.Array2.push(blockNumber)
          ->ignore
          checkpointBlockHashes
          ->Js.Array2.push(
            chainBeforeBatch.reorgDetection->ReorgDetection.getHashByBlockNumber(~blockNumber),
          )
          ->ignore
          checkpointEventsProcessed
          ->Js.Array2.push(newItemsCount)
          ->ignore

          prevCheckpointId := checkpointId
          totalBatchSize := totalBatchSize.contents + newItemsCount
          mutBatchSizePerChain->Utils.Dict.setByInt(
            fetchState.chainId,
            itemsCountBefore + newItemsCount,
          )
          mutProgressBlockNumberPerChain->Utils.Dict.setByInt(fetchState.chainId, blockNumber)
        } else {
          let blockNumberAfterBatch = fetchState->FetchState.bufferBlockNumber

          prevCheckpointId :=
            addReorgCheckpoints(
              ~chainId=fetchState.chainId,
              ~reorgDetection=chainBeforeBatch.reorgDetection,
              ~prevCheckpointId=prevCheckpointId.contents,
              ~fromBlockExclusive=prevBlockNumber,
              ~toBlockExclusive=blockNumberAfterBatch + 1, // Make it inclusive
              ~mutCheckpointIds=checkpointIds,
              ~mutCheckpointChainIds=checkpointChainIds,
              ~mutCheckpointBlockNumbers=checkpointBlockNumbers,
              ~mutCheckpointBlockHashes=checkpointBlockHashes,
              ~mutCheckpointEventsProcessed=checkpointEventsProcessed,
            )

          // Since the chain was chosen as next
          // the fact that it doesn't have new items means that it reached the buffer block number
          mutProgressBlockNumberPerChain->Utils.Dict.setByInt(
            fetchState.chainId,
            blockNumberAfterBatch,
          )
          isFinished := true
        }
      }

    | None => isFinished := true
    }
  }

  {
    totalBatchSize: totalBatchSize.contents,
    items,
    progressedChainsById: getProgressedChainsById(
      ~chainsBeforeBatch,
      ~batchSizePerChain=mutBatchSizePerChain,
      ~progressBlockNumberPerChain=mutProgressBlockNumberPerChain,
    ),
    checkpointIds,
    checkpointChainIds,
    checkpointBlockNumbers,
    checkpointBlockHashes,
    checkpointEventsProcessed,
  }
}

let prepareUnorderedBatch = (
  ~checkpointIdBeforeBatch,
  ~chainsBeforeBatch: ChainMap.t<chainBeforeBatch>,
  ~batchSizeTarget,
) => {
  let preparedFetchStates =
    chainsBeforeBatch
    ->ChainMap.values
    ->Js.Array2.map(chainBeforeBatch => chainBeforeBatch.fetchState)
    ->FetchState.sortForUnorderedBatch(~batchSizeTarget)

  let chainIdx = ref(0)
  let preparedNumber = preparedFetchStates->Array.length
  let totalBatchSize = ref(0)

  let prevCheckpointId = ref(checkpointIdBeforeBatch)
  let mutBatchSizePerChain = Js.Dict.empty()
  let mutProgressBlockNumberPerChain = Js.Dict.empty()

  let items = []
  let checkpointIds = []
  let checkpointChainIds = []
  let checkpointBlockNumbers = []
  let checkpointBlockHashes = []
  let checkpointEventsProcessed = []

  // Accumulate items for all actively indexing chains
  // the way to group as many items from a single chain as possible
  // This way the loaders optimisations will hit more often
  while totalBatchSize.contents < batchSizeTarget && chainIdx.contents < preparedNumber {
    let fetchState = preparedFetchStates->Js.Array2.unsafe_get(chainIdx.contents)
    let chainBatchSize =
      fetchState->FetchState.getReadyItemsCount(
        ~targetSize=batchSizeTarget - totalBatchSize.contents,
        ~fromItem=0,
      )
    let chainBeforeBatch =
      chainsBeforeBatch->ChainMap.get(ChainMap.Chain.makeUnsafe(~chainId=fetchState.chainId))

    let prevBlockNumber = ref(chainBeforeBatch.progressBlockNumber)
    if chainBatchSize > 0 {
      for idx in 0 to chainBatchSize - 1 {
        let item = fetchState.buffer->Belt.Array.getUnsafe(idx)
        let blockNumber = item->Internal.getItemBlockNumber

        // Every new block we should create a new checkpoint
        if blockNumber !== prevBlockNumber.contents {
          prevCheckpointId :=
            addReorgCheckpoints(
              ~chainId=fetchState.chainId,
              ~reorgDetection=chainBeforeBatch.reorgDetection,
              ~prevCheckpointId=prevCheckpointId.contents,
              ~fromBlockExclusive=prevBlockNumber.contents,
              ~toBlockExclusive=blockNumber,
              ~mutCheckpointIds=checkpointIds,
              ~mutCheckpointChainIds=checkpointChainIds,
              ~mutCheckpointBlockNumbers=checkpointBlockNumbers,
              ~mutCheckpointBlockHashes=checkpointBlockHashes,
              ~mutCheckpointEventsProcessed=checkpointEventsProcessed,
            )

          let checkpointId = prevCheckpointId.contents +. 1.

          checkpointIds->Js.Array2.push(checkpointId)->ignore
          checkpointChainIds->Js.Array2.push(fetchState.chainId)->ignore
          checkpointBlockNumbers->Js.Array2.push(blockNumber)->ignore
          checkpointBlockHashes
          ->Js.Array2.push(
            chainBeforeBatch.reorgDetection->ReorgDetection.getHashByBlockNumber(~blockNumber),
          )
          ->ignore
          checkpointEventsProcessed->Js.Array2.push(1)->ignore

          prevBlockNumber := blockNumber
          prevCheckpointId := checkpointId
        } else {
          let lastIndex = checkpointEventsProcessed->Array.length - 1
          checkpointEventsProcessed
          ->Belt.Array.setUnsafe(
            lastIndex,
            checkpointEventsProcessed->Array.getUnsafe(lastIndex) + 1,
          )
          ->ignore
        }

        items->Js.Array2.push(item)->ignore
      }

      totalBatchSize := totalBatchSize.contents + chainBatchSize
      mutBatchSizePerChain->Utils.Dict.setByInt(fetchState.chainId, chainBatchSize)
    }

    let progressBlockNumberAfterBatch =
      fetchState->FetchState.getUnorderedMultichainProgressBlockNumberAt(~index=chainBatchSize)

    prevCheckpointId :=
      addReorgCheckpoints(
        ~chainId=fetchState.chainId,
        ~reorgDetection=chainBeforeBatch.reorgDetection,
        ~prevCheckpointId=prevCheckpointId.contents,
        ~fromBlockExclusive=prevBlockNumber.contents,
        ~toBlockExclusive=progressBlockNumberAfterBatch + 1, // Make it inclusive
        ~mutCheckpointIds=checkpointIds,
        ~mutCheckpointChainIds=checkpointChainIds,
        ~mutCheckpointBlockNumbers=checkpointBlockNumbers,
        ~mutCheckpointBlockHashes=checkpointBlockHashes,
        ~mutCheckpointEventsProcessed=checkpointEventsProcessed,
      )

    mutProgressBlockNumberPerChain->Utils.Dict.setByInt(
      fetchState.chainId,
      progressBlockNumberAfterBatch,
    )

    chainIdx := chainIdx.contents + 1
  }

  {
    totalBatchSize: totalBatchSize.contents,
    items,
    progressedChainsById: getProgressedChainsById(
      ~chainsBeforeBatch,
      ~batchSizePerChain=mutBatchSizePerChain,
      ~progressBlockNumberPerChain=mutProgressBlockNumberPerChain,
    ),
    checkpointIds,
    checkpointChainIds,
    checkpointBlockNumbers,
    checkpointBlockHashes,
    checkpointEventsProcessed,
  }
}

let make = (
  ~checkpointIdBeforeBatch,
  ~chainsBeforeBatch: ChainMap.t<chainBeforeBatch>,
  ~multichain: Config.multichain,
  ~batchSizeTarget,
) => {
  if (
    switch multichain {
    | Unordered => true
    | Ordered => chainsBeforeBatch->ChainMap.size === 1
    }
  ) {
    prepareUnorderedBatch(~checkpointIdBeforeBatch, ~chainsBeforeBatch, ~batchSizeTarget)
  } else {
    prepareOrderedBatch(~checkpointIdBeforeBatch, ~chainsBeforeBatch, ~batchSizeTarget)
  }
}

let findFirstEventBlockNumber = (batch: t, ~chainId) => {
  let idx = ref(0)
  let result = ref(None)
  let checkpointsLength = batch.checkpointIds->Array.length
  while idx.contents < checkpointsLength && result.contents === None {
    let checkpointChainId = batch.checkpointChainIds->Array.getUnsafe(idx.contents)
    if (
      checkpointChainId === chainId &&
        batch.checkpointEventsProcessed->Array.getUnsafe(idx.contents) > 0
    ) {
      result := Some(batch.checkpointBlockNumbers->Array.getUnsafe(idx.contents))
    } else {
      idx := idx.contents + 1
    }
  }
  result.contents
}

let findLastEventItem = (batch: t, ~chainId) => {
  let idx = ref(batch.items->Array.length - 1)
  let result = ref(None)
  while idx.contents >= 0 && result.contents === None {
    let item = batch.items->Array.getUnsafe(idx.contents)
    switch item {
    | Internal.Event(_) as eventItem => {
        let eventItem = eventItem->Internal.castUnsafeEventItem
        if eventItem.chain->ChainMap.Chain.toChainId === chainId {
          result := Some(eventItem)
        } else {
          idx := idx.contents - 1
        }
      }
    | Internal.Block(_) => idx := idx.contents - 1
    }
  }
  result.contents
}
