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
// lifetime, unlike the live block store it is read from - so checkpoint hashes
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
  // Whether the batch's rows get history. Writes never merge across a change in
  // it, so a single write can't mix the two.
  history: HistoryPolicy.t,
  // Unnest-like checkpoint fields:
  checkpointIds: array<bigint>,
  checkpointChainIds: array<ChainId.t>,
  checkpointBlockNumbers: array<int>,
  checkpointBlockHashes: array<Null.t<string>>,
  // Logs the checkpoint carries: one log routed to several registrations is one
  // event, however many items it made.
  checkpointEventsProcessed: array<int>,
  registeredAddresses: array<AddressRows.staged>,
}

// What a chain contributed to the batch: items taken off its buffer, and the
// logs behind them.
type chainBatchCounts = {size: int, eventsProcessed: int}

let getProgressedChainsById = {
  let getChainAfterBatchIfProgressed = (
    ~chainBeforeBatch: chainBeforeBatch,
    ~progressBlockNumberAfterBatch,
    ~fetchStateAfterBatch,
    ~counts: chainBatchCounts,
  ) => {
    // The check is sufficient, since we guarantee to include a full block in a batch
    // Also, this might be true even if batchSize is 0,
    // eg when indexing at the head and chain doesn't have items in a block
    if chainBeforeBatch.progressBlockNumber < progressBlockNumberAfterBatch {
      Some(
        (
          {
            batchSize: counts.size,
            progressBlockNumber: progressBlockNumberAfterBatch,
            sourceBlockNumber: chainBeforeBatch.sourceBlockNumber,
            totalEventsProcessed: chainBeforeBatch.totalEventsProcessed +.
            counts.eventsProcessed->Int.toFloat,
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
    ~countsPerChain: dict<chainBatchCounts>,
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
        fetchState.chainId->ChainId.toString,
      ) {
      | Some(progressBlockNumber) => progressBlockNumber
      | None => chainBeforeBatch.progressBlockNumber
      }

      switch switch countsPerChain->Utils.Dict.dangerouslyGetNonOption(
        fetchState.chainId->ChainId.toString,
      ) {
      | Some(counts) =>
        let leftItems = fetchState.buffer->Array.slice(~start=counts.size)
        getChainAfterBatchIfProgressed(
          ~chainBeforeBatch,
          ~counts,
          ~fetchStateAfterBatch=fetchState->FetchState.updateInternal(~mutItems=leftItems),
          ~progressBlockNumberAfterBatch,
        )
      // Skip not affected chains
      | None =>
        getChainAfterBatchIfProgressed(
          ~chainBeforeBatch,
          ~counts={size: 0, eventsProcessed: 0},
          ~fetchStateAfterBatch=chainBeforeBatch.fetchState,
          ~progressBlockNumberAfterBatch,
        )
      } {
      | Some(progressedChain) =>
        progressedChainsById->ChainId.Dict.set(chainBeforeBatch.fetchState.chainId, progressedChain)
      | None => ()
      }
    })

    progressedChainsById
  }
}

// Index of the first entry of an ascending array strictly above `blockNumber`,
// or the array length when there is none.
let seekFirstAbove = (blockNumbers: array<int>, blockNumber) => {
  let low = ref(0)
  let high = ref(blockNumbers->Array.length)
  while low.contents < high.contents {
    let mid = (low.contents + high.contents) / 2
    if blockNumbers->Array.getUnsafe(mid) > blockNumber {
      high := mid
    } else {
      low := mid + 1
    }
  }
  low.contents
}

@inline
let addReorgCheckpoints = (
  ~cursor,
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
    // The snapshot already holds only in-threshold scanned hashes, ascending,
    // so seeking to the gap's lower bound gives the gap checkpoints without
    // rescanning the whole snapshot for every gap in the batch.
    let blockNumbers = scannedHashes.blockNumbers
    let length = blockNumbers->Array.length
    let idx = ref(blockNumbers->seekFirstAbove(fromBlockExclusive))
    while idx.contents < length && blockNumbers->Array.getUnsafe(idx.contents) < toBlockExclusive {
      let blockNumber = blockNumbers->Array.getUnsafe(idx.contents)
      let hash =
        scannedHashes.hashByBlockNumber
        ->Utils.Dict.dangerouslyGetByIntNonOption(blockNumber)
        ->Option.getUnsafe
      let checkpointId = cursor->CheckpointSequence.next(~chainId)

      mutCheckpointIds->Array.push(checkpointId)
      mutCheckpointChainIds->Array.push(chainId)
      mutCheckpointBlockNumbers->Array.push(blockNumber)
      mutCheckpointBlockHashes->Array.push(Null.Value(hash))
      mutCheckpointEventsProcessed->Array.push(0)

      idx := idx.contents + 1
    }
  }
}

