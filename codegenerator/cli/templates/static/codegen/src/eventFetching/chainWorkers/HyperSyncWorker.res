open ChainWorkerTypes
type rec t = {
  mutable currentBlockHeight: int,
  mutable latestFetchedBlockNumber: promise<int>, // promise allows locking of this field while a batch has been fetched but still being added
  mutable latestFetchedBlockTimestamp: int,
  mutable hasNewDynamicContractRegistrations: promise<bool>, //promise allows us to use this field as a lock
  mutable shouldContinueFetching: bool,
  mutable isFetching: bool,
  mutable hasStoppedFetchingCallBack: unit => unit,
  newRangeQueriedCallBacks: SDSL.Queue.t<unit => unit>,
  contractAddressMapping: ContractAddressingMap.mapping,
  chainConfig: Config.chainConfig,
  serverUrl: string,
  caughtUpToHeadHook: t => promise<unit>,
}

module Helpers = {
  let rec queryLogsPageWithBackoff = async (
    ~backoffMsOnFailure=200,
    ~callDepth=0,
    ~maxCallDepth=15,
    query: unit => promise<HyperSync.queryResponse<HyperSync.logsQueryPage>>,
    logger: Pino.t,
  ) =>
    switch await query() {
    | Error(e) =>
      let msg = e->HyperSync.queryErrorToMsq
      if callDepth < maxCallDepth {
        logger->Logging.childWarn({
          "err": msg,
          "msg": `Issue while running fetching of events from Hypersync endpoint. Will wait ${backoffMsOnFailure->Belt.Int.toString}ms and try again.`,
          "type": "EXPONENTIAL_BACKOFF",
        })
        await Time.resolvePromiseAfterDelay(~delayMilliseconds=backoffMsOnFailure)
        await queryLogsPageWithBackoff(
          ~callDepth=callDepth + 1,
          ~backoffMsOnFailure=2 * backoffMsOnFailure,
          query,
          logger,
        )
      } else {
        logger->Logging.childError({
          "err": msg,
          "msg": `Issue while running fetching batch of events from Hypersync endpoint. Attempted query a maximum of ${maxCallDepth->string_of_int} times. Will NOT retry.`,
          "type": "EXPONENTIAL_BACKOFF_MAX_DEPTH",
        })
        Js.Exn.raiseError(msg)
      }
    | Ok(v) => v
    }
}

let stopFetchingEvents = (self: t) => {
  //set the shouldContinueFetching to false
  self.shouldContinueFetching = false

  //set a resolve callback for when it's actually stopped
  if !self.isFetching {
    Promise.resolve()
  } else {
    Promise.make((resolve, _reject) => {
      self.hasStoppedFetchingCallBack = () => resolve(. ())
    })
  }
}

let make = (
  ~caughtUpToHeadHook=?,
  ~contractAddressMapping=?,
  chainConfig: Config.chainConfig,
): t => {
  let caughtUpToHeadHook = switch caughtUpToHeadHook {
  | None => (_self: t) => Promise.resolve()
  | Some(hook) => hook
  }

  let logger = Logging.createChild(
    ~params={
      "chainId": chainConfig.chainId,
      "workerType": "Hypersync",
      "loggerFor": "Used only in logging regestration of static contract addresses",
    },
  )

  let contractAddressMapping = switch contractAddressMapping {
  | None =>
    let m = ContractAddressingMap.make()
    //Add all contracts and addresses from config
    //Dynamic contracts are checked in DB on start
    m->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)
    m
  | Some(m) => m
  }

  let serverUrl = switch chainConfig.syncSource {
  | HyperSync(serverUrl) => serverUrl
  | syncSource =>
    let exn = IncorrectSyncSource(syncSource)
    logger->Logging.childErrorWithExn(
      exn,
      {
        "msg": "Passed incorrect sync source to a hypersync worker",
        "syncSource": syncSource,
      },
    )
    exn->raise
  }

  {
    currentBlockHeight: 0,
    latestFetchedBlockNumber: Promise.resolve(0),
    latestFetchedBlockTimestamp: 0,
    hasNewDynamicContractRegistrations: Promise.resolve(false),
    shouldContinueFetching: true,
    isFetching: false,
    hasStoppedFetchingCallBack: () => (),
    newRangeQueriedCallBacks: SDSL.Queue.make(),
    contractAddressMapping,
    chainConfig,
    serverUrl,
    caughtUpToHeadHook,
  }
}

