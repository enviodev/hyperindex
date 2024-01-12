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

  type getNextPageRes = {
    contractInterfaceManager: ContractInterfaceManager.t,
    page: HyperSyncTypes.logsQueryPage,
    pageFetchTime: int,
  }

  let startWorker = async (self: t, ~startBlock, ~logger, ~fetchedEventQueue) => {
    logger->Logging.childInfo("Hypersync worker starting")
    let {chainConfig, contractAddressMapping, serverUrl} = self
    let initialHeight = await HyperSync.getHeightWithRetry(~serverUrl=self.serverUrl, ~logger)

    let currentHeight = ref(initialHeight)
    let fromBlock = ref(startBlock)

    DbFunctions.ChainMetadata.setChainMetadataRow(
      ~chainId=chainConfig.chainId,
      ~startBlock,
      ~blockHeight=initialHeight,
    )->ignore

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

        DbFunctions.ChainMetadata.setChainMetadataRow(
          ~chainId=chainConfig.chainId,
          ~startBlock,
          ~blockHeight=currentHeight.contents,
        )->ignore
      }
      true
    }

    let getNextPage = async () => {
      //Wait for a valid range to query
      let _ = await checkReadyToContinue()
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
            ~fromBlock=fromBlock.contents,
            ~toBlock=currentHeight.contents,
            ~contractAddressesAndtopics,
          ),
        logger,
      )

      let pageFetchTime =
        startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

      {page: pageUnsafe, contractInterfaceManager, pageFetchTime}
    }

    let initialPagePromise = getNextPage()

    let nextPagePromise = ref(initialPagePromise)

    while self.shouldContinueFetching {
      let startFetchingBatchTimeRef = Hrtime.makeTimer()
      //fetch batch
      let {
        page: pageUnsafe,
        contractInterfaceManager,
        pageFetchTime,
      } = await nextPagePromise.contents

      let currentBatchFromBlock = fromBlock.contents

      //set height and next from block
      if pageUnsafe.archiveHeight > currentHeight.contents {
        DbFunctions.ChainMetadata.setChainMetadataRow(
          ~chainId=chainConfig.chainId,
          ~startBlock,
          ~blockHeight=pageUnsafe.archiveHeight,
        )->ignore

        currentHeight := pageUnsafe.archiveHeight
      }

      fromBlock := pageUnsafe.nextBlock

      //Start fetching next page async before parsing current page
      nextPagePromise := getNextPage()

      logger->Logging.childTrace({
        "message": "Retrieved event page from server",
        "fromBlock": currentBatchFromBlock,
        "toBlock": pageUnsafe.nextBlock - 1,
        "number of logs": pageUnsafe.items->Array.length,
      })

      //The heighest (biggest) blocknumber that was accounted for in
      //Our query. Not necessarily the blocknumber of the last log returned
      //In the query
      let heighestBlockQueried = pageUnsafe.nextBlock - 1

      //Helper function to fetch the timestamp of the heighest block queried
      //In the case that it is unknown
      let getHeighestBlockAndTimestampWithDefault = (
        ~default: HyperSyncTypes.blockNumberAndTimestamp,
      ) => {
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
        ->Belt.Option.map((item): HyperSyncTypes.blockNumberAndTimestamp => {
          blockNumber: item.log.blockNumber,
          timestamp: item.blockTimestamp,
        })

      let heighestBlockQueriedPromise: promise<
        HyperSyncTypes.blockNumberAndTimestamp,
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
            timestamp: self.latestFetchedBlockTimestamp,
          },
        )
      }

      if await self.hasNewDynamicContractRegistrations {
        //If there are new dynamic contract registrations
        //discard this batch and redo the query with new address
        self.hasNewDynamicContractRegistrations = Promise.resolve(false)

        logger->Logging.childTrace({
          "message": "Dropping invalid batch due to new dynamic contract registration",
          "page fetch time elapsed (ms)": pageFetchTime,
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
              ~chainId=self.chainConfig.chainId,
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
        let {
          blockNumber: heighestQueriedBlockNumber,
          timestamp: heighestQueriedBlockTimestamp,
        } = await heighestBlockQueriedPromise

        self.latestFetchedBlockTimestamp = heighestQueriedBlockTimestamp
        latestBlockNumbersResolve(heighestQueriedBlockNumber)

        //Loop through any callbacks on the queue waiting for confirmation of a new
        //range queried and run callbacks since there will be an updated timestamp even
        //If there ar no items in the page
        self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())

        let totalTimeElapsed =
          startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

        logger->Logging.childTrace({
          "message": "Finished page range",
          "fromBlock": currentBatchFromBlock,
          "toBlock": await self.latestFetchedBlockNumber,
          "total time elapsed (ms)": totalTimeElapsed,
          "page fetch time (ms)": pageFetchTime,
          "parsing time (ms)": parsingTimeElapsed,
          "average parse time per log (ms)": parsingTimeElapsed->Belt.Int.toFloat /.
            parsedQueueItems->Array.length->Belt.Int.toFloat,
          "push to queue time (ms)": queuePushingTimeElapsed,
        })
      }
    }
  }

  let startFetchingEvents = async (
    self: t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => {
    logger->Logging.childTrace("Starting event fetching on Skar worker")

    let {chainConfig, contractAddressMapping} = self
    let latestProcessedBlock = await DbFunctions.EventSyncState.getLatestProcessedBlockNumber(
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

    await self->startWorker(~fetchedEventQueue, ~logger, ~startBlock)

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
}
