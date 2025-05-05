open Belt
open RescriptMocha

let populateChainQueuesWithRandomEvents = (~runTime=1000, ~maxBlockTime=15, ()) => {
  let config = RegisterHandlers.registerAllHandlers()
  let allEvents = []
  let numberOfMockEventsCreated = ref(0)

  let chainFetchers = config.chainMap->ChainMap.map(({chain}) => {
    let getCurrentTimestamp = () => {
      let timestampMillis = Js.Date.now()
      // Convert milliseconds to seconds
      Belt.Int.fromFloat(timestampMillis /. 1000.0)
    }
    /// Generates a random number between two ints inclusive
    let getRandomInt = (min, max) => {
      Belt.Int.fromFloat(Js.Math.random() *. float_of_int(max - min + 1) +. float_of_int(min))
    }

    let eventConfigs = [
      (Mock.evmEventConfig(
        ~id="0",
        ~contractName="Gravatar",
        ~isWildcard=true,
      ) :> Internal.eventConfig),
    ]
    let fetcherStateInit: FetchState.t = FetchState.make(
      ~maxAddrInPartition=Env.maxAddrInPartition,
      ~endBlock=None,
      ~staticContracts=Js.Dict.empty(),
      ~eventConfigs,
      ~dynamicContracts=[],
      ~startBlock=0,
      ~chainId=0,
    )

    let fetchState = ref(fetcherStateInit)

    let endTimestamp = getCurrentTimestamp()
    let startTimestamp = endTimestamp - runTime

    let averageBlockTime = getRandomInt(1, maxBlockTime)
    let blockNumberStart = getRandomInt(20, 1000000)

    let averageEventsPerBlock = getRandomInt(1, 3)

    let currentTime = ref(startTimestamp)
    let currentBlockNumber = ref(blockNumberStart)

    while currentTime.contents <= endTimestamp {
      let blockTime = getRandomInt(0, 2 * averageBlockTime)
      let numberOfEventsInBatch = getRandomInt(0, 2 * averageEventsPerBlock)

      for logIndex in 0 to numberOfEventsInBatch {
        let batchItem: Internal.eventItem = {
          timestamp: currentTime.contents,
          chain,
          blockNumber: currentBlockNumber.contents,
          logIndex,
          eventConfig: Utils.magic("Mock eventConfig in ChainManager test"),
          event: `mock event (chainId)${chain->ChainMap.Chain.toString} - (blockNumber)${currentBlockNumber.contents->string_of_int} - (logIndex)${logIndex->string_of_int} - (timestamp)${currentTime.contents->string_of_int}`->Utils.magic,
        }

        allEvents->Js.Array2.push(batchItem)->ignore

        fetchState :=
          fetchState.contents
          ->FetchState.handleQueryResult(
            ~query={
              partitionId: "0",
              fromBlock: 0,
              target: Head,
              selection: {
                dependsOnAddresses: false,
                eventConfigs,
              },
              addressesByContractName: Js.Dict.empty(),
              indexingContracts: fetchState.contents.indexingContracts,
            },
            ~latestFetchedBlock={
              blockNumber: batchItem.blockNumber,
              blockTimestamp: batchItem.timestamp,
            },
            ~reversedNewItems=[batchItem],
            ~currentBlockHeight=currentBlockNumber.contents,
          )
          ->Result.getExn

        numberOfMockEventsCreated := numberOfMockEventsCreated.contents + 1
      }

      currentTime := currentTime.contents + blockTime
      currentBlockNumber := currentBlockNumber.contents + 1
    }

    let chainConfig = config.defaultChain->Option.getUnsafe
    let mockChainFetcher: ChainFetcher.t = {
      timestampCaughtUpToHeadOrEndblock: None,
      dbFirstEventBlockNumber: None,
      latestProcessedBlock: None,
      numEventsProcessed: 0,
      numBatchesFetched: 0,
      startBlock: 0,
      fetchState: fetchState.contents,
      logger: Logging.getLogger(),
      sourceManager: SourceManager.make(
        ~sources=chainConfig.sources,
        ~maxPartitionConcurrency=Env.maxPartitionConcurrency,
      ),
      chainConfig,
      // This is quite a hack - but it works!
      lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.empty(
        ~confirmedBlockThreshold=200,
      ),
      currentBlockHeight: 0,
      processingFilters: None,
    }

    mockChainFetcher
  })

  (
    {
      ChainManager.chainFetchers,
      isUnorderedMultichainMode: false,
      isInReorgThreshold: false,
    },
    numberOfMockEventsCreated.contents,
    allEvents,
  )
}

