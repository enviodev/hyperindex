open Belt

type t = {
  chainFetchers: ChainMap.t<ChainFetcher.t>,
  multichain: InternalConfig.multichain,
  isInReorgThreshold: bool,
}

let calculateTargetBufferSize = (~activeChainsCount, ~config: Config.t) => {
  let targetBatchesInBuffer = 3
  switch Env.targetBufferSize {
  | Some(size) => size
  | None =>
    config.batchSize * (activeChainsCount > targetBatchesInBuffer ? 1 : targetBatchesInBuffer)
  }
}

let makeFromConfig = (~config: Config.t): t => {
  let targetBufferSize = calculateTargetBufferSize(
    ~activeChainsCount=config.chainMap->ChainMap.size,
    ~config,
  )
  let chainFetchers =
    config.chainMap->ChainMap.map(ChainFetcher.makeFromConfig(_, ~config, ~targetBufferSize))
  {
    chainFetchers,
    multichain: config.multichain,
    isInReorgThreshold: false,
  }
}

let makeFromDbState = async (~initialState: Persistence.initialState, ~config: Config.t): t => {
  let isInReorgThreshold = if initialState.cleanRun {
    false
  } else {
    // TODO: Move to Persistence.initialState
    // Since now it's possible not to have rows in the history table
    // even after the indexer started saving history (entered reorg threshold),
    // This rows check might incorrectly return false for recovering the isInReorgThreshold option.
    // But this is not a problem. There's no history anyways, and the indexer will be able to
    // correctly calculate isInReorgThreshold as it starts.
    let hasStartedSavingHistory = await Db.sql->DbFunctions.EntityHistory.hasRows

    //If we have started saving history, continue to save history
    //as regardless of whether we are still in a reorg threshold
    hasStartedSavingHistory
  }

  let targetBufferSize = calculateTargetBufferSize(
    ~activeChainsCount=initialState.chains->Array.length,
    ~config,
  )
  Prometheus.ProcessingMaxBatchSize.set(~maxBatchSize=config.batchSize)
  Prometheus.IndexingTargetBufferSize.set(~targetBufferSize)
  Prometheus.ReorgThreshold.set(~isInReorgThreshold)

  let chainFetchersArr =
    await initialState.chains
    ->Array.map(async (resumedChainState: InternalTable.Chains.t) => {
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
        ),
      )
    })
    ->Promise.all

  let chainFetchers = ChainMap.fromArrayUnsafe(chainFetchersArr)

  {
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

let createBatch = (chainManager: t, ~batchSizeTarget: int): Batch.t => {
  Batch.make(
    ~chainsBeforeBatch=chainManager.chainFetchers->ChainMap.map((cf): Batch.chainBeforeBatch => {
      fetchState: cf.fetchState,
      progressBlockNumber: cf.committedProgressBlockNumber,
      totalEventsProcessed: cf.numEventsProcessed,
      sourceBlockNumber: cf.currentBlockHeight,
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

let getSafeReorgBlocks = (chainManager: t): EntityHistory.safeReorgBlocks => {
  let chainIds = []
  let blockNumbers = []
  chainManager.chainFetchers
  ->ChainMap.values
  ->Array.forEach(cf => {
    chainIds->Js.Array2.push(cf.chainConfig.id)->ignore
    blockNumbers->Js.Array2.push(cf->ChainFetcher.getHighestBlockBelowThreshold)->ignore
  })
  {
    chainIds,
    blockNumbers,
  }
}
