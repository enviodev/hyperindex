open Belt
open Ava

let populateChainQueuesWithRandomEvents = (~runTime=1000, ~maxBlockTime=15, ()) => {
  let allEvents = []

  let arbitraryEventPriorityQueue = ref(list{})
  let numberOfMockEventsCreated = ref(0)

  let chainFetchers = Config.config->ChainMap.map(({chain}) => {
    let getCurrentTimestamp = () => {
      let timestampMillis = Js.Date.now()

      // Convert milliseconds to seconds
      Belt.Int.fromFloat(timestampMillis /. 1000.0)
    }
    /// Generates a random number between two ints inclusive
    let getRandomInt = (min, max) => {
      Belt.Int.fromFloat(Js.Math.random() *. float_of_int(max - min + 1) +. float_of_int(min))
    }

    let fetcherStateInit: FetchState.t = FetchState.makeRoot(
      ~contractAddressMapping=ContractAddressingMap.make(),
      ~dynamicContracts=FetchState.DynamicContractsMap.empty,
      ~startBlock=0,
      ~endBlock=None,
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
      // there is 1 in 3 chance that all the events in the block are in the arbitraryEventPriorityQueue, all in the ChainEventQueue or split between the two
      //   0 -> all in arbitraryEventPriorityQueue
      //   1 -> all in ChainEventQueue
      //   2 -> split between the two
      let queuesToUse = getRandomInt(0, 2)
      let blockTime = getRandomInt(0, 2 * averageBlockTime)

      let numberOfEventsInBatch = getRandomInt(0, 2 * averageEventsPerBlock)

      for logIndex in 0 to numberOfEventsInBatch {
        let batchItem: Types.eventBatchQueueItem = {
          timestamp: currentTime.contents,
          chain,
          blockNumber: currentBlockNumber.contents,
          logIndex,
          event: `mock event (chainId)${chain->ChainMap.Chain.toString} - (blockNumber)${currentBlockNumber.contents->string_of_int} - (logIndex)${logIndex->string_of_int} - (timestamp)${currentTime.contents->string_of_int}`->Obj.magic,
        }

        allEvents->Js.Array2.push(batchItem)->ignore

        switch queuesToUse {
        | 0 =>
          arbitraryEventPriorityQueue :=
            list{batchItem}->FetchState.mergeSortedEventList(arbitraryEventPriorityQueue.contents)
        | 1 =>
          fetchState :=
            fetchState.contents
            ->FetchState.update(
              ~id=Root,
              ~latestFetchedBlock={
                blockNumber: batchItem.blockNumber,
                blockTimestamp: batchItem.timestamp,
              },
              ~fetchedEvents=list{batchItem},
            )
            ->Result.getExn
        | 2
        | _ =>
          if Js.Math.random() < 0.5 {
            arbitraryEventPriorityQueue :=
              list{batchItem}->FetchState.mergeSortedEventList(arbitraryEventPriorityQueue.contents)
          } else {
            fetchState :=
              fetchState.contents
              ->FetchState.update(
                ~id=Root,
                ~latestFetchedBlock={
                  blockNumber: batchItem.blockNumber,
                  blockTimestamp: batchItem.timestamp,
                },
                ~fetchedEvents=list{batchItem},
              )
              ->Result.getExn
          }
        }
        numberOfMockEventsCreated := numberOfMockEventsCreated.contents + 1
      }

      currentTime := currentTime.contents + blockTime
      currentBlockNumber := currentBlockNumber.contents + 1
    }
    let mockChainFetcher: ChainFetcher.t = {
      timestampCaughtUpToHeadOrEndblock: None,
      firstEventBlockNumber: None,
      latestProcessedBlock: None,
      numEventsProcessed: 0,
      numBatchesFetched: 0,
      isFetchingAtHead: false,
      fetchState: fetchState.contents,
      logger: Logging.logger,
      chainConfig: "TODO"->Obj.magic,
      // This is quite a hack - but it works!
      chainWorker: Config.Rpc(
        (1, {"latestFetchedBlockTimestamp": currentTime.contents})->Obj.magic,
      ),
      lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.empty(
        ~confirmedBlockThreshold=200,
      ),
      isFetchingBatch: false,
      currentBlockHeight: 0,
      eventFilters: None,
    }

    mockChainFetcher
  })

  (
    {
      ChainManager.arbitraryEventPriorityQueue: arbitraryEventPriorityQueue.contents,
      chainFetchers,
      isUnorderedMultichainMode: false,
    },
    numberOfMockEventsCreated.contents,
    allEvents,
  )
}