/**
Sets both the block height in state and asynchronously with chain metadata row (does not wait for promise response)
If the given value is greater than the current state

This is a placeholder for an action that will be dispatched to the globale state manager
*/
let setCurrentBlockHeight = (self: t, ~currentBlockHeight, ~startBlock) =>
  if currentBlockHeight > self.currentBlockHeight {
    self.currentBlockHeight = currentBlockHeight

    //Don't await this set, it can happen in its own time
    DbFunctions.ChainMetadata.setChainMetadataRow(
      ~chainId=self.chainConfig.chainId,
      ~startBlock,
      ~blockHeight=currentBlockHeight,
    )->ignore
  }

/**
Sets the latest latestFetchedBlockTimestamp in state if it is greater than the current state
*/
let setLatestFetchedBlockTimestamp = (self: t, ~latestFetchedBlockTimestamp) =>
  if latestFetchedBlockTimestamp > self.latestFetchedBlockTimestamp {
    self.latestFetchedBlockTimestamp = latestFetchedBlockTimestamp
  }

/**
Holds the value of the next page fetch happening concurrently to current page processing
*/
type nextPageFetchRes = {
  contractInterfaceManager: ContractInterfaceManager.t,
  page: HyperSync.logsQueryPage,
  pageFetchTime: int,
}

/**
The args required for calling block range fetch
*/
type blockRangeFetchArgs = {
  fromBlock: int,
  latestFetchedBlockTimestamp: int,
  nextPagePromise: promise<nextPageFetchRes>,
}

/**
A set of stats for logging about the block range fetch
*/
type blockRangeFetchStats = {
  @as("total time elapsed (ms)") totalTimeElapsed: int,
  @as("parsing time (ms)") parsingTimeElapsed: int,
  @as("page fetch time (ms)") pageFetchTime: int,
  @as("average parse time per log (ms)") averageParseTimePerLog: float,
}

type reorgGuard = {
  lastBlockScannedData: ReorgDetection.lastBlockScannedData,
  parentHash: option<string>,
}

/**
Thes response returned from a block range fetch
*/
type blockRangeFetchResponse = {
  currentBlockHeight: int,
  reorgGuard: reorgGuard,
  nextQuery: blockRangeFetchArgs,
  parsedQueueItems: array<Types.eventBatchQueueItem>,
  heighestQueriedBlockNumber: int,
  stats: blockRangeFetchStats,
}