describe("ChainManager", () => {
  //Test was previously popBlockBatchItems
  describe("createBatch", () => {
    it(
      "when processing through many randomly generated events on different queues, the grouping and ordering is correct",
      () => {
        let (
          mockChainManager,
          numberOfMockEventsCreated,
          _allEvents,
        ) = populateChainQueuesWithRandomEvents()

        let defaultFirstEvent: Internal.eventItem = {
          timestamp: 0,
          chain: MockConfig.chain1,
          blockNumber: 0,
          logIndex: 0,
          eventConfig: Utils.magic("Mock eventConfig in ChainManager test"),
          event: `mock initial event`->Utils.magic,
        }

        let numberOfMockEventsReadFromQueues = ref(0)
        let allEventsRead = []
        let rec testThatCreatedEventsAreOrderedCorrectly = (chainManager, lastEvent) => {
          let eventsInBlock = ChainManager.createBatch(
            chainManager,
            ~maxBatchSize=10000,
            ~onlyBelowReorgThreshold=false,
          )

          // ensure that the events are ordered correctly
          switch eventsInBlock {
          | {items: []} => chainManager
          | {items, fetchStatesMap} =>
            items->Belt.Array.forEach(
              i => {
                let _ = allEventsRead->Js.Array2.push(i)
              },
            )
            let batchSize = items->Array.length
            numberOfMockEventsReadFromQueues :=
              numberOfMockEventsReadFromQueues.contents + batchSize

            let firstEventInBlock = items[0]->Option.getExn

            Assert.equal(
              firstEventInBlock->ChainManager.ExposedForTesting_Hidden.getComparitorFromItem >
                lastEvent->ChainManager.ExposedForTesting_Hidden.getComparitorFromItem,
              true,
              ~message="Check that first event in this block group is AFTER the last event before this block group",
            )

            //Note -> this test was originally for popping all events related to a single block
            //Now we don't guarentee processing all events in a block so these assertions are no longer needed.
            // let lastEvent =
            //   batch
            //   ->List.toArray
            //   ->Belt.Array.sliceToEnd(1)
            //   ->Belt.Array.reduce(
            //     firstEventInBlock,
            //     (previous, current) => {
            //       // Assert.equal(
            //       //   previous.blockNumber,
            //       //   current.blockNumber,
            //       //   ~message=`The block number within a block should always be the same, here ${previous.blockNumber->string_of_int} (previous.blockNumber) != ${current.blockNumber->string_of_int}(current.blockNumber)`,
            //       // )
            //
            //       Assert.equal(
            //         previous.chain,
            //         current.chain,
            //         ~message=`The chainId within a block should always be the same, here ${previous.chain->ChainMap.Chain.toString} (previous.chainId) != ${current.chain->ChainMap.Chain.toString}(current.chainId)`,
            //       )
            //
            //       Assert.equal(
            //         current.logIndex > previous.logIndex,
            //         true,
            //         ~message=`Incorrect log index, the offending event pair: ${current.event->Utils.magic} - ${previous.event->Utils.magic}`,
            //       )
            //       current
            //     },
            //   )
            let nextChainFetchers = chainManager.chainFetchers->ChainMap.mapWithKey(
              (chain, fetcher) => {
                let {fetchState} = fetchStatesMap->ChainMap.get(chain)
                {
                  ...fetcher,
                  fetchState,
                }
              },
            )

            let nextChainManager: ChainManager.t = {
              ...chainManager,
              chainFetchers: nextChainFetchers,
            }
            testThatCreatedEventsAreOrderedCorrectly(nextChainManager, lastEvent)
          }
        }

        let finalChainManager = testThatCreatedEventsAreOrderedCorrectly(
          mockChainManager,
          defaultFirstEvent,
        )

        // Test that no events were missed
        let amountStillOnQueues =
          finalChainManager.chainFetchers
          ->ChainMap.values
          ->Belt.Array.reduce(
            0,
            (accum, val) => {
              accum + val.fetchState->FetchState.queueSize
            },
          )

        Assert.equal(
          amountStillOnQueues + numberOfMockEventsReadFromQueues.contents,
          numberOfMockEventsCreated,
          ~message="There were a different number of events created to what was recieved from the queues.",
        )
      },
    )
  })
})

