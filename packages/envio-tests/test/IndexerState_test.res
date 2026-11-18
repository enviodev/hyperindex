open Vitest

// Spread into query literals so the common fields don't have to be repeated;
// every other field is overridden at the call site.

let populateChainQueuesWithRandomEvents = (~runTime=1000, ~maxBlockTime=15, ()) => {
  let config = TestConfig.default
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
      (EventRegistration.evmOnEventRegistration(
        ~id="0",
        ~contractName="Gravatar",
        ~isWildcard=true,
      ) :> Internal.onEventRegistration),
    ]
    let addresses = []
    let addressStore = TestAddresses.makeStore(~onEventRegistrations)
    let fetcherStateInit: FetchState.t = TestFetchState.make(
      ~onNotice=ignore,
      ~maxAddrInPartition=Env.maxAddrInPartition,
      ~endBlock=None,
      ~onEventRegistrations,
      ~addressStore,
      ~addressRows=TestAddresses.addressRows(~addresses, ~onEventRegistrations),
      ~startBlock=0,
      ~maxOnBlockBufferSize=5000,
      ~chainId=1->ChainId.fromInt,
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
          chainId: id,
          blockNumber: currentBlockNumber.contents,
          logIndex,
          transactionIndex: 0,
          // Carries an `index` so the buffer's dedup key resolves; the rest of
          // the registration is unused by this test.
          onEventRegistration: {"index": 0}->(
            Utils.magic: {"index": int} => Internal.onEventRegistration
          ),
          // Carries its transaction and block, as a simulate item does, so
          // the take reads neither from the chain's stores.
          payload: {
            "description": `mock event (chainId)${id->ChainId.toString} - (blockNumber)${currentBlockNumber.contents->Int.toString} - (logIndex)${logIndex->Int.toString} - (timestamp)${currentTime.contents->Int.toString}`,
            "transaction": Dict.make(),
            "block": Dict.make(),
          }->(Utils.magic: {..} => Internal.eventPayload),
        })
        allEvents->Array.push(batchItem)->ignore

        let query: FetchState.query = {
          partitionId: "0",
          itemsEst: 0,
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          selection: FetchState.makeSelection(~dependsOnAddresses=false, ~onEventRegistrations),
          addresses: TestAddresses.setOf([]),
        }

        fetchState.contents->FetchState.startFetchingQueries(~queries=[query])

        fetchState :=
          fetchState.contents->TestFetchState.handleQueryResult(
            ~query,
            ~latestFetchedBlock=currentBlockNumber.contents,
            ~page=TestEventStore.pageOf([batchItem]),
          )

        numberOfMockEventsCreated := numberOfMockEventsCreated.contents + 1
      }

      currentTime := currentTime.contents + blockTime
      currentBlockNumber := currentBlockNumber.contents + 1
    }
    // The buffer is ready only up to the known height, so it has to cover the
    // random block range for any batch to take an event.
    fetchState :=
      fetchState.contents->TestFetchState.updateKnownHeight(
        ~knownHeight=currentBlockNumber.contents,
      )

    let chainConfig = config.defaultChain->Option.getUnsafe
    // For this test we don't need real sources - just testing event ordering
    // Create a mock source that satisfies SourceManager requirements (chain ID doesn't matter here)
    let mockSource = MockSource.make([], ~chainId=1)
    let mockChainState = ChainState.make(
      ~chainConfig,
      ~fetchState=fetchState.contents,
      ~eventStore=fetchState.contents->TestFetchState.eventStoreOf,
      ~addressStore,
      ~sourceManager=SourceManager.make(
        ~logger=Logger.makeInMemory(),
        ~sources=[mockSource.source],
        ~isRealtime=false,
      ),
      // This is quite a hack - but it works!
      ~maxReorgDepth=200,
      ~shouldRollbackOnReorg=false,
      ~committedProgressBlockNumber=-1,
      ~logger=Logger.makeInMemory(),
    )

    chainStates->ChainId.Dict.set(id, mockChainState)
  })

  let state = IndexerState.make(
    ~logger=Logger.makeInMemory(),
    ~config,
    ~persistence=TestIndexerState.defaultPersistence(),
    ~chainStates,
    ~isRealtime=false,
    ~onError=errHandler => errHandler->ErrorHandling.toExn->throw,
  )

  (state, numberOfMockEventsCreated.contents, allEvents)
}