let fetchBlockRange = async (
  {nextPagePromise, latestFetchedBlockTimestamp, fromBlock},
  ~chainId,
  ~logger,
  ~serverUrl,
  ~getNextPage,
): blockRangeFetchResponse => {
  let startFetchingBatchTimeRef = Hrtime.makeTimer()
  //fetch batch
  let {page: pageUnsafe, contractInterfaceManager, pageFetchTime} = await nextPagePromise

  //set height and next from block
  let currentBlockHeight = pageUnsafe.archiveHeight

  //TOD: This is a stub, it will need to be returned in a single query from hypersync
  let parentHash = pageUnsafe->ReorgDetection.getParentHashStub

  //TODO: This is a stub, it will need to be returned in a single query from hypersync
  let lastBlockScannedData = pageUnsafe->ReorgDetection.getLastBlockScannedDataStub

  let reorgGuard = {
    lastBlockScannedData,
    parentHash,
  }

  let nextBlock = pageUnsafe.nextBlock

  let nextPagePromise = getNextPage(~fromBlock=pageUnsafe.nextBlock, ~currentBlockHeight)

  logger->Logging.childTrace({
    "message": "Retrieved event page from server",
    "fromBlock": fromBlock,
    "toBlock": pageUnsafe.nextBlock - 1,
  })

  //The heighest (biggest) blocknumber that was accounted for in
  //Our query. Not necessarily the blocknumber of the last log returned
  //In the query
  let heighestBlockQueried = pageUnsafe.nextBlock - 1

  //Helper function to fetch the timestamp of the heighest block queried
  //In the case that it is unknown
  let getHeighestBlockAndTimestampWithDefault = (~default: HyperSync.blockNumberAndTimestamp) => {
    HyperSync.queryBlockTimestampsPage(
      ~serverUrl,
      ~fromBlock=heighestBlockQueried,
      ~toBlock=heighestBlockQueried,
    )->Promise.thenResolve(res =>
      res->Belt.Result.mapWithDefault(default, page => {
        //Expected only 1 item but just taking last in case things change and we return
        //a range
        let lastBlockInRangeQueried = page.items->Belt.Array.get(page.items->Array.length - 1)

        lastBlockInRangeQueried->Belt.Option.getWithDefault(default)
      })
    )
  }

  //The optional block and timestamp of the last item returned by the query
  //(Optional in the case that there are no logs returned in the query)
  let logItemsHeighestBlockOpt =
    pageUnsafe.items
    ->Belt.Array.get(pageUnsafe.items->Belt.Array.length - 1)
    ->Belt.Option.map((item): HyperSync.blockNumberAndTimestamp => {
      blockNumber: item.log.blockNumber,
      timestamp: item.blockTimestamp,
    })

  let heighestBlockQueriedPromise: promise<
    HyperSync.blockNumberAndTimestamp,
  > = switch logItemsHeighestBlockOpt {
  | Some(val) =>
    let {blockNumber, timestamp} = val
    if blockNumber == heighestBlockQueried {
      //If the last log item in the current page is equal to the
      //heighest block acounted for in the query. Simply return this
      //value without making an extra query
      Promise.resolve(val)
    } else {
      //If it does not match it means that there were no matching logs in the last
      //block so we should fetch the block timestamp with a default of our heighest
      //timestamp (the value in our heighest log)
      getHeighestBlockAndTimestampWithDefault(
        ~default={timestamp, blockNumber: heighestBlockQueried},
      )
    }

  | None =>
    //If there were no logs at all in the current page query then fetch the
    //timestamp of the heighest block accounted for,
    //defaulting to our current latest blocktimestamp
    getHeighestBlockAndTimestampWithDefault(
      ~default={
        blockNumber: heighestBlockQueried,
        timestamp: latestFetchedBlockTimestamp,
      },
    )
  }

  let parsingTimeRef = Hrtime.makeTimer()
  //Parse page items into queue items
  let parsedQueueItems =
    await pageUnsafe.items
    //Defer all this parsing into separate deferred callbacks
    //on the macro task queue so that parsing doesn't block the
    //event loop and each parse happens as a macro task. Meaning
    //promise resolves will take priority
    ->Deferred.mapArrayDeferred((item, resolve, reject) => {
      switch Converters.parseEvent(
        ~log=item.log,
        ~blockTimestamp=item.blockTimestamp,
        ~contractInterfaceManager,
        ~chainId,
      ) {
      | Ok(parsed) =>
        let queueItem: Types.eventBatchQueueItem = {
          timestamp: item.blockTimestamp,
          chainId,
          blockNumber: item.log.blockNumber,
          logIndex: item.log.logIndex,
          event: parsed,
        }
        resolve(queueItem)
      | Error(e) => reject(Converters.ParseEventErrorExn(e))
      }
    })
    ->Deferred.asPromise

  let parsingTimeElapsed = parsingTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

  //set latestFetchedBlockNumber and latestFetchedBlockTimestamp
  let {
    blockNumber: heighestQueriedBlockNumber,
    timestamp: heighestQueriedBlockTimestamp,
  } = await heighestBlockQueriedPromise

  let totalTimeElapsed =
    startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

  let stats = {
    totalTimeElapsed,
    parsingTimeElapsed,
    pageFetchTime,
    averageParseTimePerLog: parsingTimeElapsed->Belt.Int.toFloat /.
      parsedQueueItems->Array.length->Belt.Int.toFloat,
  }

  let nextQuery: blockRangeFetchArgs = {
    fromBlock: nextBlock,
    latestFetchedBlockTimestamp: heighestQueriedBlockTimestamp,
    nextPagePromise,
  }

  {
    parsedQueueItems,
    nextQuery,
    heighestQueriedBlockNumber,
    stats,
    currentBlockHeight,
    reorgGuard,
  }
}

