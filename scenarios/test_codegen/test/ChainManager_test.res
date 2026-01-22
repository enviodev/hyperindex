open Belt
open RescriptMocha

let populateChainQueuesWithRandomEvents = (~runTime=1000, ~maxBlockTime=15, ()) => {
  let config = Generated.configWithoutRegistrations
  let allEvents = []
  let numberOfMockEventsCreated = ref(0)

  let chainFetchers = config.chainMap->ChainMap.map(({id}) => {
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
      ~eventConfigs,
      ~contracts=[],
      ~startBlock=0,
      ~targetBufferSize=5000,
      ~chainId=1,
      ~knownHeight=0,
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
        let batchItem = Internal.Event({
          timestamp: currentTime.contents,
          chain: ChainMap.Chain.makeUnsafe(~chainId=id),
          blockNumber: currentBlockNumber.contents,
          logIndex,
          eventConfig: Utils.magic("Mock eventConfig in ChainManager test"),
          event: `mock event (chainId)${id->Int.toString} - (blockNumber)${currentBlockNumber.contents->string_of_int} - (logIndex)${logIndex->string_of_int} - (timestamp)${currentTime.contents->string_of_int}`->Utils.magic,
        })
        let eventItem = batchItem->Internal.castUnsafeEventItem

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
              blockNumber: eventItem.blockNumber,
              blockTimestamp: eventItem.timestamp,
            },
            ~newItems=[batchItem],
          )
          ->Result.getExn

        numberOfMockEventsCreated := numberOfMockEventsCreated.contents + 1
      }

      currentTime := currentTime.contents + blockTime
      currentBlockNumber := currentBlockNumber.contents + 1
    }

    let chainConfig = config.defaultChain->Option.getUnsafe
    // For this test we don't need real sources - just testing ChainManager event ordering
    // Create a mock source that satisfies SourceManager requirements (chain ID doesn't matter here)
    let mockSource = Mock.Source.make([], ~chain=#1)
    let sources = [mockSource.source]
    let mockChainFetcher: ChainFetcher.t = {
      timestampCaughtUpToHeadOrEndblock: None,
      firstEventBlockNumber: None,
      committedProgressBlockNumber: -1,
      numEventsProcessed: 0,
      numBatchesFetched: 0,
      fetchState: fetchState.contents,
      logger: Logging.getLogger(),
      sourceManager: SourceManager.make(
        ~sources,
        ~maxPartitionConcurrency=Env.maxPartitionConcurrency,
      ),
      chainConfig,
      // This is quite a hack - but it works!
      reorgDetection: ReorgDetection.make(
        ~chainReorgCheckpoints=[],
        ~maxReorgDepth=200,
        ~shouldRollbackOnReorg=false,
      ),
      safeCheckpointTracking: None,
      isProgressAtHead: false,
    }

    mockChainFetcher
  })

  (
    {
      ChainManager.chainFetchers,
      multichain: Ordered,
      committedCheckpointId: 0.,
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

        let defaultFirstEvent = Internal.Event({
          timestamp: 0,
          chain: MockConfig.chain1,
          blockNumber: 0,
          logIndex: 0,
          eventConfig: Utils.magic("Mock eventConfig in ChainManager test"),
          event: `mock initial event`->Utils.magic,
        })

        let numberOfMockEventsReadFromQueues = ref(0)
        let allEventsRead = []
        let rec testThatCreatedEventsAreOrderedCorrectly = (chainManager, lastEvent) => {
          let {items, totalBatchSize, progressedChainsById} = ChainManager.createBatch(
            chainManager,
            ~batchSizeTarget=10000,
            ~isRollback=false,
          )

          // ensure that the events are ordered correctly
          if totalBatchSize === 0 {
            chainManager
          } else {
            items->Array.forEach(
              item => {
                allEventsRead->Js.Array2.push(item)->ignore
              },
            )
            numberOfMockEventsReadFromQueues :=
              numberOfMockEventsReadFromQueues.contents + totalBatchSize

            let firstEventInBlock = items[0]->Option.getExn

            Assert.equal(
              firstEventInBlock->EventUtils.getOrderedBatchItemComparator >
                lastEvent->EventUtils.getOrderedBatchItemComparator,
              true,
              ~message="Check that first event in this block group is AFTER the last event before this block group",
            )

            let nextChainFetchers = chainManager.chainFetchers->ChainMap.mapWithKey(
              (chain, fetcher) => {
                let fetchState = switch progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(
                  chain->ChainMap.Chain.toChainId,
                ) {
                | Some(chainAfterBatch) => chainAfterBatch.fetchState
                | None => fetcher.fetchState
                }
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
              accum + val.fetchState->FetchState.bufferSize
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

  describe("unordered batch progress", () => {
    it(
      "when one chain fills the batch, other chains without items still get their progress updated",
      () => {
        // Create two chains: one with many events, one with no events
        let config = Generated.configWithoutRegistrations
        let eventConfigs = [
          (Mock.evmEventConfig(
            ~id="0",
            ~contractName="Gravatar",
            ~isWildcard=true,
          ) :> Internal.eventConfig),
        ]

        let chainConfig = config.defaultChain->Option.getUnsafe

        // Chain 1: has 100 events
        let fetchState1 = FetchState.make(
          ~maxAddrInPartition=Env.maxAddrInPartition,
          ~endBlock=None,
          ~eventConfigs,
          ~contracts=[],
          ~startBlock=0,
          ~targetBufferSize=5000,
          ~chainId=1,
          ~knownHeight=1000,
        )

        // Add 100 events to chain 1
        let events1 = Array.makeBy(100, i => {
          Internal.Event({
            timestamp: 100 + i,
            chain: ChainMap.Chain.makeUnsafe(~chainId=1),
            blockNumber: 100 + i,
            logIndex: 0,
            eventConfig: Utils.magic("Mock eventConfig"),
            event: `mock event chain1 block ${(100 + i)->Int.toString}`->Utils.magic,
          })
        })

        let fetchState1WithEvents =
          fetchState1
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
              indexingContracts: fetchState1.indexingContracts,
            },
            ~latestFetchedBlock={blockNumber: 1000, blockTimestamp: 1000},
            ~newItems=events1,
          )
          ->Result.getExn

        // Chain 137 (polygon): no events, but has fetched up to block 1000
        let fetchState137 = FetchState.make(
          ~maxAddrInPartition=Env.maxAddrInPartition,
          ~endBlock=None,
          ~eventConfigs,
          ~contracts=[],
          ~startBlock=0,
          ~targetBufferSize=5000,
          ~chainId=137,
          ~knownHeight=1000,
        )

        // Update chain 137 to have fetched up to block 1000 but with no events
        let fetchState137WithNoEvents =
          fetchState137
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
              indexingContracts: fetchState137.indexingContracts,
            },
            ~latestFetchedBlock={blockNumber: 1000, blockTimestamp: 1000},
            ~newItems=[],
          )
          ->Result.getExn

        // Create mock chain fetchers
        let mockSource1 = Mock.Source.make([], ~chain=#1)
        let mockSource137 = Mock.Source.make([], ~chain=#137)

        let makeChainFetcher = (~fetchState, ~source) => {
          (
            {
              ChainFetcher.timestampCaughtUpToHeadOrEndblock: None,
              firstEventBlockNumber: None,
              committedProgressBlockNumber: -1,
              numEventsProcessed: 0,
              numBatchesFetched: 0,
              fetchState,
              logger: Logging.getLogger(),
              sourceManager: SourceManager.make(
                ~sources=[source.Mock.Source.source],
                ~maxPartitionConcurrency=Env.maxPartitionConcurrency,
              ),
              chainConfig,
              reorgDetection: ReorgDetection.make(
                ~chainReorgCheckpoints=[],
                ~maxReorgDepth=200,
                ~shouldRollbackOnReorg=false,
              ),
              safeCheckpointTracking: None,
              isProgressAtHead: false,
            }: ChainFetcher.t
          )
        }

        let chainFetcher1 = makeChainFetcher(
          ~fetchState=fetchState1WithEvents,
          ~source=mockSource1,
        )
        let chainFetcher137 = makeChainFetcher(
          ~fetchState=fetchState137WithNoEvents,
          ~source=mockSource137,
        )

        let chainFetchers = ChainMap.fromArrayUnsafe([
          (MockConfig.chain1, chainFetcher1),
          (MockConfig.chain137, chainFetcher137),
        ])

        let chainManager: ChainManager.t = {
          chainFetchers,
          multichain: Unordered,
          committedCheckpointId: 0.,
          isInReorgThreshold: false,
        }

        // Create a batch with size target of 10 (smaller than chain 1's 100 events)
        let {progressedChainsById} = ChainManager.createBatch(
          chainManager,
          ~batchSizeTarget=10,
          ~isRollback=false,
        )

        // Chain 1 should be in progressedChainsById (it had items)
        let chain1Progress = progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(1)
        Assert.equal(
          chain1Progress->Option.isSome,
          true,
          ~message="Chain 1 should be in progressedChainsById",
        )

        // Chain 137 should ALSO be in progressedChainsById even though it had no items
        // This is the bug fix - previously chains that weren't processed because the batch
        // was full wouldn't have their progress updated
        let chain137Progress = progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(137)
        Assert.equal(
          chain137Progress->Option.isSome,
          true,
          ~message="Chain 137 should be in progressedChainsById even though it had no items (fix for multichain live indexing bug)",
        )

        // Chain 137's progress should be at its bufferBlockNumber (1000)
        switch chain137Progress {
        | Some(progress) =>
          Assert.equal(
            progress.progressBlockNumber,
            1000,
            ~message="Chain 137 progress should be at block 1000",
          )
        | None => ()
        }
      },
    )
  })
})
