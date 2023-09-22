  type rec t = {
    mutable latestFetchedBlockTimestamp: int,
    chainId: int,
    newRangeQueriedCallBacks: SDSL.Queue.t<unit => unit>,
    contractAddressMapping: ContractAddressingMap.mapping,
    caughtUpToHeadHook: option<t => promise<unit>>,
  }

  let stopFetchingEvents = (self: t) => {
    Promise.resolve()
  }

  let make = (~caughtUpToHeadHook=?, chainConfig: Config.chainConfig) => {
    let contractAddressMapping = ContractAddressingMap.make()
    let logger = Logging.createChild(
      ~params={
        "chainId": chainConfig.chainId,
        "workerType": "Raw Events",
        "loggerFor": "Used only in logging regestration of static contract addresses",
      },
    )
    //Add all contracts and addresses from config
    //Dynamic contracts are checked in DB on start
    contractAddressMapping->ContractAddressingMap.registerStaticAddresses(~chainConfig, ~logger)
    {
      latestFetchedBlockTimestamp: 0,
      chainId: chainConfig.chainId,
      newRangeQueriedCallBacks: SDSL.Queue.make(),
      contractAddressMapping,
      caughtUpToHeadHook,
    }
  }

  let startFetchingEvents = async (
    self: t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
  ) => {
    let eventIdRef = ref(0->Ethers.BigInt.fromInt)

    //TODO: make configurable
    let pageLimitSize = 50_000

    //chainId
    let hasMoreRawEvents = ref(true)

    while hasMoreRawEvents.contents {
      let page =
        await DbFunctions.sql->DbFunctions.RawEvents.getRawEventsPageGtOrEqEventId(
          ~chainId=self.chainId,
          ~eventId=eventIdRef.contents,
          ~limit=pageLimitSize,
        )

      let parsedEventsUnsafe =
        page->Belt.Array.map(Converters.parseRawEvent)->Utils.mapArrayOfResults->Belt.Result.getExn

      for i in 0 to parsedEventsUnsafe->Belt.Array.length - 1 {
        let parsedEvent = parsedEventsUnsafe[i]

        let queueItem: Types.eventBatchQueueItem = {
          timestamp: parsedEvent.timestamp,
          chainId: self.chainId,
          blockNumber: parsedEvent.blockNumber,
          logIndex: parsedEvent.logIndex,
          event: parsedEvent.event,
        }

        await fetchedEventQueue->ChainEventQueue.awaitQueueSpaceAndPushItem(queueItem)

        //Loop through any callbacks on the queue waiting for confirmation of a new
        //range queried and run callbacks needs to happen after each item is added
        //else this we could be blocked from adding items to the queue and from popping
        //items off without running callbacks
        self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())
      }

      let lastItemInPage = page->Belt.Array.get(page->Belt.Array.length - 1)

      switch lastItemInPage {
      | None => hasMoreRawEvents := false
      | Some(item) =>
        let lastEventId = item.eventId->Ethers.BigInt.fromStringUnsafe
        eventIdRef := lastEventId->Ethers.BigInt.add(1->Ethers.BigInt.fromInt)
        self.latestFetchedBlockTimestamp = item.blockTimestamp
      }
    }

    //Loop through any callbacks on the queue waiting for confirmation of a new
    //range queried and run callbacks
    self.newRangeQueriedCallBacks->SDSL.Queue.popForEach(callback => callback())

    await self.caughtUpToHeadHook->Belt.Option.mapWithDefault(Promise.resolve(), hook => hook(self))
  }

  let addNewRangeQueriedCallback = (self: t): promise<unit> => {
    self.newRangeQueriedCallBacks->ChainEventQueue.insertCallbackAwaitPromise
  }

  let getLatestFetchedBlockTimestamp = (self: t): int => self.latestFetchedBlockTimestamp

  let addDynamicContractAndFetchMissingEvents = async (
    self: t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock,
    ~fromLogIndex,
    ~logger,
  ): array<Types.eventBatchQueueItem> => {
    let _unaddedDynamicContracts =
      dynamicContracts->Belt.Array.keep(({contractType, contractAddress}) =>
        self.contractAddressMapping->ContractAddressingMap.addAddressIfNotExists(
          ~name=contractType,
          ~address=contractAddress,
        )
      )

    //Return empty array since raw events worker has already retrieved
    //dynamically registered contracts
    []
  }