let getItemKey = (item: Internal.item) =>
  switch item {
  | Event({chainId, blockNumber, logIndex}) => (chainId, blockNumber, logIndex)
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
          chainId: 1->ChainId.fromInt,
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
          let batch = state->IndexerState.createBatch(~batchSizeTarget=10000)
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
          (numberOfMockEventsReadFromQueues.contents, amountStillOnQueues),
          ~message="Every created event must be processed through batches, none left behind",
        ).toEqual((numberOfMockEventsCreated, 0))
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
        let config = TestConfig.default
        let onEventRegistrations = [
          (EventRegistration.evmOnEventRegistration(
            ~id="0",
            ~contractName="Gravatar",
            ~isWildcard=true,
          ) :> Internal.onEventRegistration),
        ]

        let makeFetchState = (~chainId, ~eventBlocks) => {
          let addresses = []
          let addressStore = TestAddresses.makeStore(~onEventRegistrations)
          let fetchState = ref(
            TestFetchState.make(
              ~onNotice=ignore,
              ~maxAddrInPartition=Env.maxAddrInPartition,
              ~endBlock=None,
              ~onEventRegistrations,
              ~addressStore,
              ~addressRows=TestAddresses.addressRows(~addresses, ~onEventRegistrations),
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
                itemsEst: 0,
                fromBlock: 0,
                toBlock: None,
                isChunk: false,
                selection: FetchState.makeSelection(
                  ~dependsOnAddresses=false,
                  ~onEventRegistrations,
                ),
                addresses: TestAddresses.setOf([]),
              }
              fetchState.contents->FetchState.startFetchingQueries(~queries=[query])
              fetchState :=
                fetchState.contents->TestFetchState.handleQueryResult(
                  ~query,
                  ~latestFetchedBlock=blockNumber,
                  ~page=TestEventStore.pageOf([
                    Internal.Event({
                      chainId,
                      blockNumber,
                      logIndex: 0,
                      transactionIndex: 0,
                      // Carries an `index` so the buffer's dedup key resolves.
                      onEventRegistration: {"index": 0}->(
                        Utils.magic: {"index": int} => Internal.onEventRegistration
                      ),
                      payload: "Mock event"->(Utils.magic: string => Internal.eventPayload),
                    }),
                  ]),
                )
            },
          )
          (fetchState.contents, addressStore)
        }

        let makeState = (~eventBlocks): IndexerState.t => {
          let chainStates = Dict.make()
          config.chainMap
          ->ChainMap.values
          ->Array.forEach(
            chainConfig => {
              let mockSource = MockSource.make([], ~chainId=1)
              let (fetchState, addressStore) = makeFetchState(~chainId=chainConfig.id, ~eventBlocks)
              let chainState = ChainState.make(
                ~chainConfig,
                ~fetchState,
                ~eventStore=fetchState->TestFetchState.eventStoreOf,
                ~addressStore,
                ~sourceManager=SourceManager.make(
                  ~logger=Logger.makeInMemory(),
                  ~sources=[mockSource.source],
                  ~isRealtime=false,
                ),
                ~maxReorgDepth=200,
                ~shouldRollbackOnReorg=false,
                ~committedProgressBlockNumber=-1,
                ~logger=Logger.makeInMemory(),
              )
              chainStates->ChainId.Dict.set(chainConfig.id, chainState)
            },
          )
          IndexerState.make(
            ~logger=Logger.makeInMemory(),
            ~config,
            ~persistence=TestIndexerState.defaultPersistence(),
            ~chainStates,
            ~isRealtime=false,
            ~onError=errHandler => errHandler->ErrorHandling.toExn->throw,
          )
        }

        // The batch is created while each chain has fetched up to block 5.
        let state = makeState(~eventBlocks=[5])
        let batch = state->IndexerState.createBatch(~batchSizeTarget=10000)

        let chainId = config.chainMap->ChainMap.keys->Array.getUnsafe(0)

        // A fetch lands mid-batch and appends block 15 to this chain's buffer
        // (its batch-time snapshot held only block 5).
        let cs = state->IndexerState.getChainState(~chainId)
        let concurrentQuery: FetchState.query = {
          partitionId: "0",
          itemsEst: 0,
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          selection: FetchState.makeSelection(~dependsOnAddresses=false, ~onEventRegistrations),
          addresses: TestAddresses.setOf([]),
        }
        cs->ChainState.startFetchingQueries(~queries=[concurrentQuery])
        cs->ChainState.handleQueryResult(
          ~query=concurrentQuery,
          ~newRegistrations=[],
          ~latestFetchedBlock=15,
          ~page=TestEventStore.pageOf([
            Internal.Event({
              chainId,
              blockNumber: 15,
              logIndex: 0,
              transactionIndex: 0,
              // Carries an `index` so the buffer's dedup key resolves.
              onEventRegistration: {"index": 0}->(
                Utils.magic: {"index": int} => Internal.onEventRegistration
              ),
              payload: "Mock event"->(Utils.magic: string => Internal.eventPayload),
            }),
          ]),
          ~knownHeight=cs->ChainState.knownHeight,
        )

        state->IndexerState.applyBatchProgress(~batch)
        let resultCs = state->IndexerState.getChainState(~chainId)
        let progressed =
          batch.progressedChainsById
          ->ChainId.Dict.dangerouslyGetNonOption(chainId)
          ->Option.getUnsafe

        t.expect(
          {
            "committedProgressBlockNumber": resultCs->ChainState.committedProgressBlockNumber,
            // The concurrent fetch buffered 2 events in the chain's store.
            "bufferSize": resultCs->ChainState.bufferSize,
            // The store is the chain's either way, so only the frontier shows
            // whether the post-fetch fetch state was kept: the batch-time
            // snapshot would ask again from block 6.
            "nextQueryFromBlock": {
              resultCs->ChainState.updateKnownHeight(~knownHeight=100)
              switch resultCs->ChainState.getNextQuery(~chainTargetItems=10_000.) {
              | Ready([query]) => Some(query.fromBlock)
              | _ => None
              }
            },
          },
          ~message="must commit the batch's progress while keeping the mid-batch fetch frontier",
        ).toEqual({
          "committedProgressBlockNumber": progressed.progressBlockNumber,
          "bufferSize": 2,
          "nextQueryFromBlock": Some(16),
        })
      },
    )
  })
})
