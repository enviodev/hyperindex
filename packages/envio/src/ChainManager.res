type t = {
  chainFetchers: ChainMap.t<ChainFetcher.t>,
  isInReorgThreshold: bool,
  // True once every chain has caught up to head/endBlock. Monotonic during a run.
  isRealtime: bool,
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
    | 1 => 60_000
    | 2 => 30_000
    | 3 => 20_000
    | 4 => 15_000
    | 5 => 10_000
    | _ => 5_000
    }
  }
}

let makeFromDbState = (
  ~initialState: Persistence.initialState,
  ~config: Config.t,
  ~registrations,
  ~reducedPollingInterval=?,
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

  // updateSyncTimeOnRestart wipes the saved timestamp so a restart re-enters
  // backfill mode for all chains.
  let isRealtime =
    !Env.updateSyncTimeOnRestart &&
    initialState.chains->Array.length > 0 &&
    initialState.chains->Array.every(c => c.timestampCaughtUpToHeadOrEndblock->Option.isSome)

  let chainFetchersArr =
    initialState.chains->Array.map((resumedChainState: Persistence.initialChainState) => {
      let chain = Config.getChain(config, ~chainId=resumedChainState.id)
      let chainConfig = config.chainMap->ChainMap.get(chain)

      (
        chain,
        chainConfig->ChainFetcher.makeFromDbState(
          ~resumedChainState,
          ~reorgCheckpoints=initialState.reorgCheckpoints,
          ~isInReorgThreshold,
          ~isRealtime,
          ~targetBufferSize,
          ~config,
          ~registrations,
          ~reducedPollingInterval?,
        ),
      )
    })

  let chainFetchers = ChainMap.fromArrayUnsafe(chainFetchersArr)

  // Set initial progress metrics from DB state so dashboards reflect
  // the persisted state immediately on restart
  let allChainsReady = ref(chainFetchersArr->Array.length > 0)
  chainFetchersArr->Array.forEach(((chain, cf)) => {
    let chainId = chain->ChainMap.Chain.toChainId
    Prometheus.ProgressBlockNumber.set(~blockNumber=cf.committedProgressBlockNumber, ~chainId)
    Prometheus.ProgressReady.init(~chainId)
    if cf->ChainFetcher.isReady {
      Prometheus.ProgressReady.set(~chainId)
    } else {
      allChainsReady := false
    }
  })
  if allChainsReady.contents {
    Prometheus.ProgressReady.setAllReady()
  }

  {
    chainFetchers,
    isInReorgThreshold,
    isRealtime,
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
  !Batch.hasReadyItem(
    chainManager.chainFetchers->ChainMap.map(cf => {
      cf.fetchState
    }),
  )
}

let createBatch = (
  chainManager: t,
  ~processedCheckpointId,
  ~batchSizeTarget: int,
  ~isRollback: bool,
): Batch.t => {
  Batch.make(
    ~isInReorgThreshold=chainManager.isInReorgThreshold,
    ~checkpointIdBeforeBatch=processedCheckpointId->BigInt.add(
      // Since for rollback we have a diff checkpoint id.
      // This is needed to currectly overwrite old state
      // in an append-only ClickHouse insert.
      isRollback ? 1n : 0n,
    ),
    ~chainsBeforeBatch=chainManager.chainFetchers->ChainMap.map((cf): Batch.chainBeforeBatch => {
      fetchState: cf.fetchState,
      progressBlockNumber: cf.committedProgressBlockNumber,
      totalEventsProcessed: cf.numEventsProcessed,
      sourceBlockNumber: cf.fetchState.knownHeight,
      reorgDetection: cf.reorgDetection,
      chainConfig: cf.chainConfig,
    }),
    ~batchSizeTarget,
  )
}

let isProgressAtHead = chainManager =>
  chainManager.chainFetchers->ChainMap.values->Array.every(cf => cf.isProgressAtHead)

let isActivelyIndexing = chainManager =>
  chainManager.chainFetchers->ChainMap.values->Array.every(ChainFetcher.isActivelyIndexing)

let getSafeCheckpointId = (chainManager: t) => {
  let chainFetchers = chainManager.chainFetchers->ChainMap.values

  let result: ref<option<bigint>> = ref(None)

  for idx in 0 to chainFetchers->Array.length - 1 {
    let chainFetcher = chainFetchers->Array.getUnsafe(idx)
    switch chainFetcher.safeCheckpointTracking {
    | None => () // Skip chains with maxReorgDepth = 0
    | Some(safeCheckpointTracking) => {
        let safeCheckpointId =
          safeCheckpointTracking->SafeCheckpointTracking.getSafeCheckpointId(
            ~sourceBlockNumber=chainFetcher.fetchState.knownHeight,
          )
        switch result.contents {
        | None => result := Some(safeCheckpointId)
        | Some(current) if safeCheckpointId < current => result := Some(safeCheckpointId)
        | _ => ()
        }
      }
    }
  }

  switch result.contents {
  | Some(id) if id > 0n => Some(id)
  | _ => None // No safe checkpoint found
  }
}

/**
Takes in a chain manager and sets all chains timestamp caught up to head
when valid state lines up and returns an updated chain manager
*/
let updateProgressedChains = (chainManager: t, ~batch: Batch.t) => {
  let nextQueueItemIsNone = chainManager->nextItemIsNone

  let allChainsAtHead = chainManager->isProgressAtHead
  //Update the timestampCaughtUpToHeadOrEndblock values
  let allChainsReady = ref(true)
  let chainFetchers = chainManager.chainFetchers->ChainMap.map(prev => {
    let cf = prev
    let chain = ChainMap.Chain.makeUnsafe(~chainId=cf.chainConfig.id)

    let maybeChainAfterBatch =
      batch.progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(
        chain->ChainMap.Chain.toChainId,
      )

    let cf = switch maybeChainAfterBatch {
    | Some(chainAfterBatch) => {
        if cf.committedProgressBlockNumber !== chainAfterBatch.progressBlockNumber {
          Prometheus.ProgressBlockNumber.set(
            ~blockNumber=chainAfterBatch.progressBlockNumber,
            ~chainId=chain->ChainMap.Chain.toChainId,
          )
        }
        if cf.numEventsProcessed !== chainAfterBatch.totalEventsProcessed {
          Prometheus.ProgressEventsCount.set(
            ~processedCount=chainAfterBatch.totalEventsProcessed,
            ~chainId=chain->ChainMap.Chain.toChainId,
          )
        }

        // Calculate and set latency metrics
        switch batch->Batch.findLastEventItem(~chainId=chain->ChainMap.Chain.toChainId) {
        | Some(eventItem) => {
            let blockTimestamp = eventItem.timestamp
            let currentTimeMs = Date.now()->Float.toInt
            let blockTimestampMs = blockTimestamp * 1000
            let latencyMs = currentTimeMs - blockTimestampMs

            Prometheus.ProgressLatency.set(~latencyMs, ~chainId=chain->ChainMap.Chain.toChainId)
          }
        | None => ()
        }

        {
          ...cf,
          // Since we process per chain always in order,
          // we need to calculate it once, by using the first item in a batch
          fetchState: switch cf.fetchState.firstEventBlock {
          | Some(_) => cf.fetchState
          | None =>
            switch batch->Batch.findFirstEventBlockNumber(
              ~chainId=chain->ChainMap.Chain.toChainId,
            ) {
            | Some(_) as firstEventBlock => {...cf.fetchState, firstEventBlock}
            | None => cf.fetchState
            }
          },
          committedProgressBlockNumber: chainAfterBatch.progressBlockNumber,
          numEventsProcessed: chainAfterBatch.totalEventsProcessed,
          isProgressAtHead: cf.isProgressAtHead || chainAfterBatch.isProgressAtHeadWhenBatchCreated,
          safeCheckpointTracking: switch cf.safeCheckpointTracking {
          | Some(safeCheckpointTracking) =>
            Some(
              safeCheckpointTracking->SafeCheckpointTracking.updateOnNewBatch(
                ~sourceBlockNumber=cf.fetchState.knownHeight,
                ~chainId=chain->ChainMap.Chain.toChainId,
                ~batchCheckpointIds=batch.checkpointIds,
                ~batchCheckpointBlockNumbers=batch.checkpointBlockNumbers,
                ~batchCheckpointChainIds=batch.checkpointChainIds,
              ),
            )
          | None => None
          },
        }
      }
    | None => cf
    }

    /* strategy for TUI synced status:
     * Firstly -> only update synced status after batch is processed (not on batch creation). But also set when a batch tries to be created and there is no batch
     *
     * Secondly -> reset timestampCaughtUpToHead and isFetching at head when dynamic contracts get registered to a chain if they are not within 0.001 percent of the current block height
     *
     * New conditions for valid synced:
     *
     * CASE 1 (chains are being synchronised at the head)
     *
     * All chain fetchers are fetching at the head AND
     * No events that can be processed on the queue (even if events still exist on the individual queues)
     * CASE 2 (chain finishes earlier than any other chain)
     *
     * CASE 3 endblock has been reached and latest processed block is greater than or equal to endblock (both fields must be Some)
     *
     * The given chain fetcher is fetching at the head or latest processed block >= endblock
     * The given chain has processed all events on the queue
     * see https://github.com/Float-Capital/indexer/pull/1388 */
    let cf = if cf->ChainFetcher.hasProcessedToEndblock {
      // in the case this is already set, don't reset and instead propagate the existing value
      let timestampCaughtUpToHeadOrEndblock =
        cf->ChainFetcher.isReady ? cf.timestampCaughtUpToHeadOrEndblock : Date.make()->Some
      {
        ...cf,
        timestampCaughtUpToHeadOrEndblock,
      }
    } else if !(cf->ChainFetcher.isReady) && cf.isProgressAtHead {
      //Only calculate and set timestampCaughtUpToHeadOrEndblock if chain fetcher is at the head and
      //its not already set
      //CASE1
      //All chains are caught up to head chainManager queue returns None
      //Meaning we are busy synchronizing chains at the head
      if nextQueueItemIsNone && allChainsAtHead {
        {
          ...cf,
          timestampCaughtUpToHeadOrEndblock: Date.make()->Some,
        }
      } else {
        //CASE2 -> Only calculate if case1 fails
        //All events have been processed on the chain fetchers queue
        //Other chains may be busy syncing
        let hasNoMoreEventsToProcess = cf->ChainFetcher.hasNoMoreEventsToProcess

        if hasNoMoreEventsToProcess {
          {
            ...cf,
            timestampCaughtUpToHeadOrEndblock: Date.make()->Some,
          }
        } else {
          //Default to just returning cf
          cf
        }
      }
    } else {
      //Default to just returning cf
      cf
    }

    // Set envio_progress_ready per-chain when it first becomes ready
    if cf->ChainFetcher.isReady {
      if !(prev->ChainFetcher.isReady) {
        Prometheus.ProgressReady.set(~chainId=chain->ChainMap.Chain.toChainId)
      }
    } else {
      allChainsReady := false
    }

    cf
  })

  if allChainsReady.contents {
    Prometheus.ProgressReady.setAllReady()
  }

  {
    ...chainManager,
    chainFetchers,
    isRealtime: chainManager.isRealtime || allChainsReady.contents,
  }
}
