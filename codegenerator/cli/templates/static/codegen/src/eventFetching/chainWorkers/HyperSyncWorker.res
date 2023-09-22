open ChainWorkerTypes
module Make = (HyperSync: HyperSync.S) => {
  type rec t = {
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
      query: unit => promise<HyperSyncTypes.queryResponse<HyperSyncTypes.logsQueryPage>>,
      logger: Pino.t,
    ) =>
      switch await query() {
      | Error(e) =>
        let msg = e->HyperSyncTypes.queryErrorToMsq
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

  let make = (~caughtUpToHeadHook=?, chainConfig: Config.chainConfig): t => {
    let caughtUpToHeadHook = switch caughtUpToHeadHook {
    | None => (_self: t) => Promise.resolve()
    | Some(hook) => hook
    }

    let contractAddressMapping = ContractAddressingMap.make()
    let logger = Logging.createChild(
      ~params={
        "chainId": chainConfig.chainId,
        "workerType": "Hypersync",
        "loggerFor": "Used only in logging regestration of static contract addresses",
      },
    )
    //Add all contracts and addresses from config
    //Dynamic contracts are checked in DB on start
    contractAddressMapping->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)

    let serverUrl = switch chainConfig.syncSource {
    | EthArchive(serverUrl)
    | Skar(serverUrl) => serverUrl
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

  let startFetchingEvents = async (
    self: t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => {
    logger->Logging.childTrace("Starting event fetching on Skar worker")

    let {chainConfig, contractAddressMapping, serverUrl} = self
    let latestProcessedBlock = await DbFunctions.RawEvents.getLatestProcessedBlockNumber(
      ~chainId=chainConfig.chainId,
    )

    let startBlock =
      latestProcessedBlock->Belt.Option.mapWithDefault(
        chainConfig.startBlock,
        latestProcessedBlock => latestProcessedBlock + 1,
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

    let initialHeight = await HyperSync.getHeightWithRetry(~serverUrl=self.serverUrl, ~logger)

    let currentHeight = ref(initialHeight)
    let fromBlock = ref(startBlock)

    let checkReadyToContinue = async () => {
      if fromBlock.contents >= currentHeight.contents {
        logger->Logging.childTrace("Worker is caught up, awaiting new blocks")
        //If the block we want to query from is greater than the current height,
        //poll for until the archive height is greater than the from block and set
        //current height to the new height
        currentHeight :=
          (
            await HyperSync.pollForHeightGtOrEq(
              ~serverUrl=self.serverUrl,
              ~blockNumber=fromBlock.contents,
              ~logger,
            )
          )
      }
      true
    }

    while (await checkReadyToContinue()) && self.shouldContinueFetching {
      //Instantiate each time to add new registered contract addresses
      let contractInterfaceManager = ContractInterfaceManager.make(
        ~chainConfig,
        ~contractAddressMapping,
      )

      let {addresses, topics} =
        contractInterfaceManager->ContractInterfaceManager.getAllTopicsAndAddresses

      //Just the topics of the event signature and no topics related
      //to indexed parameters
      let topLevelTopics = [topics]

      let startFetchingBatchTimeRef = Hrtime.makeTimer()

      //fetch batch
      let pageUnsafe = await Helpers.queryLogsPageWithBackoff(
        () =>
          HyperSync.queryLogsPage(
            ~serverUrl,
            ~fromBlock=fromBlock.contents,
            ~toBlock=currentHeight.contents,
            ~addresses,
            ~topics=topLevelTopics,
          ),
        logger,
      )

      let elapsedTimeFetchingPage =
        startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

      logger->Logging.childTrace({
        "message": "Retrieved event page from server",
        "fromBlock": fromBlock.contents,
        "toBlock": pageUnsafe.nextBlock - 1,
        "number of logs": pageUnsafe.items->Array.length,
      })

      //Start query for heighest block queried to get latest timestamp
      let heighestBlockQueried = pageUnsafe.archiveHeight - 1
      let heighestBlockQueriedPagePromise = HyperSync.queryBlockTimestampsPage(
        ~serverUrl,
        ~fromBlock=heighestBlockQueried,
        ~toBlock=heighestBlockQueried,
      )

      if await self.hasNewDynamicContractRegistrations {
        //If there are new dynamic contract registrations
        //discard this batch and redo the query with new address
        self.hasNewDynamicContractRegistrations = Promise.resolve(false)

        logger->Logging.childTrace({
          "message": "Dropping invalid batch due to new dynamic contract registration",
          "page fetch time elapsed (ms)": elapsedTimeFetchingPage,
        })
      } else {
        //Lock the latest fetched blockNumber until it gets
        //set with the timestamp later.
        //Lock is to prevent race condition when looking up from dynamic contract registration
        let {
          pendingPromise: latestBlockNumbersPromise,
          resolve: latestBlockNumbersResolve,
        } = Utils.createPromiseWithHandles()
        self.latestFetchedBlockNumber = latestBlockNumbersPromise

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
            ) {
            | Ok(parsed) =>
              let queueItem: Types.eventBatchQueueItem = {
                timestamp: item.blockTimestamp,
                chainId: chainConfig.chainId,
                blockNumber: item.log.blockNumber,
                logIndex: item.log.logIndex,
                event: parsed,
              }
              resolve(queueItem)
            | Error(e) => reject(Converters.ParseEventErrorExn(e))
            }
          })
          ->Deferred.asPromise

        let parsingTimeElapsed =
          parsingTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

        let queuePushingTimeRef = Hrtime.makeTimer()

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
        }

        let queuePushingTimeElapsed =
          queuePushingTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

        //set latestFetchedBlockNumber and latestFetchedBlockTimestamp
        let heighestBlockQueriedPage = await heighestBlockQueriedPagePromise

        //Used in failure case of query
        let fallbackUpdateLatestFetchedValuesToLastInBatch = () => {
          let lastItemInBatch = pageUnsafe.items->Belt.Array.get(pageUnsafe.items->Array.length)
          lastItemInBatch
          ->Belt.Option.map(item => {
            //Set the latest fetched timestamp to the last item in the batch timestamp
            //Note this could be lower than the block we were querying until
            //But its only used in query failure and it will still help unblock chain manager queues
            self.latestFetchedBlockTimestamp = item.blockTimestamp
          })
          ->ignore

          //We know the latest fetched block number since it will be the one before nextBlock
          self.latestFetchedBlockNumber = latestBlockNumbersResolve(pageUnsafe.nextBlock - 1)
        }

        switch heighestBlockQueriedPage {
        | Ok(page) =>
          //Expected only 1 item but just taking last in case things change and we return
          //a range
          let lastBlockInRangeQueried =
            pageUnsafe.items->Belt.Array.get(pageUnsafe.items->Array.length)

          switch lastBlockInRangeQueried {
          | Some(item) =>
            //Set the latest fetched data to the queried block
            self.latestFetchedBlockTimestamp = item.blockTimestamp
            self.latestFetchedBlockNumber = latestBlockNumbersResolve(item.log.blockNumber)
          | None => fallbackUpdateLatestFetchedValuesToLastInBatch()
          }
        | Error(err) => fallbackUpdateLatestFetchedValuesToLastInBatch()
        }
        //Loop through any callbacks on the queue waiting for confirmation of a new
        //range queried and run callbacks since there will be an updated timestamp even
        //If there ar no items in the page
        self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())

        let totalTimeElapsed =
          startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

        logger->Logging.childTrace({
          "message": "Finished page range",
          "fromBlock": fromBlock.contents,
          "toBlock": await self.latestFetchedBlockNumber,
          "total time elapsed (ms)": totalTimeElapsed,
          "page fetch time (ms)": elapsedTimeFetchingPage,
          "parsing time (ms)": parsingTimeElapsed,
          "average parse time per log (ms)": parsingTimeElapsed->Belt.Int.toFloat /.
            parsedQueueItems->Array.length->Belt.Int.toFloat,
          "push to queue time (ms)": queuePushingTimeElapsed,
        })

        //set height and next from block
        currentHeight := pageUnsafe.archiveHeight
        fromBlock := pageUnsafe.nextBlock
      }
    }

