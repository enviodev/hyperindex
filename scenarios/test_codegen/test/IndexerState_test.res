open Vitest

// Spread into query literals so the cross-chain scheduler fields
// (chainId/progress) don't have to be repeated; every other field is
// overridden at the call site.
let defaultQuery: FetchState.query = {
  partitionId: "0",
  fromBlock: 0,
  toBlock: None,
  isChunk: false,
  estResponseSize: 0.,
  chainId: 0,
  progress: 0.,
  selection: {FetchState.dependsOnAddresses: false, eventConfigs: []},
  addressesByContractName: Dict.make(),
  indexingAddresses: Dict.make(),
}

let populateChainQueuesWithRandomEvents = (~runTime=1000, ~maxBlockTime=15, ()) => {
  let config = Config.loadWithoutRegistrations()
  let allEvents = []
  let numberOfMockEventsCreated = ref(0)

  let chainStates = Dict.make()
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(({id}) => {
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
      ~maxOnBlockBufferSize=5000,
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
          eventConfig: "Mock eventConfig in IndexerState test"->(
            Utils.magic: string => Internal.eventConfig
          ),
          payload: `mock event (chainId)${id->Int.toString} - (blockNumber)${currentBlockNumber.contents->Int.toString} - (logIndex)${logIndex->Int.toString} - (timestamp)${currentTime.contents->Int.toString}`->(
            Utils.magic: string => Internal.eventPayload
          ),
        })
        allEvents->Array.push(batchItem)->ignore

        let query: FetchState.query = {
          ...defaultQuery,
          partitionId: "0",
          estResponseSize: 0.,
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
    // For this test we don't need real sources - just testing event ordering
    // Create a mock source that satisfies SourceManager requirements (chain ID doesn't matter here)
    let mockSource = MockIndexer.Source.make([], ~chain=#1)
    let mockChainState = ChainState.make(
      ~chainConfig,
      ~fetchState=fetchState.contents,
      ~sourceManager=SourceManager.make(~sources=[mockSource.source], ~isRealtime=false),
      // This is quite a hack - but it works!
      ~reorgDetection=ReorgDetection.make(
        ~chainReorgCheckpoints=[],
        ~maxReorgDepth=200,
        ~shouldRollbackOnReorg=false,
      ),
      ~committedProgressBlockNumber=-1,
      ~logger=Logging.getLogger(),
    )

    chainStates->Utils.Dict.setByInt(id, mockChainState)
  })

  let state = IndexerState.make(
    ~config,
    ~persistence=MockIndexer.defaultPersistence,
    ~chainStates,
    ~isInReorgThreshold=false,
    ~isRealtime=false,
    ~onError=errHandler => errHandler->ErrorHandling.raiseExn,
  )

  (state, numberOfMockEventsCreated.contents, allEvents)
}

let getItemKey = (item: Internal.item) =>
  switch item {
  | Event({chain, blockNumber, logIndex}) => (
      chain->ChainMap.Chain.toChainId,
      blockNumber,
      logIndex,
    )
  | Block({onBlockConfig: {chainId}, blockNumber}) => (chainId, blockNumber, 0)
  }

// Advance each chain's fetchState to its post-batch state, simulating the loop
// committing a processed batch.
let advanceChains = (state: IndexerState.t, ~batch) =>
  state
  ->IndexerState.chainStates
  ->Utils.Dict.forEach(cs =>
    cs->ChainState.advanceAfterBatch(~batch, ~enteringReorgThreshold=false)
  )

