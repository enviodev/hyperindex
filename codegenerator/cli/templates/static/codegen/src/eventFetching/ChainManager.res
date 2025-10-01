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

let getFetchStates = (chainManager: t): ChainMap.t<FetchState.t> => {
  chainManager.chainFetchers->ChainMap.map(cf => {
    cf.fetchState
  })
}

let nextItemIsNone = (chainManager: t): bool => {
  !Batch.hasMultichainReadyItem(chainManager->getFetchStates, ~multichain=chainManager.multichain)
}

let createBatch = (chainManager: t, ~batchSizeTarget: int): Batch.t => {
  let refTime = Hrtime.makeTimer()
  let fetchStates = chainManager->getFetchStates

  let mutBatchSizePerChain = Js.Dict.empty()
  let items = if (
    switch chainManager.multichain {
    | Unordered => true
    | Ordered => fetchStates->ChainMap.size === 1
    }
  ) {
    Batch.prepareUnorderedBatch(~batchSizeTarget, ~fetchStates, ~mutBatchSizePerChain)
  } else {
    Batch.prepareOrderedBatch(~batchSizeTarget, ~fetchStates, ~mutBatchSizePerChain)
  }
  let batchSizePerChain = mutBatchSizePerChain

  let dcsToStoreByChainId = Js.Dict.empty()
  // Needed to:
  // - Recalculate the computed queue sizes
  // - Accumulate registered dynamic contracts to store in the db
  // - Trigger onBlock pointer update
  let updatedFetchStates = fetchStates->ChainMap.map(fetchState => {
    switch batchSizePerChain->Utils.Dict.dangerouslyGetNonOption(fetchState.chainId->Int.toString) {
    | Some(batchSize) =>
      let leftItems = fetchState.buffer->Js.Array2.sliceFrom(batchSize)
      switch fetchState.dcsToStore {
      | [] => fetchState->FetchState.updateInternal(~mutItems=leftItems)
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

          dcsToStoreByChainId->Js.Dict.set(fetchState.chainId->Int.toString, batchDcs)
          updatedFetchState
        }
      }
    // Skip not affected chains
    | None => fetchState
    }
  })

  let progressedChains = []
  chainManager.chainFetchers
  ->ChainMap.entries
  ->Array.forEach(((chain, chainFetcher)) => {
    let updatedFetchState = updatedFetchStates->ChainMap.get(chain)
    let nextProgressBlockNumber = updatedFetchState->FetchState.getProgressBlockNumber
    let maybeItemsCountInBatch =
      batchSizePerChain->Utils.Dict.dangerouslyGetNonOption(
        chain->ChainMap.Chain.toChainId->Int.toString,
      )
    if (
      chainFetcher.committedProgressBlockNumber < nextProgressBlockNumber ||
        // It should never be 0
        maybeItemsCountInBatch->Option.isSome
    ) {
      let chainBatchSize = maybeItemsCountInBatch->Option.getWithDefault(0)
      progressedChains
      ->Js.Array2.push(
        (
          {
            chainId: chain->ChainMap.Chain.toChainId,
            batchSize: chainBatchSize,
            progressBlockNumber: nextProgressBlockNumber,
            totalEventsProcessed: chainFetcher.numEventsProcessed + chainBatchSize,
            // Snapshot the value at the moment of batch creation
            // so we don't have a case where we can't catch up the head because of the
            // defference between processing and new blocks
            isProgressAtHead: nextProgressBlockNumber >= chainFetcher.currentBlockHeight,
          }: Batch.progressedChain
        ),
      )
      ->ignore
    }
  })

  {
    items,
    progressedChains,
    updatedFetchStates,
    dcsToStoreByChainId,
    creationTimeMs: refTime->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis,
  }
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