    self.hasStoppedFetchingCallBack()
  }

  let addNewRangeQueriedCallback = (self: t): promise<unit> => {
    self.newRangeQueriedCallBacks->ChainEventQueue.insertCallbackAwaitPromise
  }

  let getLatestFetchedBlockTimestamp = (self: t) => self.latestFetchedBlockTimestamp

  let addDynamicContractAndFetchMissingEvents = async (
    self: t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock,
    ~fromLogIndex,
    ~logger,
  ): array<Types.eventBatchQueueItem> => {
    let {serverUrl} = self
    let {pendingPromise, resolve} = Utils.createPromiseWithHandles()

    //Perform registering and updatiing "hasNewDynamicContractRegistrations" inside a lock
    //To avoid race condition where fetcher sees that there are new contracts to register but
    //they are still busy being registered (this would cause an improper batch query with missing
    //addresses from the fetcher) or that the "hasNewDynamicContractRegistrations" state has not been
    //set to true yet but there are infact new registrations and a batch could be processed when it should
    //be discarded
    self.hasNewDynamicContractRegistrations = pendingPromise

    let unaddedDynamicContracts = dynamicContracts->Belt.Array.keep(({
      contractAddress,
      contractType,
      chainId,
    }) => {
      self.contractAddressMapping->ContractAddressingMap.addAddressIfNotExists(
        ~address=contractAddress,
        ~name=contractType,
      )
    })

    self.hasNewDynamicContractRegistrations = resolve(true)

    let contractInterfaceManager =
      unaddedDynamicContracts
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
    let toBlock = await self.latestFetchedBlockNumber

    logger->Logging.childTrace({
      "message": "Registering dynamic contracts",
      "contracts": dynamicContracts,
      "fromBlock": fromBlock,
      "fromLogIndex": fromLogIndex,
      "toBlock": toBlock,
    })

    while fromBlockRef.contents < toBlock {
      let {addresses, topics} =
        contractInterfaceManager->ContractInterfaceManager.getAllTopicsAndAddresses

      //Just the topics of the event signature and no topics related
      //to indexed parameters
      let topLevelTopics = [topics]

      //fetch batch
      let pageUnsafe = await Helpers.queryLogsPageWithBackoff(
        () =>
          HyperSync.queryLogsPage(
            ~serverUrl,
            ~fromBlock=fromBlockRef.contents,
            ~toBlock,
            ~addresses,
            ~topics=topLevelTopics,
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
}
