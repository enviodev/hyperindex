open Belt

type t = {
  committedCheckpointId: float,
  chainFetchers: ChainMap.t<ChainFetcher.t>,
  multichain: Config.multichain,
  isInReorgThreshold: bool,
}

// Check if progress is past the reorg threshold (safe block).
// A chain is in reorg threshold when progressBlockNumber > sourceBlockNumber - maxReorgDepth.
// This matches the logic in InternalTable.Checkpoints.makeGetReorgCheckpointsQuery.
let isProgressInReorgThreshold = (~progressBlockNumber, ~sourceBlockNumber, ~maxReorgDepth) => {
  maxReorgDepth > 0 &&
  sourceBlockNumber > 0 &&
  progressBlockNumber > sourceBlockNumber - maxReorgDepth
}

let calculateTargetBufferSize = (~activeChainsCount) => {
  switch Env.targetBufferSize {
  | Some(size) => size
  | None =>
    switch activeChainsCount {
    | 1 => 50_000
    | 2 => 30_000
    | 3 => 20_000
    | 4 => 15_000
    | _ => 10_000
    }
  }
}

let makeFromDbState = async (
  ~initialState: Persistence.initialState,
  ~config: Config.t,
  ~registrations,
): t => {
  let isInReorgThreshold = if initialState.cleanRun {
    false
  } else {
    // Check if any chain is in reorg threshold by comparing progress with sourceBlock - maxReorgDepth.
    initialState.chains->Array.some(chain =>
      isProgressInReorgThreshold(
        ~progressBlockNumber=chain.progressBlockNumber,
        ~sourceBlockNumber=chain.sourceBlockNumber,
        ~maxReorgDepth=chain.maxReorgDepth,
      )
    )
  }

  let targetBufferSize = calculateTargetBufferSize(
    ~activeChainsCount=initialState.chains->Array.length,
  )
  Prometheus.ProcessingMaxBatchSize.set(~maxBatchSize=config.batchSize)
  Prometheus.IndexingTargetBufferSize.set(~targetBufferSize)
  Prometheus.ReorgThreshold.set(~isInReorgThreshold)
  initialState.cache->Utils.Dict.forEach(({effectName, count}) => {
    Prometheus.EffectCacheCount.set(~count, ~effectName)
  })

  let chainFetchersArr =
    await initialState.chains
    ->Array.map(async (resumedChainState: Persistence.initialChainState) => {
      let chain = Config.getChain(config, ~chainId=resumedChainState.id)
      let chainConfig = config.chainMap->ChainMap.get(chain)

      (
        chain,
        await chainConfig->ChainFetcher.makeFromDbState(
          ~resumedChainState,
          ~reorgCheckpoints=initialState.reorgCheckpoints,
          ~isInReorgThreshold,
          ~targetBufferSize,
          ~config,
          ~registrations,
        ),
      )
    })
    ->Promise.all

  let chainFetchers = ChainMap.fromArrayUnsafe(chainFetchersArr)

  {
    committedCheckpointId: initialState.checkpointId,
    multichain: config.multichain,
    chainFetchers,
    isInReorgThreshold,
  }
}

let getChainFetcher = (chainManager: t, ~chain: ChainMap.Chain.t): ChainFetcher.t => {
  chainManager.chainFetchers->ChainMap.get(chain)
}

let setChainFetcher = (chainManager: t, chainFetcher: ChainFetcher.t) => {
  {
    ...chainManager,
    chainFetchers: chainManager.chainFetchers->ChainMap.set(
      ChainMap.Chain.makeUnsafe(~chainId=chainFetcher.chainConfig.id),
      chainFetcher,
    ),
  }
}

let nextItemIsNone = (chainManager: t): bool => {
  !Batch.hasMultichainReadyItem(
    chainManager.chainFetchers->ChainMap.map(cf => {
      cf.fetchState
    }),
    ~multichain=chainManager.multichain,
  )
}

let createBatch = (chainManager: t, ~batchSizeTarget: int, ~isRollback: bool): Batch.t => {
  Batch.make(
    ~checkpointIdBeforeBatch=chainManager.committedCheckpointId +. (
      // Since for rollback we have a diff checkpoint id.
      // This is needed to currectly overwrite old state
      // in an append-only ClickHouse insert.
      isRollback ? 1. : 0.
    ),
    ~chainsBeforeBatch=chainManager.chainFetchers->ChainMap.map((cf): Batch.chainBeforeBatch => {
      fetchState: cf.fetchState,
      progressBlockNumber: cf.committedProgressBlockNumber,
      totalEventsProcessed: cf.numEventsProcessed,
      sourceBlockNumber: cf.fetchState.knownHeight,
      reorgDetection: cf.reorgDetection,
    }),
    ~multichain=chainManager.multichain,
    ~batchSizeTarget,
  )
}

let isProgressAtHead = chainManager =>
  chainManager.chainFetchers
  ->ChainMap.values
  ->Js.Array2.every(cf => cf.isProgressAtHead)

let isActivelyIndexing = chainManager =>
  chainManager.chainFetchers
  ->ChainMap.values
  ->Js.Array2.every(ChainFetcher.isActivelyIndexing)

let getSafeCheckpointId = (chainManager: t) => {
  let chainFetchers = chainManager.chainFetchers->ChainMap.values

  let infinity = (%raw(`Infinity`): float)
  let result = ref(infinity)

  for idx in 0 to chainFetchers->Array.length - 1 {
    let chainFetcher = chainFetchers->Array.getUnsafe(idx)
    switch chainFetcher.safeCheckpointTracking {
    | None => () // Skip chains with maxReorgDepth = 0
    | Some(safeCheckpointTracking) => {
        let safeCheckpointId =
          safeCheckpointTracking->SafeCheckpointTracking.getSafeCheckpointId(
            ~sourceBlockNumber=chainFetcher.fetchState.knownHeight,
          )
        if safeCheckpointId < result.contents {
          result := safeCheckpointId
        }
      }
    }
  }

  if result.contents === infinity || result.contents === 0. {
    None // No safe checkpoint found
  } else {
    Some(result.contents)
  }
}