describe("IndexerState", () => {
  //Test was previously popBlockBatchItems
  describe("createBatch", () => {
    it(
      "when processing through many randomly generated events on different queues, the grouping and ordering is correct",
      t => {
        let (state, numberOfMockEventsCreated, _allEvents) = populateChainQueuesWithRandomEvents()

        let defaultFirstEvent = Internal.Event({
          timestamp: 0,
          chain: MockConfig.chain1,
          blockNumber: 0,
          blockHash: "0x0",
          logIndex: 0,
          eventConfig: "Mock eventConfig in IndexerState test"->(
            Utils.magic: string => Internal.eventConfig
          ),
          payload: `mock initial event`->(Utils.magic: string => Internal.eventPayload),
        })

        let numberOfMockEventsReadFromQueues = ref(0)
        let allEventsRead = []
        let continue = ref(true)
        while continue.contents {
          let batch =
            state->IndexerState.createBatch(
              ~processedCheckpointId=Internal.initialCheckpointId,
              ~batchSizeTarget=10000,
              ~isRollback=false,
            )
          let {items, totalBatchSize} = batch

          // ensure that the events are ordered correctly
          if totalBatchSize === 0 {
            continue := false
          } else {
            items->Array.forEach(item => allEventsRead->Array.push(item)->ignore)
            numberOfMockEventsReadFromQueues :=
              numberOfMockEventsReadFromQueues.contents + totalBatchSize

            let firstEventInBlock = items[0]->Option.getOrThrow

            t.expect(
              firstEventInBlock->getItemKey > defaultFirstEvent->getItemKey,
              ~message="Check that first event in this block group is AFTER the last event before this block group",
            ).toBe(true)

            state->advanceChains(~batch)
          }
        }

        // Test that no events were missed
        let amountStillOnQueues =
          state
          ->IndexerState.chainStates
          ->Dict.valuesToArray
          ->Array.reduce(0, (accum, cs) => accum + cs->ChainState.fetchState->FetchState.bufferSize)

        t.expect(
          amountStillOnQueues + numberOfMockEventsReadFromQueues.contents,
          ~message="There were a different number of events created to what was recieved from the queues.",
        ).toBe(numberOfMockEventsCreated)
      },
    )

    // The loop launches the next fetch before awaiting processEventBatch, so a
    // response can advance a chain's fetchState while the batch is in flight.
    // applyBatchProgress must commit only progress fields and keep that
    // concurrently-advanced fetch frontier, otherwise the freshly fetched blocks
    // are silently dropped.
    it(
      "applyBatchProgress keeps a fetchState that advanced during the batch",
      t => {
        let config = Config.loadWithoutRegistrations()
        let eventConfigs = [
          (MockIndexer.evmEventConfig(
            ~id="0",
            ~contractName="Gravatar",
            ~isWildcard=true,
          ) :> Internal.eventConfig),
        ]

        let makeFetchState = (~chainId, ~eventBlocks) => {
          let fetchState = ref(
            FetchState.make(
              ~maxAddrInPartition=Env.maxAddrInPartition,
              ~endBlock=None,
              ~eventConfigs,
              ~addresses=[],
              ~startBlock=0,
              ~maxOnBlockBufferSize=5000,
              ~chainId,
              ~knownHeight=0,
            ),
          )
          eventBlocks->Array.forEach(
            blockNumber => {
              let query: FetchState.query = {
                ...defaultQuery,
                partitionId: "0",
                estResponseSize: 0.,
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
                      eventConfig: "Mock eventConfig"->(
                        Utils.magic: string => Internal.eventConfig
                      ),
                      payload: "Mock event"->(Utils.magic: string => Internal.eventPayload),
                    }),
                  ],
                )
            },
          )
          fetchState.contents
        }

        let makeState = (~eventBlocks): IndexerState.t => {
          let chainStates = Dict.make()
          config.chainMap
          ->ChainMap.values
          ->Array.forEach(
            chainConfig => {
              let mockSource = MockIndexer.Source.make([], ~chain=#1)
              let chainState = ChainState.make(
                ~chainConfig,
                ~fetchState=makeFetchState(~chainId=chainConfig.id, ~eventBlocks),
                ~sourceManager=SourceManager.make(~sources=[mockSource.source], ~isRealtime=false),
                ~reorgDetection=ReorgDetection.make(
                  ~chainReorgCheckpoints=[],
                  ~maxReorgDepth=200,
                  ~shouldRollbackOnReorg=false,
                ),
                ~committedProgressBlockNumber=-1,
                ~logger=Logging.getLogger(),
              )
              chainStates->Utils.Dict.setByInt(chainConfig.id, chainState)
            },
          )
          IndexerState.make(
            ~config,
            ~persistence=MockIndexer.defaultPersistence,
            ~chainStates,
            ~isInReorgThreshold=false,
            ~isRealtime=false,
            ~onError=errHandler => errHandler->ErrorHandling.raiseExn,
          )
        }

        // The batch is created while each chain has fetched up to block 5.
        let state = makeState(~eventBlocks=[5])
        let batch =
          state->IndexerState.createBatch(
            ~processedCheckpointId=Internal.initialCheckpointId,
            ~batchSizeTarget=10000,
            ~isRollback=false,
          )

        let chain = config.chainMap->ChainMap.keys->Array.getUnsafe(0)
        let chainId = chain->ChainMap.Chain.toChainId

        // A fetch lands mid-batch and appends block 15 to this chain's buffer
        // (its batch-time snapshot held only block 5).
        let cs = state->IndexerState.getChainState(~chain)
        let concurrentFetchState = cs->ChainState.fetchState
        let concurrentQuery: FetchState.query = {
          ...defaultQuery,
          partitionId: "0",
          estResponseSize: 0.,
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          selection: {dependsOnAddresses: false, eventConfigs},
          addressesByContractName: Dict.make(),
          indexingAddresses: concurrentFetchState.indexingAddresses,
        }
        concurrentFetchState->FetchState.startFetchingQueries(~queries=[concurrentQuery])
        cs->ChainState.handleQueryResult(
          ~query=concurrentQuery,
          ~newItemsWithDcs=[],
          ~latestFetchedBlock={blockNumber: 15, blockTimestamp: 15 * 15},
          ~newItems=[
            Internal.Event({
              timestamp: 15 * 15,
              chain,
              blockNumber: 15,
              blockHash: "0x15",
              logIndex: 0,
              eventConfig: "Mock eventConfig"->(Utils.magic: string => Internal.eventConfig),
              payload: "Mock event"->(Utils.magic: string => Internal.eventPayload),
            }),
          ],
          ~knownHeight=concurrentFetchState.knownHeight,
        )

        state->IndexerState.applyBatchProgress(~batch)
        let resultCs = state->IndexerState.getChainState(~chain)
        let progressed =
          batch.progressedChainsById
          ->Utils.Dict.dangerouslyGetByIntNonOption(chainId)
          ->Option.getUnsafe

        t.expect(
          {
            "committedProgressBlockNumber": resultCs->ChainState.committedProgressBlockNumber,
            // The concurrent fetch buffered 2 events; the batch-time snapshot had 1.
            // Seeing 2 proves the current (post-fetch) fetchState was kept.
            "bufferSize": resultCs->ChainState.fetchState->FetchState.bufferSize,
          },
          ~message="must commit the batch's progress while keeping the mid-batch fetch frontier",
        ).toEqual({
          "committedProgressBlockNumber": progressed.progressBlockNumber,
          "bufferSize": 2,
        })
      },
    )
  })
})