/**
This temporarily holds the looping of calling the fetch block range action. This will change or 
disappear when it becomes something that simply dispatches actions based on the response of fetch block
ranges
*/
let loopFetchBlockRanges = async (
  self: t,
  ~initalQueryArgs,
  ~checkHasReorgOccurred,
  ~logger,
  ~getNextPage,
  ~fetchedEventQueue,
  ~setCurrentBlockHeight,
) => {
  let {serverUrl} = self
  let queryArgs = ref(initalQueryArgs)
  while self.shouldContinueFetching {
    let {
      parsedQueueItems,
      heighestQueriedBlockNumber,
      stats,
      nextQuery,
      currentBlockHeight,
      reorgGuard,
    } = await fetchBlockRange(
      queryArgs.contents,
      ~serverUrl,
      ~getNextPage,
      ~logger,
      ~chainId=self.chainConfig.chainId,
    )

    let {parentHash, lastBlockScannedData} = reorgGuard

    //TODO: this should rather return a value and dispatch a different action
    lastBlockScannedData->checkHasReorgOccurred(~parentHash, ~currentHeight=currentBlockHeight)

    if await self.hasNewDynamicContractRegistrations {
      //If there are new dynamic contract registrations
      //discard this batch and redo the query with new address
      self.hasNewDynamicContractRegistrations = Promise.resolve(false)

      logger->Logging.childTrace({
        "message": "Dropping invalid batch due to new dynamic contract registration",
        "page fetch time elapsed (ms)": stats.pageFetchTime,
      })
    } else {
      //Loop through items, add them to the queue
      for i in 0 to parsedQueueItems->Array.length - 1 {
        let queueItem = parsedQueueItems[i]

        //Add item to the queue
        await fetchedEventQueue->ChainEventQueue.awaitQueueSpaceAndPushItem(queueItem)

        //Loop through any callbacks on the queue waiting for confirmation of a new
        //range queried and run callbacks needs to happen after each item is added
        //else this we could be blocked from adding items to the queue and from popping
        //items off without running callbacks
        self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())

        //Loop through any callbacks on the queue waiting for confirmation of a new
        //range queried and run callbacks since there will be an updated timestamp even
        //If there ar no items in the page
        self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())

        logger->Logging.childTrace({
          "message": "Finished page range",
          "fromBlock": queryArgs.contents.fromBlock,
          "toBlock": heighestQueriedBlockNumber,
          "number of logs": parsedQueueItems->Array.length,
          "stats": stats,
        })
      }
    }

    //Note these side effects can disappear once we use immutable dispatcher
    self->setLatestFetchedBlockTimestamp(
      ~latestFetchedBlockTimestamp=nextQuery.latestFetchedBlockTimestamp,
    )
    setCurrentBlockHeight(~currentBlockHeight)

    queryArgs := nextQuery
  }
}

