open Belt
type t = {chainManager: ChainManager.t}
type action = HyperSyncBlockRangeResponse(ChainMap.Chain.t, HyperSyncWorker.blockRangeFetchResponse)
type task = HyperSyncBlockRangeQuery

let actionReducer = (state: t, action: action) => {
  switch action {
  | HyperSyncBlockRangeResponse(chain, response) =>
    let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
    let {
      parsedQueueItems,
      heighestQueriedBlockNumber,
      stats,
      nextQuery,
      currentBlockHeight,
      reorgGuard,
      fromBlockQueried,
    } = response

    chainFetcher.logger->Logging.childTrace({
      "message": "Finished page range",
      "fromBlock": fromBlockQueried,
      "toBlock": heighestQueriedBlockNumber,
      "number of logs": parsedQueueItems->Array.length,
      "stats": stats,
    })

    //TODO: Check reorg has occurred  here and action reorg if need be
    let {parentHash, lastBlockScannedData} = reorgGuard

    // lastBlockScannedData->checkHasReorgOccurred(~parentHash, ~currentHeight=currentBlockHeight)

    if chainFetcher.pendingDynamicContractRegistrations->Set.String.isEmpty {
      let queueIsFull = parsedQueueItems->Array.reduce(false, (accum, item) => {
        let isFull = chainFetcher.fetchedEventQueue->ChainEventQueue.pushItem(item)
        isFull || accum
      })

      let pendingNextQuery = if queueIsFull {
        Some(ChainFetcher.HypersyncPendingNextQuery(nextQuery))
      } else {
        None
      }

      let updatedChainFetcher = {
        ...chainFetcher,
        pendingNextQuery,
        currentBlockHeight,
      }

      let updatedFetchers =
        state.chainManager.chainFetchers->ChainMap.set(chain, updatedChainFetcher)

      let nextTasks = if !queueIsFull {
        //If the queue is not full dispatch the next query
        //Othe this will be dispatch when the queue has space
        [HyperSyncBlockRangeQuery]
      } else {
        []
      }

      let nextState = {chainManager: {...state.chainManager, chainFetchers: updatedFetchers}}
      (nextState, nextTasks)
    } else {
      //If there are new dynamic contract registrations
      //discard this batch and redo once the the dynamic registrations have caught up
      chainFetcher.logger->Logging.childTrace({
        "message": "Dropping invalid batch due to new dynamic contract registration",
        "page fetch time elapsed (ms)": stats.pageFetchTime,
      })
      (state, [])
    }
  }
}

let taskReducer = (state: t, task: task, ~dispatchAction) => ()
