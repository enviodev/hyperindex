open Vitest

let populateChainQueuesWithRandomEvents = (~runTime=1000, ~maxBlockTime=15, ()) => {
  let config = Config.loadWithoutRegistrations()
  let allEvents = []
  let numberOfMockEventsCreated = ref(0)

  let chainFetchers = config.chainMap->ChainMap.map(({id}) => {
    let getCurrentTimestamp = () => {
      let timestampMillis = Date.now()
      // Convert milliseconds to seconds
      Int.fromFloat(timestampMillis /. 1000.0)
    }
    /// Generates a random number between two ints inclusive
    let getRandomInt = (min, max) => {
      Int.fromFloat(Math.random() *. Int.toFloat(max - min + 1) +. Int.toFloat(min))
    }

    let eventConfigs = [
      (MockIndexer.evmEventConfig(
        ~id="0",
        ~contractName="Gravatar",
        ~isWildcard=true,
      ) :> Internal.eventConfig),
    ]
    let fetcherStateInit: FetchState.t = FetchState.make(
      ~maxAddrInPartition=Env.maxAddrInPartition,
      ~endBlock=None,
      ~eventConfigs,
      ~addresses=[],
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
          blockHash: `0x${currentBlockNumber.contents->Int.toString}`,
          logIndex,
          eventConfig: Utils.magic("Mock eventConfig in ChainManager test"),
          event: `mock event (chainId)${id->Int.toString} - (blockNumber)${currentBlockNumber.contents->Int.toString} - (logIndex)${logIndex->Int.toString} - (timestamp)${currentTime.contents->Int.toString}`->Utils.magic,
        })
        allEvents->Array.push(batchItem)->ignore

        let query: FetchState.query = {
          partitionId: "0",
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          selection: {
            dependsOnAddresses: false,
            eventConfigs,
          },
          addressesByContractName: Dict.make(),
          indexingAddresses: fetchState.contents.indexingAddresses,
        }

        fetchState.contents->FetchState.startFetchingQueries(~queries=[query])

        fetchState :=
          fetchState.contents->FetchState.handleQueryResult(
            ~query,
            ~latestFetchedBlock={
              blockNumber: currentBlockNumber.contents,
              blockTimestamp: currentTime.contents,
            },
            ~newItems=[batchItem],
          )

        numberOfMockEventsCreated := numberOfMockEventsCreated.contents + 1
      }

      currentTime := currentTime.contents + blockTime
      currentBlockNumber := currentBlockNumber.contents + 1
    }

    let chainConfig = config.defaultChain->Option.getUnsafe
    // For this test we don't need real sources - just testing ChainManager event ordering
    // Create a mock source that satisfies SourceManager requirements (chain ID doesn't matter here)
    let mockSource = MockIndexer.Source.make([], ~chain=#1)
    let sources = [mockSource.source]
    let mockChainFetcher: ChainFetcher.t = {
      timestampCaughtUpToHeadOrEndblock: None,
      committedProgressBlockNumber: -1,
      numEventsProcessed: 0.,
      fetchState: fetchState.contents,
      logger: Logging.getLogger(),
      sourceManager: SourceManager.make(
        ~sources,
        ~maxPartitionConcurrency=Env.maxPartitionConcurrency,
        ~isRealtime=false,
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
      isInReorgThreshold: false,
      isRealtime: false,
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
      t => {
        let (
          mockChainManager,
          numberOfMockEventsCreated,
          _allEvents,
        ) = populateChainQueuesWithRandomEvents()

        let defaultFirstEvent = Internal.Event({
          timestamp: 0,
          chain: MockConfig.chain1,
          blockNumber: 0,
          blockHash: "0x0",
          logIndex: 0,
          eventConfig: Utils.magic("Mock eventConfig in ChainManager test"),
          event: `mock initial event`->Utils.magic,
        })

        let numberOfMockEventsReadFromQueues = ref(0)
        let allEventsRead = []
        let rec testThatCreatedEventsAreOrderedCorrectly = (chainManager, lastEvent) => {
          let {items, totalBatchSize, progressedChainsById} = ChainManager.createBatch(
            chainManager,
            ~processedCheckpointId=Internal.initialCheckpointId,
            ~batchSizeTarget=10000,
            ~isRollback=false,
          )

          // ensure that the events are ordered correctly
          if totalBatchSize === 0 {
            chainManager
          } else {
            items->Array.forEach(
              item => {
                allEventsRead->Array.push(item)->ignore
              },
            )
            numberOfMockEventsReadFromQueues :=
              numberOfMockEventsReadFromQueues.contents + totalBatchSize

            let firstEventInBlock = items[0]->Option.getOrThrow

            let getItemKey = (item: Internal.item) =>
              switch item {
              | Event({chain, blockNumber, logIndex}) => (
                  chain->ChainMap.Chain.toChainId,
                  blockNumber,
                  logIndex,
                )
              | Block({onBlockConfig: {chainId}, blockNumber}) => (chainId, blockNumber, 0)
              }
            t.expect(
              firstEventInBlock->getItemKey > lastEvent->getItemKey,
              ~message="Check that first event in this block group is AFTER the last event before this block group",
            ).toBe(true)

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
          ->Array.reduce(
            0,
            (accum, val) => {
              accum + val.fetchState->FetchState.bufferSize
            },
          )

        t.expect(
          amountStillOnQueues + numberOfMockEventsReadFromQueues.contents,
          ~message="There were a different number of events created to what was recieved from the queues.",
        ).toBe(numberOfMockEventsCreated)
      },
    )

    // GlobalState launches the next fetch before awaiting processEventBatch, so a
    // response can advance a chain's fetchState while the batch is in flight.
    // updateProgressedChains must commit only progress fields and keep that
    // concurrently-advanced fetch frontier, otherwise the freshly fetched blocks
    // are silently dropped.
    it("updateProgressedChains keeps a fetchState that advanced during the batch", t => {
      let config = Config.loadWithoutRegistrations()
      let eventConfigs = [
        (
          MockIndexer.evmEventConfig(~id="0", ~contractName="Gravatar", ~isWildcard=true) :>
            Internal.eventConfig
        ),
      ]

      let makeFetchState = (~chainId, ~eventBlocks) => {
        let fetchState = ref(
          FetchState.make(
            ~maxAddrInPartition=Env.maxAddrInPartition,
            ~endBlock=None,
            ~eventConfigs,
            ~addresses=[],
            ~startBlock=0,
            ~targetBufferSize=5000,
            ~chainId,
            ~knownHeight=0,
          ),
        )
        eventBlocks->Array.forEach(blockNumber => {
          let query: FetchState.query = {
            partitionId: "0",
            fromBlock: 0,
            toBlock: None,
            isChunk: false,
            selection: {dependsOnAddresses: false, eventConfigs},
            addressesByContractName: Dict.make(),
            indexingAddresses: fetchState.contents.indexingAddresses,
          }
          fetchState.contents->FetchState.startFetchingQueries(~queries=[query])
          fetchState :=
            fetchState.contents->FetchState.handleQueryResult(
              ~query,
              ~latestFetchedBlock={blockNumber, blockTimestamp: blockNumber * 15},
              ~newItems=[
                Internal.Event({
                  timestamp: blockNumber * 15,
                  chain: ChainMap.Chain.makeUnsafe(~chainId),
                  blockNumber,
                  blockHash: `0x${blockNumber->Int.toString}`,
                  logIndex: 0,
                  eventConfig: Utils.magic("Mock eventConfig"),
                  event: Utils.magic("Mock event"),
                }),
              ],
            )
        })
        fetchState.contents
      }

      let makeChainManager = (~eventBlocks): ChainManager.t => {
        let chainFetchers = config.chainMap->ChainMap.map(chainConfig => {
          let mockSource = MockIndexer.Source.make([], ~chain=#1)
          let chainFetcher: ChainFetcher.t = {
            timestampCaughtUpToHeadOrEndblock: None,
            committedProgressBlockNumber: -1,
            numEventsProcessed: 0.,
            fetchState: makeFetchState(~chainId=chainConfig.id, ~eventBlocks),
            logger: Logging.getLogger(),
            sourceManager: SourceManager.make(
              ~sources=[mockSource.source],
              ~maxPartitionConcurrency=Env.maxPartitionConcurrency,
              ~isRealtime=false,
            ),
            chainConfig,
            reorgDetection: ReorgDetection.make(
              ~chainReorgCheckpoints=[],
              ~maxReorgDepth=200,
              ~shouldRollbackOnReorg=false,
            ),
            safeCheckpointTracking: None,
            isProgressAtHead: false,
          }
          chainFetcher
        })
        {chainFetchers, isInReorgThreshold: false, isRealtime: false}
      }

      // The batch is created while each chain has fetched up to block 5.
      let atBatchCreation = makeChainManager(~eventBlocks=[5])
      let batch =
        atBatchCreation->ChainManager.createBatch(
          ~processedCheckpointId=Internal.initialCheckpointId,
          ~batchSizeTarget=10000,
          ~isRollback=false,
        )

      let chain = atBatchCreation.chainFetchers->ChainMap.keys->Array.getUnsafe(0)
      let chainId = chain->ChainMap.Chain.toChainId

      // A fetch lands mid-batch and advances this chain's frontier to block 15.
      let cf = atBatchCreation.chainFetchers->ChainMap.get(chain)
      let withConcurrentFetch: ChainManager.t = {
        ...atBatchCreation,
        chainFetchers: atBatchCreation.chainFetchers->ChainMap.set(
          chain,
          {...cf, fetchState: makeFetchState(~chainId, ~eventBlocks=[5, 15])},
        ),
      }

      let result = withConcurrentFetch->ChainManager.updateProgressedChains(~batch)
      let resultCf = result.chainFetchers->ChainMap.get(chain)
      let progressed =
        batch.progressedChainsById
        ->Utils.Dict.dangerouslyGetByIntNonOption(chainId)
        ->Option.getUnsafe

      t.expect(
        {
          "committedProgressBlockNumber": resultCf.committedProgressBlockNumber,
          // The concurrent fetch buffered 2 events; the batch-time snapshot had 1.
          // Seeing 2 proves the current (post-fetch) fetchState was kept.
          "bufferSize": resultCf.fetchState->FetchState.bufferSize,
        },
        ~message="must commit the batch's progress while keeping the mid-batch fetch frontier",
      ).toEqual({
        "committedProgressBlockNumber": progressed.progressBlockNumber,
        "bufferSize": 2,
      })
    })
  })
})