let startWorker = async (
  self: t,
  ~startBlock,
  ~logger,
  ~fetchedEventQueue,
  ~checkHasReorgOccurred,
) => {
  logger->Logging.childInfo("Hypersync worker starting")
  let {chainConfig, contractAddressMapping, serverUrl} = self
  let initialHeight = await HyperSync.getHeightWithRetry(~serverUrl, ~logger)
  let setCurrentBlockHeight = self->setCurrentBlockHeight(~startBlock)

  setCurrentBlockHeight(~currentBlockHeight=initialHeight)

  let waitForNextBlockBeforeQuery = async (~fromBlock, ~currentBlockHeight) => {
    if fromBlock >= currentBlockHeight {
      logger->Logging.childTrace("Worker is caught up, awaiting new blocks")

      //If the block we want to query from is greater than the current height,
      //poll for until the archive height is greater than the from block and set
      //current height to the new height
      let currentBlockHeight = await HyperSync.pollForHeightGtOrEq(
        ~serverUrl,
        ~blockNumber=fromBlock,
        ~logger,
      )

      //Note: this side effect can be removed when this becomes immutable
      setCurrentBlockHeight(~currentBlockHeight)

      currentBlockHeight
    } else {
      currentBlockHeight
    }
  }

  let getNextPage = async (~fromBlock, ~currentBlockHeight) => {
    //Wait for a valid range to query
    let currentBlockHeight = await waitForNextBlockBeforeQuery(~fromBlock, ~currentBlockHeight)

    //Instantiate each time to add new registered contract addresses
    let contractInterfaceManager = ContractInterfaceManager.make(
      ~chainConfig,
      ~contractAddressMapping,
    )

    let contractAddressesAndtopics =
      contractInterfaceManager->ContractInterfaceManager.getAllContractTopicsAndAddresses

    let startFetchingBatchTimeRef = Hrtime.makeTimer()

    //fetch batch
    let pageUnsafe = await Helpers.queryLogsPageWithBackoff(
      () =>
        HyperSync.queryLogsPage(
          ~serverUrl=self.serverUrl,
          ~fromBlock,
          ~toBlock=currentBlockHeight,
          ~contractAddressesAndtopics,
        ),
      logger,
    )

    let pageFetchTime =
      startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    {page: pageUnsafe, contractInterfaceManager, pageFetchTime}
  }

  let initialPagePromise = getNextPage(
    ~fromBlock=startBlock,
    ~currentBlockHeight=self.currentBlockHeight,
  )

  let initalQueryArgs: blockRangeFetchArgs = {
    fromBlock: startBlock,
    latestFetchedBlockTimestamp: self.latestFetchedBlockTimestamp,
    nextPagePromise: initialPagePromise,
  }

  await self->loopFetchBlockRanges(
    ~fetchedEventQueue,
    ~checkHasReorgOccurred,
    ~initalQueryArgs,
    ~logger,
    ~getNextPage,
    ~setCurrentBlockHeight,
  )
}

let startFetchingEvents = async (
  self: t,
  ~logger: Pino.t,
  ~fetchedEventQueue: ChainEventQueue.t,
  ~checkHasReorgOccurred,
) => {
  logger->Logging.childTrace("Starting event fetching on HyperSync worker")

  let {chainConfig, contractAddressMapping} = self
  let latestProcessedBlock = await DbFunctions.EventSyncState.getLatestProcessedBlockNumber(
    ~chainId=chainConfig.chainId,
  )

  let startBlock =
    latestProcessedBlock->Belt.Option.mapWithDefault(chainConfig.startBlock, latestProcessedBlock =>
      latestProcessedBlock + 1
    )

  logger->Logging.childTrace({
    "msg": "Starting fetching events for chain.",
    "startBlock": startBlock,
    "latestProcessedBlock": latestProcessedBlock,
  })

  //Add all dynamic contracts from DB
  let dynamicContracts =
    await DbFunctions.sql->DbFunctions.DynamicContractRegistry.readDynamicContractsOnChainIdAtOrBeforeBlock(
      ~chainId=chainConfig.chainId,
      ~startBlock,
    )

  dynamicContracts->Belt.Array.forEach(({contractType, contractAddress}) =>
    contractAddressMapping->ContractAddressingMap.addAddress(
      ~name=contractType,
      ~address=contractAddress,
    )
  )

  await self->startWorker(~fetchedEventQueue, ~logger, ~startBlock, ~checkHasReorgOccurred)

  self.hasStoppedFetchingCallBack()
}

let addNewRangeQueriedCallback = (self: t): promise<unit> => {
  self.newRangeQueriedCallBacks->ChainEventQueue.insertCallbackAwaitPromise
}

let getLatestFetchedBlockTimestamp = (self: t) => self.latestFetchedBlockTimestamp

