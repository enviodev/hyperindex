open Belt

type t = {
  chainFetchers: ChainMap.t<ChainFetcher.t>,
  isUnorderedMultichainMode: bool,
  isInReorgThreshold: bool,
}

let makeFromConfig = (~config: Config.t): t => {
  let chainFetchers = config.chainMap->ChainMap.map(ChainFetcher.makeFromConfig(_, ~config))
  {
    chainFetchers,
    isUnorderedMultichainMode: config.isUnorderedMultichainMode,
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

  let chainFetchersArr =
    await initialState.chains
    ->Array.map(async (initialChainState: InternalTable.Chains.t) => {
      let chain = Config.getChain(config, ~chainId=initialChainState.id)
      let chainConfig = config.chainMap->ChainMap.get(chain)
      (
        chain,
        await chainConfig->ChainFetcher.makeFromDbState(
          ~initialChainState,
          ~isInReorgThreshold,
          ~config,
        ),
      )
    })
    ->Promise.all

  let chainFetchers = ChainMap.fromArrayUnsafe(chainFetchersArr)

  {
    isUnorderedMultichainMode: config.isUnorderedMultichainMode,
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

let getFetchStateWithData = (chainManager: t, ~shouldDeepCopy=false): ChainMap.t<FetchState.t> => {
  chainManager.chainFetchers->ChainMap.map(cf => {
    shouldDeepCopy ? cf.fetchState->FetchState.copy : cf.fetchState
  })
}

/**
Simply calls getOrderedNextItem in isolation using the chain manager without
the context of a batch
*/
let nextItemIsNone = (chainManager: t): bool => {
  chainManager->getFetchStateWithData->Batch.getOrderedNextItem === None
}

let createBatch = (chainManager: t, ~maxBatchSize: int): Batch.t => {
  let refTime = Hrtime.makeTimer()

  //Make a copy of the queues and fetch states since we are going to mutate them
  let fetchStates = chainManager->getFetchStateWithData(~shouldDeepCopy=true)

  let sizePerChain = Js.Dict.empty()
  let items = if chainManager.isUnorderedMultichainMode || fetchStates->ChainMap.size === 1 {
    Batch.popUnorderedBatchItems(~maxBatchSize, ~fetchStates, ~sizePerChain)
  } else {
    Batch.popOrderedBatchItems(~maxBatchSize, ~fetchStates, ~sizePerChain)
  }

  let dcsToStoreByChainId = Js.Dict.empty()
  // Needed to recalculate the computed queue sizes
  let fetchStates = fetchStates->ChainMap.map(fetchState => {
    switch fetchState.dcsToStore {
    | Some(dcs) => dcsToStoreByChainId->Js.Dict.set(fetchState.chainId->Int.toString, dcs)
    | None => ()
    }
    fetchState->FetchState.updateInternal(~dcsToStore=None)
  })

  let progressedChains = []
  chainManager.chainFetchers
  ->ChainMap.entries
  ->Array.forEach(((chain, chainFetcher)) => {
    let updatedFetchState = fetchStates->ChainMap.get(chain)
    let nextProgressBlockNumber = updatedFetchState->FetchState.getProgressBlockNumber
    let maybeItemsCountInBatch =
      sizePerChain->Utils.Dict.dangerouslyGetNonOption(
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
            progressNextBlockLogIndex: updatedFetchState->FetchState.getProgressNextBlockLogIndex,
            totalEventsProcessed: chainFetcher.numEventsProcessed + chainBatchSize,
          }: Batch.progressedChain
        ),
      )
      ->ignore
    }
  })

  let batchSize = items->Array.length
  if batchSize > 0 {
    let fetchedEventsBuffer =
      fetchStates
      ->ChainMap.entries
      ->Array.map(((chain, fetchState)) => (
        chain->ChainMap.Chain.toString,
        fetchState->FetchState.bufferSize,
      ))
      ->Js.Dict.fromArray

    let timeElapsed = refTime->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    Logging.trace({
      "msg": "New batch created for processing",
      "batchSize": batchSize,
      "buffers": fetchedEventsBuffer,
      "time taken (ms)": timeElapsed,
    })

    if Env.Benchmark.shouldSaveData {
      let group = "Other"
      Benchmark.addSummaryData(
        ~group,
        ~label=`Batch Creation Time (ms)`,
        ~value=timeElapsed->Belt.Int.toFloat,
      )
      Benchmark.addSummaryData(~group, ~label=`Batch Size`, ~value=batchSize->Belt.Int.toFloat)
    }
  }

  {
    items,
    progressedChains,
    fetchStates,
    dcsToStoreByChainId,
  }
}

let isFetchingAtHead = chainManager =>
  chainManager.chainFetchers
  ->ChainMap.values
  ->Js.Array2.every(ChainFetcher.isFetchingAtHead)

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
