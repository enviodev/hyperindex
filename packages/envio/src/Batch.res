@@warning("-44")
open Utils.UnsafeIntOperators

type chainAfterBatch = {
  chainId: ChainId.t,
  batchSize: int,
  progressBlockNumber: int,
  // Timestamp of `progressBlockNumber` itself, never of a lower block, so it
  // measures how far behind chain time the committed progress is. `None` when
  // the source didn't return that block's header - during backfill it only
  // returns blocks carrying items, and an SVM slot may have produced no block
  // at all.
  progressBlockTime: option<int>,
  sourceBlockNumber: int,
  totalEventsProcessed: float,
  isProgressAtHeadWhenBatchCreated: bool,
}

// A per-chain snapshot of the scanned block hashes still inside the reorg
// threshold, taken when the batch is assembled. Immutable for the batch's
// lifetime, unlike the chain buffer it is read from - so checkpoint hashes
// can't shift under a concurrent merge. `blockNumbers` is ascending;
// `hashByBlockNumber` is keyed by block number.
type reorgHashSnapshot = {
  blockNumbers: array<int>,
  hashByBlockNumber: dict<string>,
}

type chainBeforeBatch = {
  fetchState: FetchState.t,
  // The chain's own buffer, which the batch builds its items from.
  buffer: ChainBuffer.t,
  // Builds the chain's items of `[fromBlock, maxBlock]`, up to about
  // `targetItems`, with the last block they cover.
  buildItems: (
    ~fromBlock: int,
    ~maxBlock: int,
    ~targetItems: int,
  ) => promise<(array<Internal.item>, option<int>)>,
  // Adds the time spent waiting for the chain's items to its metric.
  recordParse: float => unit,
  scannedHashes: reorgHashSnapshot,
  // The progress block isn't known until the build computes it, so its
  // timestamp can't be snapshotted with the rest. Reads the chain's buffer,
  // which keeps the block until the batch commits.
  blockTimeAt: int => option<int>,
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
  // Items the checkpoint carries, which is what indexes `items`.
  checkpointItemsCount: array<int>,
  // Logs the checkpoint carries: one log matched to several registrations is one
  // event, however many items it made.
  checkpointEventsProcessed: array<int>,
  registeredAddresses: array<AddressRows.staged>,
}

// What a chain contributed to the batch: items built from its buffer, and the
// logs behind them.
type chainBatchCounts = {size: int, eventsProcessed: int}

