open Belt

@@warning("-44")
open Utils.UnsafeIntOperators

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
  reorgDetection: ReorgDetection.t,
  progressBlockNumber: int,
  sourceBlockNumber: int,
  totalEventsProcessed: int,
}

// This is a micro-optimization to avoid unnecessary object allocations
// Item 0 is totalBatchSize: int
// Item 1 is progressedChainsById: dict<chainAfterBatch>
// The rest are checkpoints where
// The 2nd is checkpointId: int
// The 3rd is chainId: int
// The 4th is blockNumber: int
// The 5th is blockHash: option<string>
// The 6th is eventsProcessed: int
// The xths are items of the checkpoint
// The (7+eventsProcessed)th is the next checkpointId

type t = array<unknown>

let totalBatchSizeIndex = 0
@get
external totalBatchSize: t => int = "0"

let progressedChainsByIdIndex = 1
@get
external progressedChainsById: t => dict<chainAfterBatch> = "1"

let checkpointsStartIndex = 2

let checkpointIdOffset = 0
let chainIdOffset = 1
let blockNumberOffset = 2
let blockHashOffset = 3
let eventsProcessedOffset = 4
let itemsStartOffset = 5

let fixedCheckpointFields = 5

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
    ~progressBlockNumberAfterBatch,
    ~fetchStateAfterBatch,
    ~batchSize,
    ~dcsToStore,
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
            totalEventsProcessed: chainBeforeBatch.totalEventsProcessed + batchSize,
            dcsToStore,
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
      | None => chainBeforeBatch.progressBlockNumber
      }

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
            ~fetchStateAfterBatch=fetchState->FetchState.updateInternal(~mutItems=leftItems),
            ~progressBlockNumberAfterBatch,
          )

        | dcs => {
            let leftDcsToStore = []
            let batchDcs = []
            let fetchStateAfterBatch =
              fetchState->FetchState.updateInternal(~mutItems=leftItems, ~dcsToStore=leftDcsToStore)

            dcs->Array.forEach(dc => {
              // Important: This should be a registering block number.
              // This works for now since dc.startBlock is a registering block number.
              if dc.startBlock <= progressBlockNumberAfterBatch {
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
              ~fetchStateAfterBatch,
              ~progressBlockNumberAfterBatch,
            )
          }
        }
      // Skip not affected chains
      | None =>
        getChainAfterBatchIfProgressed(
          ~chainBeforeBatch,
          ~batchSize=0,
          ~dcsToStore=None,
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
let getCheckpointIndex = (~checkpointId, ~checkpointIdBeforeBatch, ~totalBatchSize) => {
  checkpointsStartIndex +
  (checkpointId - checkpointIdBeforeBatch - 1) * fixedCheckpointFields +
  totalBatchSize
}

let prepareOrderedBatch = (
  ~checkpointIdBeforeBatch,
  ~chainsBeforeBatch: ChainMap.t<chainBeforeBatch>,
  ~batchSizeTarget,
) => {
  let totalBatchSize = ref(0)
  let isFinished = ref(false)
  let mutBatchSizePerChain = Js.Dict.empty()
  let mutProgressBlockNumberPerChain = Js.Dict.empty()

  let checkpointIdAfterBatch = ref(checkpointIdBeforeBatch)
  let fetchStates = chainsBeforeBatch->ChainMap.map(chainBeforeBatch => chainBeforeBatch.fetchState)

  let batch = []

  while totalBatchSize.contents < batchSizeTarget && !isFinished.contents {
    switch fetchStates->getOrderedNextChain(~batchSizePerChain=mutBatchSizePerChain) {
    | Some(fetchState) => {
        let itemsCountBefore = switch mutBatchSizePerChain->Utils.Dict.dangerouslyGetByIntNonOption(
          fetchState.chainId,
        ) {
        | Some(batchSize) => batchSize
        | None => 0
        }
        let newItemsCount = fetchState->FetchState.getReadyItemsCount(
          // We should get items only for a single block
          // Since for the ordered mode next block could be after another chain's block
          ~targetSize=1,
          ~fromItem=itemsCountBefore,
        )

        if newItemsCount > 0 {
          let checkpointId = checkpointIdAfterBatch.contents + 1
          checkpointIdAfterBatch := checkpointId
          let checkpointIndex = getCheckpointIndex(
            ~checkpointId,
            ~checkpointIdBeforeBatch,
            ~totalBatchSize=totalBatchSize.contents,
          )

          let blockNumber =
            fetchState.buffer->Array.getUnsafe(itemsCountBefore)->Internal.getItemBlockNumber

          for idx in itemsCountBefore to itemsCountBefore + newItemsCount - 1 {
            batch->Array.setUnsafe(
              checkpointIndex + itemsStartOffset + idx,
              fetchState.buffer->Belt.Array.getUnsafe(idx)->(Utils.magic: Internal.item => unknown),
            )
          }
          batch->Array.setUnsafe(
            checkpointIndex + checkpointIdOffset,
            checkpointId->(Utils.magic: int => unknown),
          )
          batch->Array.setUnsafe(
            checkpointIndex + chainIdOffset,
            fetchState.chainId->(Utils.magic: int => unknown),
          )
          batch->Array.setUnsafe(
            checkpointIndex + blockNumberOffset,
            blockNumber->(Utils.magic: int => unknown),
          )
          // batch->Array.setUnsafe(
          //   checkpointIndex + blockHashOffset,
          //   fetchState.buffer->Array.getUnsafe(itemsCountBefore)->Internal.getItemBlockHash,
          // )
          batch->Array.setUnsafe(
            checkpointIndex + eventsProcessedOffset,
            newItemsCount->(Utils.magic: int => unknown),
          )
          totalBatchSize := totalBatchSize.contents + newItemsCount
          mutBatchSizePerChain->Utils.Dict.setByInt(
            fetchState.chainId,
            itemsCountBefore + newItemsCount,
          )
          mutProgressBlockNumberPerChain->Utils.Dict.setByInt(fetchState.chainId, blockNumber)
        } else {
          // Since the chain was chosen as next
          // the fact that it doesn't have new items means that it reached the buffer block number
          mutProgressBlockNumberPerChain->Utils.Dict.setByInt(
            fetchState.chainId,
            fetchState->FetchState.bufferBlockNumber,
          )
          isFinished := true
        }
      }

    | None => isFinished := true
    }
  }

  batch->Array.setUnsafe(
    totalBatchSizeIndex,
    totalBatchSize.contents->(Utils.magic: int => unknown),
  )
  batch->Array.setUnsafe(
    progressedChainsByIdIndex,
    getProgressedChainsById(
      ~chainsBeforeBatch,
      ~batchSizePerChain=mutBatchSizePerChain,
      ~progressBlockNumberPerChain=mutProgressBlockNumberPerChain,
    )->(Utils.magic: dict<chainAfterBatch> => unknown),
  )
  batch
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
    ->FetchState.filterAndSortForUnorderedBatch(~batchSizeTarget)

  let chainIdx = ref(0)
  let preparedNumber = preparedFetchStates->Array.length
  let totalBatchSize = ref(0)

  let checkpointIdAfterBatch = ref(checkpointIdBeforeBatch)
  let mutBatchSizePerChain = Js.Dict.empty()
  let mutProgressBlockNumberPerChain = Js.Dict.empty()

  let batch = []

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
    if chainBatchSize > 0 {
      let prevBlockNumber = ref(-1)
      let sameBlockIndex = ref(0)
      let checkpointIndexRef = ref(-1)
      for idx in 0 to chainBatchSize - 1 {
        let item = fetchState.buffer->Belt.Array.getUnsafe(idx)
        let blockNumber = item->Internal.getItemBlockNumber

        // Populating batch with items, every block number
        // should create a new checkpoint
        if blockNumber !== prevBlockNumber.contents {
          let checkpointId = checkpointIdAfterBatch.contents + 1

          let checkpointIndex = if checkpointIndexRef.contents !== -1 {
            let prevCheckpointIndex = checkpointIndexRef.contents
            let prevCheckpointItemsCount = sameBlockIndex.contents
            batch->Array.setUnsafe(
              prevCheckpointIndex + eventsProcessedOffset,
              prevCheckpointItemsCount->(Utils.magic: int => unknown),
            )
            prevCheckpointIndex + itemsStartOffset + prevCheckpointItemsCount
          } else {
            getCheckpointIndex(
              ~checkpointId,
              ~checkpointIdBeforeBatch,
              ~totalBatchSize=totalBatchSize.contents,
            )
          }

          batch->Array.setUnsafe(
            checkpointIndex + blockNumberOffset,
            blockNumber->(Utils.magic: int => unknown),
          )
          batch->Array.setUnsafe(
            checkpointIndex + checkpointIdOffset,
            checkpointId->(Utils.magic: int => unknown),
          )
          batch->Array.setUnsafe(
            checkpointIndex + chainIdOffset,
            fetchState.chainId->(Utils.magic: int => unknown),
          )

          // batch->Array.setUnsafe(
          //   checkpointIndex + blockHashOffset,
          //   fetchState.buffer->Array.getUnsafe(itemsCountBefore)->Internal.getItemBlockHash,
          // )
          checkpointIndexRef := checkpointIndex
          prevBlockNumber := blockNumber
          sameBlockIndex := 0
          checkpointIdAfterBatch := checkpointId
        }

        batch->Array.setUnsafe(
          checkpointIndexRef.contents + itemsStartOffset + sameBlockIndex.contents,
          item->(Utils.magic: Internal.item => unknown),
        )
        sameBlockIndex := sameBlockIndex.contents + 1
      }

      batch->Array.setUnsafe(
        checkpointIndexRef.contents + eventsProcessedOffset,
        sameBlockIndex.contents->(Utils.magic: int => unknown),
      )

      totalBatchSize := totalBatchSize.contents + chainBatchSize
      mutBatchSizePerChain->Utils.Dict.setByInt(fetchState.chainId, chainBatchSize)
    }

    mutProgressBlockNumberPerChain->Utils.Dict.setByInt(
      fetchState.chainId,
      fetchState->FetchState.getUnorderedMultichainProgressBlockNumberAt(~index=chainBatchSize),
    )

    chainIdx := chainIdx.contents + 1
  }

  batch->Array.setUnsafe(
    totalBatchSizeIndex,
    totalBatchSize.contents->(Utils.magic: int => unknown),
  )
  batch->Array.setUnsafe(
    progressedChainsByIdIndex,
    getProgressedChainsById(
      ~chainsBeforeBatch,
      ~batchSizePerChain=mutBatchSizePerChain,
      ~progressBlockNumberPerChain=mutProgressBlockNumberPerChain,
    )->(Utils.magic: dict<chainAfterBatch> => unknown),
  )
  batch
}

let make = (
  ~checkpointIdBeforeBatch,
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
    prepareUnorderedBatch(~checkpointIdBeforeBatch, ~chainsBeforeBatch, ~batchSizeTarget)
  } else {
    prepareOrderedBatch(~checkpointIdBeforeBatch, ~chainsBeforeBatch, ~batchSizeTarget)
  }
}