// Within a chain, ids ascend with block order, and rollback preserves that by
// deleting the chain's ids above its target before any higher one is allocated.
// Every rollback deletes by `id > target`, which is only the stale suffix while
// ids and blocks agree on order within each chain.
let make = (
  ~sequence: CheckpointSequence.t,
  ~frontier: Frontier.t,
  ~chainsBeforeBatch: dict<chainBeforeBatch>,
  ~batchSizeTarget,
  ~history,
) => {
  let preparedFetchStates =
    chainsBeforeBatch
    ->Dict.valuesToArray
    ->Array.map(chainBeforeBatch => chainBeforeBatch.fetchState)
    ->FetchState.sortForBatch(~batchSizeTarget)

  let chainIdx = ref(0)
  let preparedNumber = preparedFetchStates->Array.length
  let totalBatchSize = ref(0)

  let cursor = sequence->CheckpointSequence.cursor(~frontier)
  let mutCountsPerChain = Dict.make()
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
      ->ChainId.Dict.dangerouslyGetNonOption(fetchState.chainId)
      ->Option.getUnsafe

    let prevBlockNumber = ref(chainBeforeBatch.progressBlockNumber)
    let chainEventsProcessed = ref(0)
    if chainBatchSize > 0 {
      for idx in 0 to chainBatchSize - 1 {
        let item = fetchState.buffer->Array.getUnsafe(idx)
        let blockNumber = item->Internal.getItemBlockNumber
        // The buffer is sorted, so a log's items are consecutive: the first of
        // them is the only one that counts as an event.
        let isNewEvent =
          idx === 0 || !(fetchState.buffer->Array.getUnsafe(idx - 1)->FetchState.isSameLog(item))
        if isNewEvent {
          chainEventsProcessed := chainEventsProcessed.contents + 1
        }

        // Every new block we should create a new checkpoint
        if blockNumber !== prevBlockNumber.contents {
          addReorgCheckpoints(
            ~chainId=fetchState.chainId,
            ~scannedHashes=chainBeforeBatch.scannedHashes,
            ~shouldRollbackOnReorg=chainBeforeBatch.shouldRollbackOnReorg,
            ~cursor,
            ~fromBlockExclusive=prevBlockNumber.contents,
            ~toBlockExclusive=blockNumber,
            ~mutCheckpointIds=checkpointIds,
            ~mutCheckpointChainIds=checkpointChainIds,
            ~mutCheckpointBlockNumbers=checkpointBlockNumbers,
            ~mutCheckpointBlockHashes=checkpointBlockHashes,
            ~mutCheckpointEventsProcessed=checkpointEventsProcessed,
          )

          let checkpointId = cursor->CheckpointSequence.next(~chainId=fetchState.chainId)

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
        } else if isNewEvent {
          let lastIndex = checkpointEventsProcessed->Array.length - 1
          checkpointEventsProcessed
          ->Array.setUnsafe(lastIndex, checkpointEventsProcessed->Array.getUnsafe(lastIndex) + 1)
          ->ignore
        }

        items->Array.push(item)->ignore
      }

      totalBatchSize := totalBatchSize.contents + chainBatchSize
      mutCountsPerChain->ChainId.Dict.set(
        fetchState.chainId,
        {size: chainBatchSize, eventsProcessed: chainEventsProcessed.contents},
      )
    }

    let progressBlockNumberAfterBatch =
      fetchState->FetchState.getProgressBlockNumberAt(~index=chainBatchSize)

    addReorgCheckpoints(
      ~chainId=fetchState.chainId,
      ~scannedHashes=chainBeforeBatch.scannedHashes,
      ~shouldRollbackOnReorg=chainBeforeBatch.shouldRollbackOnReorg,
      ~cursor,
      ~fromBlockExclusive=prevBlockNumber.contents,
      ~toBlockExclusive=progressBlockNumberAfterBatch + 1, // Make it inclusive
      ~mutCheckpointIds=checkpointIds,
      ~mutCheckpointChainIds=checkpointChainIds,
      ~mutCheckpointBlockNumbers=checkpointBlockNumbers,
      ~mutCheckpointBlockHashes=checkpointBlockHashes,
      ~mutCheckpointEventsProcessed=checkpointEventsProcessed,
    )

    mutProgressBlockNumberPerChain->ChainId.Dict.set(
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
      ~countsPerChain=mutCountsPerChain,
      ~progressBlockNumberPerChain=mutProgressBlockNumberPerChain,
    ),
    history,
    checkpointIds,
    checkpointChainIds,
    checkpointBlockNumbers,
    checkpointBlockHashes,
    checkpointEventsProcessed,
    registeredAddresses: [],
  }
}

// Where the batch leaves each chain it handed ids to. Ids ascend within a
// chain, so the last one seen per chain is its highest.
let checkpointFrontier = (batch: t): Frontier.t => {
  let frontier = Frontier.empty()
  batch.checkpointChainIds->Array.forEachWithIndex((chainId, index) =>
    frontier->Frontier.set(chainId, batch.checkpointIds->Array.getUnsafe(index))
  )
  frontier
}

// Exclusive end of the items belonging to the checkpoint at `checkpointIdx`,
// starting from `fromItemIdx`. A checkpoint is one chain's one block, and a
// batch takes whole blocks in order, so a checkpoint's items are the run at the
// dispatch cursor that still carries its chain and block - a reorg-only
// checkpoint's run is empty.
let checkpointItemsEnd = (batch: t, ~checkpointIdx, ~fromItemIdx) => {
  let chainId = batch.checkpointChainIds->Array.getUnsafe(checkpointIdx)
  let blockNumber = batch.checkpointBlockNumbers->Array.getUnsafe(checkpointIdx)
  let itemsLength = batch.items->Array.length
  let idx = ref(fromItemIdx)
  let isFinished = ref(false)
  while !isFinished.contents && idx.contents < itemsLength {
    let item = batch.items->Array.getUnsafe(idx.contents)
    if (
      item->Internal.getItemBlockNumber === blockNumber && item->Internal.getItemChainId === chainId
    ) {
      idx := idx.contents + 1
    } else {
      isFinished := true
    }
  }
  idx.contents
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
        if eventItem.chainId === chainId {
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