let getProgressedChainsById = {
  let getChainAfterBatchIfProgressed = (
    ~chainBeforeBatch: chainBeforeBatch,
    ~progressBlockNumberAfterBatch,
    ~counts: chainBatchCounts,
  ) => {
    // The check is sufficient, since we guarantee to include a full block in a batch
    // Also, this might be true even if batchSize is 0,
    // eg when indexing at the head and chain doesn't have items in a block
    if chainBeforeBatch.progressBlockNumber < progressBlockNumberAfterBatch {
      Some(
        (
          {
            chainId: chainBeforeBatch.fetchState.chainId,
            batchSize: counts.size,
            progressBlockNumber: progressBlockNumberAfterBatch,
            progressBlockTime: chainBeforeBatch.blockTimeAt(progressBlockNumberAfterBatch),
            sourceBlockNumber: chainBeforeBatch.sourceBlockNumber,
            totalEventsProcessed: chainBeforeBatch.totalEventsProcessed +.
            counts.eventsProcessed->Int.toFloat,
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

      switch getChainAfterBatchIfProgressed(
        ~chainBeforeBatch,
        ~counts=countsPerChain
        ->Utils.Dict.dangerouslyGetNonOption(fetchState.chainId->ChainId.toString)
        ->Option.getOr({size: 0, eventsProcessed: 0}),
        ~progressBlockNumberAfterBatch,
      ) {
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
  ~mutCheckpointItemsCount,
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
      mutCheckpointItemsCount->Array.push(0)
      mutCheckpointEventsProcessed->Array.push(0)

      idx := idx.contents + 1
    }
  }
}

// Within a chain, ids ascend with block order, and rollback preserves that by
// deleting the chain's ids above its target before any higher one is allocated.
// Every rollback deletes by `id > target`, which is only the stale suffix while
// ids and blocks agree on order within each chain.
let make = async (
  ~sequence: CheckpointSequence.t,
  ~frontier: Frontier.t,
  ~chainsBeforeBatch: dict<chainBeforeBatch>,
  ~batchSizeTarget,
  ~history,
) => {
  let preparedChains =
    chainsBeforeBatch
    ->Dict.valuesToArray
    ->FetchState.sortForBatch(
      ~fetchStateOf=chain => chain.fetchState,
      ~bufferOf=chain => chain.buffer,
      ~processingBlockNumberOf=chain => chain.progressBlockNumber,
      ~batchSizeTarget,
    )

  let chainIdx = ref(0)
  let preparedNumber = preparedChains->Array.length
  let totalBatchSize = ref(0)

  let cursor = sequence->CheckpointSequence.cursor(~frontier)
  let mutCountsPerChain = Dict.make()
  let mutProgressBlockNumberPerChain = Dict.make()

  let items = []
  let checkpointIds = []
  let checkpointChainIds = []
  let checkpointBlockNumbers = []
  let checkpointBlockHashes = []
  let checkpointItemsCount = []
  let checkpointEventsProcessed = []

  // Chain by chain, each built for what is left of the target, so the loaders
  // see as many items of one chain together as possible.
  while totalBatchSize.contents < batchSizeTarget && chainIdx.contents < preparedNumber {
    let chainBeforeBatch = preparedChains->Array.getUnsafe(chainIdx.contents)
    let {fetchState, buffer} = chainBeforeBatch
    let fromBlock = chainBeforeBatch.progressBlockNumber + 1
    let maxBlock = fetchState->FetchState.bufferBlockNumber

    let (chainItems, progressBlockNumberAfterBatch) = if maxBlock < fromBlock {
      ([], chainBeforeBatch.progressBlockNumber)
    } else if buffer->ChainBuffer.countItemsInBlockRange(~fromBlock, ~toBlock=maxBlock) === 0 {
      // Nothing to build: the whole ready range is processed as it stands.
      ([], maxBlock)
    } else {
      let startedAt = Performance.now()
      let (chainItems, lastBlock) = await chainBeforeBatch.buildItems(
        ~fromBlock,
        ~maxBlock,
        ~targetItems=batchSizeTarget - totalBatchSize.contents,
      )
      chainBeforeBatch.recordParse(Performance.now() -. startedAt)
      (chainItems, lastBlock->Option.getOr(maxBlock))
    }
    let chainBatchSize = chainItems->Array.length

    let prevBlockNumber = ref(chainBeforeBatch.progressBlockNumber)
    let chainEventsProcessed = ref(0)
    if chainBatchSize > 0 {
      for idx in 0 to chainBatchSize - 1 {
        let item = chainItems->Array.getUnsafe(idx)
        let blockNumber = item->Internal.getItemBlockNumber
        // Items are built in order, so a log's items are consecutive: the first
        // of them is the only one that counts as an event.
        let isNewEvent =
          idx === 0 || !(chainItems->Array.getUnsafe(idx - 1)->FetchState.isSameLog(item))
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
            ~mutCheckpointItemsCount=checkpointItemsCount,
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
          checkpointItemsCount->Array.push(1)->ignore
          checkpointEventsProcessed->Array.push(1)->ignore

          prevBlockNumber := blockNumber
        } else {
          let lastIndex = checkpointItemsCount->Array.length - 1
          checkpointItemsCount
          ->Array.setUnsafe(lastIndex, checkpointItemsCount->Array.getUnsafe(lastIndex) + 1)
          ->ignore
          if isNewEvent {
            checkpointEventsProcessed
            ->Array.setUnsafe(lastIndex, checkpointEventsProcessed->Array.getUnsafe(lastIndex) + 1)
            ->ignore
          }
        }

        items->Array.push(item)->ignore
      }

      totalBatchSize := totalBatchSize.contents + chainBatchSize
      mutCountsPerChain->ChainId.Dict.set(
        fetchState.chainId,
        {size: chainBatchSize, eventsProcessed: chainEventsProcessed.contents},
      )
    }

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
      ~mutCheckpointItemsCount=checkpointItemsCount,
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
    checkpointItemsCount,
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

let findFirstEventBlockNumber = (batch: t, ~chainId) => {
  let idx = ref(0)
  let result = ref(None)
  let checkpointsLength = batch.checkpointIds->Array.length
  while idx.contents < checkpointsLength && result.contents === None {
    let checkpointChainId = batch.checkpointChainIds->Array.getUnsafe(idx.contents)
    if (
      checkpointChainId === chainId && batch.checkpointItemsCount->Array.getUnsafe(idx.contents) > 0
    ) {
      result := Some(batch.checkpointBlockNumbers->Array.getUnsafe(idx.contents))
    } else {
      idx := idx.contents + 1
    }
  }
  result.contents
}

// The block of the chain's last item that carries one in the batch: an
// event's or a transaction handler's.
let findLastItemBlock = (batch: t, ~chainId) => {
  let idx = ref(batch.items->Array.length - 1)
  let result = ref(None)
  while idx.contents >= 0 && result.contents === None {
    let item = batch.items->Array.getUnsafe(idx.contents)
    if item->Internal.getItemChainId === chainId {
      switch item {
      | Internal.Event({payload}) =>
        result := Some(payload->Internal.getPayloadBlock->Nullable.toOption)
      | Internal.Transaction({?transaction}) =>
        result :=
          Some(
            transaction->Option.flatMap(transaction =>
              transaction->Internal.getTransactionBlock->Nullable.toOption
            ),
          )
      | Internal.Block(_) => ()
      }
    }
    idx := idx.contents - 1
  }
  result.contents->Option.flatMap(block => block)
}
