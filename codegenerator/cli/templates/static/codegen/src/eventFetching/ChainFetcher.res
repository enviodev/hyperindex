type pendingNextQuery = HypersyncPendingNextQuery(HyperSyncWorker.blockRangeFetchArgs) | Rpc

type t = {
  logger: Pino.t,
  fetcher: DynamicContractFetcher.t,
  chainConfig: Config.chainConfig,
  chainWorker: ref<ChainWorker.chainWorker>,
  //The latest known block of the chain
  currentBlockHeight: int,
  isFetchingBatch: bool,
  mutable lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.t,
}

//CONSTRUCTION
let make = (
  ~chainConfig: Config.chainConfig,
  ~lastBlockScannedHashes,
  ~maxQueueSize,
  ~shouldSyncFromRawEvents: bool,
): t => {
  let logger = Logging.createChild(~params={"chainId": chainConfig.chain})

  //Dangerous! Ref is not defined yet but will be defined in the next step
  let chainWorkerRef = ref(None->Obj.magic)

  let chainConfigWorkerNoCallback = {
    let noneCallback = None
    switch chainConfig.syncSource {
    | Rpc(_) => ChainWorker.RpcSelectedWithCallback(noneCallback)
    | HyperSync(_) => ChainWorker.HyperSyncSelectedWithCallback(noneCallback)
    }
  }
  let fetchedEventQueue = ChainEventQueue.make(~maxQueueSize)

  //TODO: Purge resync code or reimplement
  let chainWorkerWithCallback = chainConfigWorkerNoCallback
  let _ = shouldSyncFromRawEvents
  // if shouldSyncFromRawEvents {
  //   let finishedSyncCallback = async (worker: RawEventsWorker.t) => {
  //     await worker->RawEventsWorker.stopFetchingEvents
  //     logger->Logging.childInfo("Finished reprocessed cached events, starting fetcher")
  //     let contractAddressMapping = worker.contractAddressMapping
  //
  //     let latestFetchedEventId = await worker.latestFetchedEventId
  //     let {blockNumber} = latestFetchedEventId->EventUtils.unpackEventIndex
  //     let startBlock = blockNumber + 1
  //     chainWorkerRef :=
  //       chainConfigWorkerNoCallback->ChainWorker.make(~chainConfig, ~contractAddressMapping)
  //
  //     chainWorkerRef.contents
  //     ->ChainWorker.startWorker(~startBlock, ~fetchedEventQueue, ~logger, ~checkHasReorgOccurred)
  //     ->ignore
  //   }
  //
  //   ChainWorker.RawEventsSelectedWithCallback(Some(finishedSyncCallback))
  // } else {
  //   chainConfigWorkerNoCallback
  // }

  chainWorkerRef := chainWorkerWithCallback->ChainWorker.make(~chainConfig)

  let contractAddressMapping = {
    let m = ContractAddressingMap.make()
    //Add all contracts and addresses from config
    //Dynamic contracts are checked in DB on start
    m->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)
    m
  }

  {
    logger,
    chainConfig,
    chainWorker: chainWorkerRef,
    lastBlockScannedHashes,
    currentBlockHeight: 0,
    isFetchingBatch: false,
    fetcher: DynamicContractFetcher.makeRoot(~contractAddressMapping),
  }
}

// //Public methods
// let startFetchingEvents = async (self: t, ~checkHasReorgOccurred) => {
//   switch self.chainWorker.contents->ChainWorker.startFetchingEvents(
//     ~logger=self.logger,
//     ~fetchedEventQueue=self.fetchedEventQueue,
//     ~checkHasReorgOccurred=self->checkHasReorgOccurred,
//   ) {
//   | exception err =>
//     self.logger->Logging.childError({
//       "err": err,
//       "msg": `error while running chainWorker on chain ${self.chainConfig.chain->ChainMap.Chain.toString}`,
//     })
//     Error(err)
//   | _ => Ok()
//   }
// }

/**
Gets the latest item on the front of the queue and returns updated fetcher
*/
let getLatestItem = (self: t) => {
  self.fetcher->DynamicContractFetcher.getEarliestEvent
}

/**
Registers the new contract
fetches all the unfetched events
*/
let addDynamicContractAndFetchMissingEvents = (
  self: t,
  ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ~fromBlock,
  ~fromLogIndex,
): promise<array<Types.eventBatchQueueItem>> => {
  self.chainWorker.contents->ChainWorker.addDynamicContractAndFetchMissingEvents(
    ~dynamicContracts,
    ~fromBlock,
    ~fromLogIndex,
    ~logger=self.logger,
  )
}

type latestFetchedBlockTimestamp = int
type queueFront =
  | NoItem(latestFetchedBlockTimestamp, ChainMap.Chain.t)
  | Item(Types.eventBatchQueueItem)

// type queueFront = Val(queueItem) | WaitForDynamicContracts

// let getFrontOfQueue = (self: t): (_, queueFront) => {
//   let (nextFetcher, latestItem) = self->getLatestItem
//   let nextItem = switch latestItem {
//   | NoItem(latestFetchedBlockTimestamp) =>
//     NoItem(latestFetchedBlockTimestamp, self.chainConfig.chain)
//   | Item(item) => Item(item)
//   }
//   (nextFetcher, nextItem)
// }

let addNewRangeQueriedCallback = (self: t) => {
  ChainWorker.addNewRangeQueriedCallback(self.chainWorker.contents)
}
