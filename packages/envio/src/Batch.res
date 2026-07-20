@@warning("-44")
open Utils.UnsafeIntOperators

type chainAfterBatch = {
  batchSize: int,
  progressBlockNumber: int,
  sourceBlockNumber: int,
  totalEventsProcessed: float,
  fetchState: FetchState.t,
  isProgressAtHeadWhenBatchCreated: bool,
}

// A per-chain snapshot of the scanned block hashes still inside the reorg
// threshold, taken when the batch is assembled. Immutable for the batch's
// lifetime, unlike the live block store it is read from — so checkpoint hashes
// can't shift under a concurrent store mutation. `blockNumbers` is ascending;
// `hashByBlockNumber` is keyed by block number.
type reorgHashSnapshot = {
  blockNumbers: array<int>,
  hashByBlockNumber: dict<string>,
}

type chainBeforeBatch = {
  fetchState: FetchState.t,
  scannedHashes: reorgHashSnapshot,
  shouldRollbackOnReorg: bool,
  progressBlockNumber: int,
  sourceBlockNumber: int,
  totalEventsProcessed: float,
  chainConfig: Config.chain,
}

type t = {
  totalBatchSize: int,
  items: array<Internal.item>,
  progressedChainsById: dict<chainAfterBatch>,
  // Processed inside the reorg threshold. Drives whether history is saved, so
  // writes never merge across a change in this value.
  isInReorgThreshold: bool,
  // Unnest-like checkpoint fields:
  checkpointIds: array<bigint>,
  checkpointChainIds: array<int>,
  checkpointBlockNumbers: array<int>,
  checkpointBlockHashes: array<Null.t<string>>,
  checkpointEventsProcessed: array<int>,
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
            totalEventsProcessed: chainBeforeBatch.totalEventsProcessed +. batchSize->Int.toFloat,
            fetchState: fetchStateAfterBatch,
            isProgressAtHeadWhenBatchCreated: progressBlockNumberAfterBatch >=
            chainBeforeBatch.sourceBlockNumber - chainBeforeBatch.chainConfig.blockLag,
          }: chainAfterBatch
        ),
      )
    } else {
      None
    }
  }

  (
    ~chainsBeforeBatch: dict<chainBeforeBatch>,
    ~batchSizePerChain: dict<int>,
    ~progressBlockNumberPerChain: dict<int>,
  ) => {
    let progressedChainsById = Dict.make()

    // Needed to:
    // - Recalculate the computed queue sizes
    // - Accumulate registered dynamic contracts to store in the db
    // - Trigger onBlock pointer update
    chainsBeforeBatch
    ->Dict.valuesToArray
    ->Array.forEach(chainBeforeBatch => {
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
        let leftItems = fetchState.buffer->Array.slice(~start=batchSize)
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
  ~scannedHashes: reorgHashSnapshot,
  ~shouldRollbackOnReorg,
  ~fromBlockExclusive,
  ~toBlockExclusive,
  ~chainId,
  ~mutCheckpointIds,
  ~mutCheckpointChainIds,
  ~mutCheckpointBlockNumbers,
  ~mutCheckpointBlockHashes,
  ~mutCheckpointEventsProcessed,
) => {
  if shouldRollbackOnReorg {
    let prevCheckpointId = ref(prevCheckpointId)
    // The snapshot already holds only in-threshold scanned hashes, ascending,
    // so a straight range filter over it gives the gap checkpoints without
    // re-reading the store per block.
    let blockNumbers = scannedHashes.blockNumbers
    for idx in 0 to blockNumbers->Array.length - 1 {
      let blockNumber = blockNumbers->Array.getUnsafe(idx)
      if blockNumber > fromBlockExclusive && blockNumber < toBlockExclusive {
        let hash =
          scannedHashes.hashByBlockNumber
          ->Utils.Dict.dangerouslyGetByIntNonOption(blockNumber)
          ->Option.getUnsafe
        let checkpointId = prevCheckpointId.contents->BigInt.add(1n)
        prevCheckpointId := checkpointId

        mutCheckpointIds->Array.push(checkpointId)
        mutCheckpointChainIds->Array.push(chainId)
        mutCheckpointBlockNumbers->Array.push(blockNumber)
        mutCheckpointBlockHashes->Array.push(Null.Value(hash))
        mutCheckpointEventsProcessed->Array.push(0)
      }
    }
    prevCheckpointId.contents
  } else {
    prevCheckpointId
  }
}

let prepareBatch = (
  ~checkpointIdBeforeBatch,
  ~chainsBeforeBatch: dict<chainBeforeBatch>,
  ~batchSizeTarget,
  ~isInReorgThreshold,
) => {
  let preparedFetchStates =
    chainsBeforeBatch
    ->Dict.valuesToArray
    ->Array.map(chainBeforeBatch => chainBeforeBatch.fetchState)
    ->FetchState.sortForBatch(~batchSizeTarget)

  let chainIdx = ref(0)
  let preparedNumber = preparedFetchStates->Array.length
  let totalBatchSize = ref(0)

  let prevCheckpointId = ref(checkpointIdBeforeBatch)
  let mutBatchSizePerChain = Dict.make()
  let mutProgressBlockNumberPerChain = Dict.make()

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
    let fetchState = preparedFetchStates->Array.getUnsafe(chainIdx.contents)
    let chainBatchSize =
      fetchState->FetchState.getReadyItemsCount(
        ~targetSize=batchSizeTarget - totalBatchSize.contents,
        ~fromItem=0,
      )
    let chainBeforeBatch =
      chainsBeforeBatch
      ->Utils.Dict.dangerouslyGetByIntNonOption(fetchState.chainId)
      ->Option.getUnsafe

    let prevBlockNumber = ref(chainBeforeBatch.progressBlockNumber)
    if chainBatchSize > 0 {
      for idx in 0 to chainBatchSize - 1 {
        let item = fetchState.buffer->Array.getUnsafe(idx)
        let blockNumber = item->Internal.getItemBlockNumber

        // Every new block we should create a new checkpoint
        if blockNumber !== prevBlockNumber.contents {
          prevCheckpointId :=
            addReorgCheckpoints(
              ~chainId=fetchState.chainId,
              ~scannedHashes=chainBeforeBatch.scannedHashes,
              ~shouldRollbackOnReorg=chainBeforeBatch.shouldRollbackOnReorg,
              ~prevCheckpointId=prevCheckpointId.contents,
              ~fromBlockExclusive=prevBlockNumber.contents,
              ~toBlockExclusive=blockNumber,
              ~mutCheckpointIds=checkpointIds,
              ~mutCheckpointChainIds=checkpointChainIds,
              ~mutCheckpointBlockNumbers=checkpointBlockNumbers,
              ~mutCheckpointBlockHashes=checkpointBlockHashes,
              ~mutCheckpointEventsProcessed=checkpointEventsProcessed,
            )

          let checkpointId = prevCheckpointId.contents->BigInt.add(1n)

          checkpointIds->Array.push(checkpointId)->ignore
          checkpointChainIds->Array.push(fetchState.chainId)->ignore
          checkpointBlockNumbers->Array.push(blockNumber)->ignore
          checkpointBlockHashes
          ->Array.push(
            switch chainBeforeBatch.scannedHashes.hashByBlockNumber->Utils.Dict.dangerouslyGetByIntNonOption(
              blockNumber,
            ) {
            | Some(hash) => Null.Value(hash)
            | None => Null.Null
            },
          )
          ->ignore
          checkpointEventsProcessed->Array.push(1)->ignore

          prevBlockNumber := blockNumber
          prevCheckpointId := checkpointId
        } else {
          let lastIndex = checkpointEventsProcessed->Array.length - 1
          checkpointEventsProcessed
          ->Array.setUnsafe(lastIndex, checkpointEventsProcessed->Array.getUnsafe(lastIndex) + 1)
          ->ignore
        }

        items->Array.push(item)->ignore
      }

      totalBatchSize := totalBatchSize.contents + chainBatchSize
      mutBatchSizePerChain->Utils.Dict.setByInt(fetchState.chainId, chainBatchSize)
    }

    let progressBlockNumberAfterBatch =
      fetchState->FetchState.getProgressBlockNumberAt(~index=chainBatchSize)

    prevCheckpointId :=
      addReorgCheckpoints(
        ~chainId=fetchState.chainId,
        ~scannedHashes=chainBeforeBatch.scannedHashes,
        ~shouldRollbackOnReorg=chainBeforeBatch.shouldRollbackOnReorg,
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
    isInReorgThreshold,
    checkpointIds,
    checkpointChainIds,
    checkpointBlockNumbers,
    checkpointBlockHashes,
    checkpointEventsProcessed,
  }
}

let make = (
  ~checkpointIdBeforeBatch,
  ~chainsBeforeBatch: dict<chainBeforeBatch>,
  ~batchSizeTarget,
  ~isInReorgThreshold,
) => {
  prepareBatch(~checkpointIdBeforeBatch, ~chainsBeforeBatch, ~batchSizeTarget, ~isInReorgThreshold)
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