let keepMap = (batch: t, f) => {
  let length = batch->Array.length
  let checkpointIndex = ref(checkpointsStartIndex)
  let result = []
  while checkpointIndex.contents < length {
    let eventsProcessed =
      batch
      ->Array.getUnsafe(checkpointIndex.contents + eventsProcessedOffset)
      ->(Utils.magic: unknown => int)
    for idx in 0 to eventsProcessed - 1 {
      let item =
        batch
        ->Array.getUnsafe(checkpointIndex.contents + itemsStartOffset + idx)
        ->(Utils.magic: unknown => Internal.item)
      switch f(item) {
      | Some(value) => result->Array.push(value)
      | None => ()
      }
    }
    checkpointIndex := checkpointIndex.contents + fixedCheckpointFields + eventsProcessed
  }
  result
}

let findFirstEventBlockNumber = (batch: t, ~chainId) => {
  let length = batch->Array.length
  let checkpointIndex = ref(checkpointsStartIndex)
  let result = ref(None)
  while checkpointIndex.contents < length && result.contents === None {
    let checkpointChainId =
      batch
      ->Array.getUnsafe(checkpointIndex.contents + chainIdOffset)
      ->(Utils.magic: unknown => int)
    if checkpointChainId === chainId {
      result :=
        Some(
          batch
          ->Array.getUnsafe(checkpointIndex.contents + blockNumberOffset)
          ->(Utils.magic: unknown => int),
        )
    } else {
      let eventsProcessed =
        batch
        ->Array.getUnsafe(checkpointIndex.contents + eventsProcessedOffset)
        ->(Utils.magic: unknown => int)
      checkpointIndex := checkpointIndex.contents + fixedCheckpointFields + eventsProcessed
    }
  }
  result.contents
}