let fetchArbitraryEvents = async (
  self: t,
  ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ~fromBlock,
  ~fromLogIndex,
  ~toBlock,
  ~logger,
) => {
  logger->Logging.childTrace({
    "message": "Fetching Arbitrary Events",
    "contracts": dynamicContracts,
    "fromBlock": fromBlock,
    "fromLogIndex": fromLogIndex,
    "toBlock": toBlock,
  })

  let contractInterfaceManager =
    dynamicContracts
    ->Belt.Array.map(({contractAddress, contractType, chainId}) => {
      let chainConfig = switch Config.config->Js.Dict.get(chainId->Belt.Int.toString) {
      | None =>
        let exn = UndefinedChainConfig(chainId)
        logger->Logging.childErrorWithExn(exn, "Could not find chain config for given ChainId")
        exn->raise
      | Some(c) => c
      }

      let singleContractInterfaceManager = ContractInterfaceManager.makeFromSingleContract(
        ~contractAddress,
        ~contractName=contractType,
        ~chainConfig,
      )

      singleContractInterfaceManager
    })
    ->ContractInterfaceManager.combineInterfaceManagers

  //to be populated in queries
  let queueItems: array<Types.eventBatchQueueItem> = []

  let fromBlockRef = ref(fromBlock)

  while fromBlockRef.contents < toBlock {
    let contractAddressesAndtopics =
      contractInterfaceManager->ContractInterfaceManager.getAllContractTopicsAndAddresses

    //fetch batch
    let pageUnsafe = await Helpers.queryLogsPageWithBackoff(
      () =>
        HyperSync.queryLogsPage(
          ~serverUrl=self.serverUrl,
          ~fromBlock=fromBlockRef.contents,
          ~toBlock,
          ~contractAddressesAndtopics,
        ),
      logger,
    )

    let parsedItems =
      await pageUnsafe.items
      //Defer all this parsing into separate deferred callbacks
      //on the macro task queue so that parsing doesn't block the
      //event loop and each parse happens as a macro task. Meaning
      //promise resolves will take priority
      ->Deferred.mapArrayDeferred((item, resolve, reject) => {
        switch Converters.parseEvent(
          ~log=item.log,
          ~blockTimestamp=item.blockTimestamp,
          ~contractInterfaceManager,
          ~chainId=self.chainConfig.chainId,
        ) {
        | Ok(parsed) =>
          let queueItem: Types.eventBatchQueueItem = {
            timestamp: item.blockTimestamp,
            chainId: self.chainConfig.chainId,
            blockNumber: item.log.blockNumber,
            logIndex: item.log.logIndex,
            event: parsed,
          }

          resolve(Some(queueItem))

        | Error(e) => reject(Converters.ParseEventErrorExn(e))
        }
      })
      ->Deferred.asPromise

    parsedItems->Belt.Array.forEach(itemOpt => {
      itemOpt->Belt.Option.map(item => queueItems->Js.Array2.push(item))->ignore
    })

    fromBlockRef := pageUnsafe.nextBlock
  }

  queueItems
}

let getContractAddressMapping = (self: t) => self.contractAddressMapping

let addDynamicContractAndFetchMissingEvents = async (
  self: t,
  ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
  ~fromBlock,
  ~fromLogIndex,
  ~logger,
): array<Types.eventBatchQueueItem> => {
  let {
    pendingPromise: hasNewDynamicContractRegistrationsPendingPromise,
    resolve: hasNewDynamicContractRegistrationsResolve,
  } = Utils.createPromiseWithHandles()

  //Perform registering and updatiing "hasNewDynamicContractRegistrations" inside a lock
  //To avoid race condition where fetcher sees that there are new contracts to register but
  //they are still busy being registered (this would cause an improper batch query with missing
  //addresses from the fetcher) or that the "hasNewDynamicContractRegistrations" state has not been
  //set to true yet but there are infact new registrations and a batch could be processed when it should
  //be discarded
  self.hasNewDynamicContractRegistrations = hasNewDynamicContractRegistrationsPendingPromise

  let unaddedDynamicContracts = dynamicContracts->Belt.Array.keep(({
    contractAddress,
    contractType,
  }) => {
    self.contractAddressMapping->ContractAddressingMap.addAddressIfNotExists(
      ~address=contractAddress,
      ~name=contractType,
    )
  })

  hasNewDynamicContractRegistrationsResolve(true)

  let toBlock = await self.latestFetchedBlockNumber

  logger->Logging.childTrace({
    "message": "Registering dynamic contracts",
    "contracts": dynamicContracts,
    "fromBlock": fromBlock,
    "fromLogIndex": fromLogIndex,
    "toBlock": toBlock,
  })

  await self->fetchArbitraryEvents(
    ~dynamicContracts=unaddedDynamicContracts,
    ~logger,
    ~fromBlock,
    ~fromLogIndex,
    ~toBlock,
  )
}

let getBlockHashes = ({serverUrl}: t) => HyperSync.queryBlockHashes(~serverUrl)

let getCurrentBlockHeight = (self: t) => self.currentBlockHeight
