open Belt
open ChainWorker

module Make = (
  T: {
    let config: Config.t
    let rpcConfig: Config.rpcConfig
    let chainConfig: Config.chainConfig
  },
): S => {
  let name = "RPC"
  let config = T.config
  let rpcConfig = T.rpcConfig
  let chainConfig = T.chainConfig
  let chain = chainConfig.chain

  let blockIntervals = Js.Dict.empty()

  let blockLoader = LazyLoader.make(
    ~loaderFn=blockNumber =>
      EventFetching.getUnwrappedBlockWithBackoff(
        ~provider=rpcConfig.provider,
        ~backoffMsOnFailure=1000,
        ~blockNumber,
      ),
    ~metadata={
      asyncTaskName: "blockLoader: fetching block timestamp - `getBlock` rpc call",
      caller: "RPC ChainWorker",
      suggestedFix: "This likely means the RPC url you are using is not respending correctly. Please try another RPC endipoint.",
    },
    (),
  )

  let waitForBlockGreaterThanCurrentHeight = async (~currentBlockHeight, ~logger) => {
    let provider = T.rpcConfig.provider
    let nextBlockWait = provider->EventUtils.waitForNextBlock
    let latestHeight =
      await provider
      ->Ethers.JsonRpcProvider.getBlockNumber
      ->Promise.catch(_err => {
        logger->Logging.childWarn("Error getting current block number")
        0->Promise.resolve
      })
    if latestHeight > currentBlockHeight {
      latestHeight
    } else {
      await nextBlockWait
    }
  }

  let waitForNewBlockBeforeQuery = async (
    ~fromBlock,
    ~currentBlockHeight,
    ~setCurrentBlockHeight,
    ~logger,
  ) => {
    //If there are no new blocks to fetch, poll the provider for
    //a new block until it arrives
    if fromBlock > currentBlockHeight {
      let nextBlock = await waitForBlockGreaterThanCurrentHeight(~currentBlockHeight, ~logger)

      setCurrentBlockHeight(nextBlock)

      nextBlock
    } else {
      currentBlockHeight
    }
  }

  let fetchBlockRange = async (
    ~query: blockRangeFetchArgs,
    ~logger,
    ~currentBlockHeight,
    ~setCurrentBlockHeight,
  ) => {
    try {
      let {
        fromBlock,
        toBlock,
        contractAddressMapping,
        fetchStateRegisterId,
        partitionId,
        ?eventFilters,
      } = query

      let startFetchingBatchTimeRef = Hrtime.makeTimer()
      let currentBlockHeight = await waitForNewBlockBeforeQuery(
        ~fromBlock,
        ~currentBlockHeight,
        ~setCurrentBlockHeight,
        ~logger,
      )

      let currentBlockInterval = blockIntervals->Js.Dict.get(partitionId->Belt.Int.toString)->Belt.Option.getWithDefault(
        T.rpcConfig.syncConfig.initialBlockInterval,
      )

      let targetBlock = Pervasives.min(toBlock, fromBlock + currentBlockInterval - 1)

      let toBlockPromise = blockLoader->LazyLoader.get(targetBlock)

      let firstBlockParentPromise =
        fromBlock > 0
          ? blockLoader->LazyLoader.get(fromBlock - 1)->Promise.thenResolve(res => res->Some)
          : Promise.resolve(None)

      //Needs to be run on every loop in case of new registrations
      let contractInterfaceManager = ContractInterfaceManager.make(
        ~contractAddressMapping,
        ~chainConfig,
      )

      let {
        eventBatchPromises,
        finalExecutedBlockInterval,
      } = await EventFetching.getContractEventsOnFilters(
        ~contractInterfaceManager,
        ~fromBlock,
        ~toBlock=targetBlock,
        ~initialBlockInterval=currentBlockInterval,
        ~minFromBlockLogIndex=0,
        ~rpcConfig=T.rpcConfig,
        ~chain,
        ~blockLoader,
        ~logger,
        ~config,
      )

      let eventBatches = await eventBatchPromises->Promise.all
      let parsedQueueItemsPreFilter = eventBatches->Array.map(({
        timestamp,
        chain,
        blockNumber,
        logIndex,
        event,
        eventMod,
      }): Types.eventBatchQueueItem => {
        timestamp,
        chain,
        blockNumber,
        logIndex,
        event,
        eventMod,
      })

      let parsedQueueItems = switch eventFilters {
      //Most cases there are no filters so this will be passed throug
      | None => parsedQueueItemsPreFilter
      | Some(eventFilters) =>
        //In the case where there are filters, apply them and keep the events that
        //are needed
        parsedQueueItemsPreFilter->Array.keep(item => item->FetchState.applyFilters(~eventFilters))
      }

      let sc = rpcConfig.syncConfig

      // Increase batch size going forward, but do not increase past a configured maximum
      // See: https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease
      blockIntervals->Js.Dict.set(partitionId->Belt.Int.toString, Pervasives.min(finalExecutedBlockInterval + sc.accelerationAdditive, sc.intervalCeiling))

      let (optFirstBlockParent, toBlock) = (await firstBlockParentPromise, await toBlockPromise)

      let heighestQueriedBlockNumber = targetBlock

      let totalTimeElapsed =
        startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

      let reorgGuardStub: reorgGuard = {
        firstBlockParentNumberAndHash: optFirstBlockParent->Option.map(b => {
          ReorgDetection.blockNumber: b.number,
          blockHash: b.hash,
        }),
        lastBlockScannedData: {
          blockNumber: toBlock.number,
          blockTimestamp: toBlock.timestamp,
          blockHash: toBlock.hash,
        },
      }

      {
        latestFetchedBlockTimestamp: toBlock.timestamp,
        parsedQueueItems,
        heighestQueriedBlockNumber,
        stats: {
          totalTimeElapsed: totalTimeElapsed,
        },
        currentBlockHeight,
        reorgGuard: reorgGuardStub,
        fromBlockQueried: fromBlock,
        fetchStateRegisterId,
        partitionId,
      }->Ok
    } catch {
    | exn => exn->ErrorHandling.make(~logger, ~msg="Failed to fetch block Range")->Error
    }
  }

  let getBlockHashes = (~blockNumbers) => {
    blockNumbers
    ->Array.map(blockNum => blockLoader->LazyLoader.get(blockNum))
    ->Promise.all
    ->Promise.thenResolve(blocks => {
      blocks
      ->Array.map(b => {
        ReorgDetection.blockNumber: b.number,
        blockHash: b.hash,
        blockTimestamp: b.timestamp,
      })
      ->Ok
    })
    ->Promise.catch(exn => exn->Error->Promise.resolve)
  }
}
