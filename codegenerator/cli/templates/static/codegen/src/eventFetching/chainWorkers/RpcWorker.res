open Belt
open ChainWorkerTypes

type rec t = {
  currentBlockInterval: int,
  blockLoader: LazyLoader.asyncMap<Ethers.JsonRpcProvider.block>,
  chainConfig: Config.chainConfig,
  rpcConfig: Config.rpcConfig,
}

let make = (chainConfig: Config.chainConfig, ~rpcConfig: Config.rpcConfig): t => {
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

  {
    currentBlockInterval: rpcConfig.syncConfig.initialBlockInterval,
    blockLoader,
    chainConfig,
    rpcConfig,
  }
}

let waitForBlockGreaterThanCurrentHeight = async (
  {rpcConfig: {provider}}: t,
  ~currentBlockHeight,
  ~logger,
) => {
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
  self: t,
  ~fromBlock,
  ~currentBlockHeight,
  ~setCurrentBlockHeight,
  ~logger,
) => {
  //If there are no new blocks to fetch, poll the provider for
  //a new block until it arrives
  if fromBlock > currentBlockHeight {
    let nextBlock = await self->waitForBlockGreaterThanCurrentHeight(~currentBlockHeight, ~logger)

    setCurrentBlockHeight(nextBlock)

    nextBlock
  } else {
    currentBlockHeight
  }
}

let fetchBlockRange = async (
  self: t,
  ~query: blockRangeFetchArgs,
  ~logger,
  ~currentBlockHeight,
  ~setCurrentBlockHeight,
) => {
  let {currentBlockInterval, blockLoader, chainConfig, rpcConfig} = self
  let {fromBlock, toBlock, contractAddressMapping, fetchStateRegisterId} = query

  let startFetchingBatchTimeRef = Hrtime.makeTimer()
  let currentBlockHeight =
    await self->waitForNewBlockBeforeQuery(
      ~fromBlock,
      ~currentBlockHeight,
      ~setCurrentBlockHeight,
      ~logger,
    )

  let targetBlock = Pervasives.min(toBlock, fromBlock + currentBlockInterval - 1)

  let toBlockTimestampPromise =
    blockLoader->LazyLoader.get(targetBlock)->Promise.thenResolve(block => block.timestamp)

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
    ~rpcConfig,
    ~chain=chainConfig.chain,
    ~blockLoader,
    ~logger,
    (),
  )

  let parsedQueueItems =
    await eventBatchPromises
    ->Array.map(async ({
      timestampPromise,
      chain,
      blockNumber,
      logIndex,
      eventPromise,
    }): Types.eventBatchQueueItem => {
      timestamp: await timestampPromise,
      chain,
      blockNumber,
      logIndex,
      event: await eventPromise,
    })
    ->Promise.all

  let sc = rpcConfig.syncConfig

  let nextWorker = {
    ...self,
    // Increase batch size going forward, but do not increase past a configured maximum
    // See: https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease
    currentBlockInterval: Pervasives.min(
      finalExecutedBlockInterval + sc.accelerationAdditive,
      sc.intervalCeiling,
    ),
  }

  let heighestQueriedBlockTimestamp = await toBlockTimestampPromise

  let heighestQueriedBlockNumber = targetBlock

  let totalTimeElapsed =
    startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

  let reorgGuardStub: reorgGuard = {
    parentHash: None,
    lastBlockScannedData: {
      blockNumber: 0,
      blockTimestamp: 0,
      blockHash: "0x1234",
    },
  }

  {
    latestFetchedBlockTimestamp: heighestQueriedBlockTimestamp,
    parsedQueueItems,
    heighestQueriedBlockNumber,
    stats: {
      totalTimeElapsed: totalTimeElapsed,
    },
    currentBlockHeight,
    reorgGuard: reorgGuardStub,
    fromBlockQueried: fromBlock,
    fetchStateRegisterId,
    worker: Rpc(nextWorker),
  }
}

/**
Currently just a stub to conform to signature
*/
let getBlockHashes = (self: t, ~blockNumbers) => {
  let _ = (self, blockNumbers)
  Ok([])->Promise.resolve
}