// NOTE: this is likely a temporary feature - can delete if feature no longer important.
describe("determineNextEvent", () => {
  describe("optimistic-unordered-mode", () => {
    let determineNextEvent_unordered = ChainManager.ExposedForTesting_Hidden.createDetermineNextEventFunction(
      ~isUnorderedMultichainMode=true,
      _,
      ~onlyBelowReorgThreshold=false,
    )
    let determineNextEvent_ordered = ChainManager.ExposedForTesting_Hidden.createDetermineNextEventFunction(
      ~isUnorderedMultichainMode=false,
      _,
      ~onlyBelowReorgThreshold=false,
    )

    let makeNoItem = timestamp => FetchState.NoItem({
      latestFetchedBlock: {blockTimestamp: timestamp, blockNumber: 0},
    })
    let makeMockQItem = (timestamp, chain): Internal.eventItem => {
      {
        timestamp,
        chain,
        blockNumber: 987654,
        logIndex: 123456,
        eventConfig: Utils.magic("Mock eventConfig in ChainManager test"),
        event: "SINGLE TEST EVENT"->Utils.magic,
      }
    }

    let makeMockFetchState = (~latestFetchedBlockTimestamp, ~item): FetchState.t => {
      let normalSelection: FetchState.selection = {
        dependsOnAddresses: true,
        eventConfigs: [
          (Mock.evmEventConfig(~id="0", ~contractName="MockContract") :> Internal.eventConfig),
        ],
      }
      let partition: FetchState.partition = {
        id: "0",
        latestFetchedBlock: {
          blockTimestamp: latestFetchedBlockTimestamp,
          blockNumber: 0,
        },
        status: {
          fetchingStateId: None,
        },
        selection: normalSelection,
        addressesByContractName: Js.Dict.empty(),
        fetchedEventQueue: item->Option.mapWithDefault([], v => [v]),
      }
      {
        partitions: [partition],
        maxAddrInPartition: 5,
        nextPartitionIndex: 1,
        queueSize: 10,
        latestFullyFetchedBlock: {
          blockTimestamp: latestFetchedBlockTimestamp,
          blockNumber: 0,
        },
        endBlock: None,
        isFetchingAtHead: false,
        firstEventBlockNumber: item->Option.map(v => v.blockNumber),
        normalSelection,
        chainId: 0,
        indexingContracts: Js.Dict.empty(),
      }
    }

    let makeMockPartitionedFetchState = (
      ~latestFetchedBlockTimestamp,
      ~item,
    ): ChainManager.fetchStateWithData => {
      {
        fetchState: makeMockFetchState(~latestFetchedBlockTimestamp, ~item),
        currentBlockHeight: 700,
        heighestBlockBelowThreshold: 500,
      }
    }

    it(
      "should always take an event if there is one, even if other chains haven't caught up",
      () => {
        let singleItem = makeMockQItem(654, MockConfig.chain137)
        let earliestItem = makeNoItem(5) /* earlier timestamp than the test event */

        let fetchStatesMap = RegisterHandlers.registerAllHandlers().chainMap->ChainMap.mapWithKey(
          (chain, _) =>
            switch chain->ChainMap.Chain.toChainId {
            | 1 =>
              makeMockPartitionedFetchState(
                ~latestFetchedBlockTimestamp=5,
                ~item=None,
              ) /* earlier timestamp than the test event */
            | 137 =>
              makeMockPartitionedFetchState(~latestFetchedBlockTimestamp=5, ~item=Some(singleItem))
            | 1337 | 100 =>
              makeMockPartitionedFetchState(~latestFetchedBlockTimestamp=655, ~item=None)
            | _ => Js.Exn.raiseError("Unexpected chain")
            },
        )

        let {val: {earliestEvent}} = determineNextEvent_unordered(fetchStatesMap)->Result.getExn

        Assert.deepEqual(
          earliestEvent->FetchState_test.getItem,
          Some(singleItem),
          ~message="Should have taken the single item",
        )

        let {val: {earliestEvent}} = determineNextEvent_ordered(fetchStatesMap)->Result.getExn

        Assert.deepEqual(
          earliestEvent,
          earliestItem,
          ~message="Should return the `NoItem` that is earliest since it is earlier than the `Item`",
        )
      },
    )
    it(
      "should always take the lower of two events if there are any, even if other chains haven't caught up",
      () => {
        let earliestItemTimestamp = 653
        let singleItemTimestamp = 654
        let singleItem = makeMockQItem(singleItemTimestamp, MockConfig.chain137)

        let fetchStatesMap = RegisterHandlers.registerAllHandlers().chainMap->ChainMap.mapWithKey(
          (chain, _) =>
            switch chain->ChainMap.Chain.toChainId {
            | 1 =>
              makeMockPartitionedFetchState(
                ~latestFetchedBlockTimestamp=earliestItemTimestamp,
                ~item=None,
              ) /* earlier timestamp than the test event */
            | 137 =>
              makeMockPartitionedFetchState(
                ~latestFetchedBlockTimestamp=singleItemTimestamp,
                ~item=Some(singleItem),
              )
            | 1337 | 100 =>
              let higherTS = singleItemTimestamp + 1
              makeMockPartitionedFetchState(
                ~latestFetchedBlockTimestamp=higherTS,
                ~item=Some(makeMockQItem(higherTS, chain)),
              )
            | _ => Js.Exn.raiseError("Unexpected chain")
            },
        )

        // let example: array<ChainFetcher.eventQueuePeek> = [
        //   earliestItem,
        //   NoItem(653 /* earlier timestamp than the test event */, {id:1}),
        //   Item({...singleItem, timestamp: singleItem.timestamp + 1}),
        //   Item(singleItem),
        //   NoItem(655 /* later timestamp than the test event */, {id:1}),
        // ]

        let {val: {earliestEvent}} = determineNextEvent_unordered(fetchStatesMap)->Result.getExn

        Assert.deepEqual(
          earliestEvent->FetchState_test.getItem,
          Some(singleItem),
          ~message="Should have taken the single item",
        )

        let {val: {earliestEvent}} = determineNextEvent_ordered(fetchStatesMap)->Result.getExn

        Assert.deepEqual(
          earliestEvent,
          makeNoItem(earliestItemTimestamp),
          ~message="Should return the `NoItem` that is earliest since it is earlier than the `Item`",
        )
      },
    )
  })
})