//Test was previously popBlockBatchItems

test(
  "createBatch: when processing through many randomly generated events on different queues, the grouping and ordering is correct",
  (. t) => {
    let (
      mockChainManager,
      numberOfMockEventsCreated,
      _allEvents,
    ) = populateChainQueuesWithRandomEvents()

    let defaultFirstEvent: Types.eventBatchQueueItem = {
      timestamp: 0,
      chain: Chain_1,
      blockNumber: 0,
      logIndex: 0,
      event: `mock initial event`->Obj.magic,
    }

    let numberOfMockEventsReadFromQueues = ref(0)
    let allEventsRead = []
    let rec testThatCreatedEventsAreOrderedCorrectly = (chainManager, lastEvent) => {
      let eventsInBlock = ChainManager.createBatch(chainManager, ~maxBatchSize=10000)

      // ensure that the events are ordered correctly
      switch eventsInBlock {
      | None => chainManager
      | Some({batch, batchSize, fetchStatesMap, arbitraryEventQueue}) =>
        batch->List.forEach(i => {
          allEventsRead->Js.Array2.push(i)
        })
        numberOfMockEventsReadFromQueues := numberOfMockEventsReadFromQueues.contents + batchSize
        // Check that events has at least 1 item in it
        t->Assert.deepEqual(.
          batchSize > 0,
          true,
          ~message="if `Some` is returned, the array must have at least 1 item in it.",
        )

        let firstEventInBlock = batch->List.headExn

        t->Assert.deepEqual(.
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
        //       // t->Assert.deepEqual(.
        //       //   previous.blockNumber,
        //       //   current.blockNumber,
        //       //   ~message=`The block number within a block should always be the same, here ${previous.blockNumber->string_of_int} (previous.blockNumber) != ${current.blockNumber->string_of_int}(current.blockNumber)`,
        //       // )
        //
        //       t->Assert.deepEqual(.
        //         previous.chain,
        //         current.chain,
        //         ~message=`The chainId within a block should always be the same, here ${previous.chain->ChainMap.Chain.toString} (previous.chainId) != ${current.chain->ChainMap.Chain.toString}(current.chainId)`,
        //       )
        //
        //       t->Assert.deepEqual(.
        //         current.logIndex > previous.logIndex,
        //         true,
        //         ~message=`Incorrect log index, the offending event pair: ${current.event->Obj.magic} - ${previous.event->Obj.magic}`,
        //       )
        //       current
        //     },
        //   )
        let nextChainFetchers = chainManager.chainFetchers->ChainMap.mapWithKey((
          chain,
          fetcher,
        ) => {
          let fetchState = fetchStatesMap->ChainMap.get(chain)
          {
            ...fetcher,
            fetchState,
          }
        })

        let nextChainManager: ChainManager.t = {
          ...chainManager,
          arbitraryEventPriorityQueue: arbitraryEventQueue,
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
      finalChainManager.arbitraryEventPriorityQueue->List.length +
        finalChainManager.chainFetchers
        ->ChainMap.values
        ->Belt.Array.reduce(0, (accum, val) => {
          accum + val.fetchState->FetchState.queueSize
        })

    t->Assert.deepEqual(.
      amountStillOnQueues + numberOfMockEventsReadFromQueues.contents,
      numberOfMockEventsCreated,
      ~message="There were a different number of events created to what was recieved from the queues.",
    )
  },
)
