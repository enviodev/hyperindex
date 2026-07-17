open Vitest

// Spread into query literals so the common fields don't have to be repeated;
// every other field is overridden at the call site.
let defaultQuery: FetchState.query = {
  partitionId: "0",
  fromBlock: 0,
  toBlock: None,
  isChunk: false,
  itemsTarget: 0,
  itemsEst: 0,
  selection: {FetchState.dependsOnAddresses: false, onEventRegistrations: []},
  addressesByContractName: Dict.make(),
}

let populateChainQueuesWithRandomEvents = (~runTime=1000, ~maxBlockTime=15, ()) => {
  let config = Config.load()
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

    let onEventRegistrations = [
      (MockIndexer.evmOnEventRegistration(
        ~id="0",
        ~contractName="Gravatar",
        ~isWildcard=true,
      ) :> Internal.onEventRegistration),
    ]
    let addresses = []
    let contractConfigs = IndexingAddresses.makeContractConfigs(~onEventRegistrations)
    let indexingAddresses = IndexingAddresses.make(~contractConfigs, ~addresses)
    let fetcherStateInit: FetchState.t = FetchState.make(
      ~maxAddrInPartition=Env.maxAddrInPartition,
      ~endBlock=None,
      ~onEventRegistrations,
      ~contractConfigs,
      ~addresses,
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
          chain: ChainMap.Chain.makeUnsafe(~chainId=id),
          blockNumber: currentBlockNumber.contents,
          logIndex,
          transactionIndex: 0,
          // Carries an `index` so the buffer's dedup key resolves; the rest of
          // the registration is unused by this test.
          onEventRegistration: {"index": 0}->(
            Utils.magic: {"index": int} => Internal.onEventRegistration
          ),
          payload: `mock event (chainId)${id->Int.toString} - (blockNumber)${currentBlockNumber.contents->Int.toString} - (logIndex)${logIndex->Int.toString} - (timestamp)${currentTime.contents->Int.toString}`->(
            Utils.magic: string => Internal.eventPayload
          ),
        })
        allEvents->Array.push(batchItem)->ignore

        let query: FetchState.query = {
          partitionId: "0",
          itemsTarget: 0,
          itemsEst: 0,
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          selection: {
            dependsOnAddresses: false,
            onEventRegistrations,
          },
          addressesByContractName: Dict.make(),
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
      ~indexingAddresses,
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
    ~persistence=MockIndexer.defaultPersistence(),
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
  | Block({onBlockRegistration: {chainId}, blockNumber}) => (chainId, blockNumber, 0)
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
          chain: MockConfig.chain1,
          blockNumber: 0,
          logIndex: 0,
          transactionIndex: 0,
          // Carries an `index` so the buffer's dedup key resolves; the rest of
          // the registration is unused by this test.
          onEventRegistration: {"index": 0}->(
            Utils.magic: {"index": int} => Internal.onEventRegistration
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
          ->Array.reduce(0, (accum, cs) => accum + cs->ChainState.bufferSize)

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
        let config = Config.load()
        let onEventRegistrations = [
          (MockIndexer.evmOnEventRegistration(
            ~id="0",
            ~contractName="Gravatar",
            ~isWildcard=true,
          ) :> Internal.onEventRegistration),
        ]

        let makeFetchState = (~chainId, ~eventBlocks) => {
          let addresses = []
          let contractConfigs = IndexingAddresses.makeContractConfigs(~onEventRegistrations)
          let indexingAddresses = IndexingAddresses.make(~contractConfigs, ~addresses)
          let fetchState = ref(
            FetchState.make(
              ~maxAddrInPartition=Env.maxAddrInPartition,
              ~endBlock=None,
              ~onEventRegistrations,
              ~contractConfigs,
              ~addresses,
              ~startBlock=0,
              ~maxOnBlockBufferSize=5000,
              ~chainId,
              ~knownHeight=0,
            ),
          )
          eventBlocks->Array.forEach(
            blockNumber => {
              let query: FetchState.query = {
                partitionId: "0",
                itemsTarget: 0,
                itemsEst: 0,
                fromBlock: 0,
                toBlock: None,
                isChunk: false,
                selection: {dependsOnAddresses: false, onEventRegistrations},
                addressesByContractName: Dict.make(),
              }
              fetchState.contents->FetchState.startFetchingQueries(~queries=[query])
              fetchState :=
                fetchState.contents->FetchState.handleQueryResult(
                  ~query,
                  ~latestFetchedBlock={blockNumber, blockTimestamp: blockNumber * 15},
                  ~newItems=[
                    Internal.Event({
                      chain: ChainMap.Chain.makeUnsafe(~chainId),
                      blockNumber,
                      logIndex: 0,
                      transactionIndex: 0,
                      // Carries an `index` so the buffer's dedup key resolves.
                      onEventRegistration: {"index": 0}->(
                        Utils.magic: {"index": int} => Internal.onEventRegistration
                      ),
                      payload: "Mock event"->(Utils.magic: string => Internal.eventPayload),
                    }),
                  ],
                )
            },
          )
          (fetchState.contents, indexingAddresses)
        }

        let makeState = (~eventBlocks): IndexerState.t => {
          let chainStates = Dict.make()
          config.chainMap
          ->ChainMap.values
          ->Array.forEach(
            chainConfig => {
              let mockSource = MockIndexer.Source.make([], ~chain=#1)
              let (fetchState, indexingAddresses) = makeFetchState(~chainId=chainConfig.id, ~eventBlocks)
              let chainState = ChainState.make(
                ~chainConfig,
                ~fetchState,
                ~indexingAddresses,
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
            ~persistence=MockIndexer.defaultPersistence(),
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
        let concurrentQuery: FetchState.query = {
          partitionId: "0",
          itemsTarget: 0,
          itemsEst: 0,
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          selection: {dependsOnAddresses: false, onEventRegistrations},
          addressesByContractName: Dict.make(),
        }
        cs->ChainState.startFetchingQueries(~queries=[concurrentQuery])
        cs->ChainState.handleQueryResult(
          ~query=concurrentQuery,
          ~newItemsWithDcs=[],
          ~latestFetchedBlock={blockNumber: 15, blockTimestamp: 15 * 15},
          ~newItems=[
            Internal.Event({
              chain,
              blockNumber: 15,
              logIndex: 0,
              transactionIndex: 0,
              // Carries an `index` so the buffer's dedup key resolves.
              onEventRegistration: {"index": 0}->(
                Utils.magic: {"index": int} => Internal.onEventRegistration
              ),
              payload: "Mock event"->(Utils.magic: string => Internal.eventPayload),
            }),
          ],
          ~knownHeight=cs->ChainState.knownHeight,
          ~transactionStore=None,
          ~blockStore=None,
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
            "bufferSize": resultCs->ChainState.bufferSize,
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
