open RescriptMocha
open Mocha
let {
  it: it_promise,
  it_only: it_promise_only,
  it_skip: it_skip_promise,
  before: before_promise,
} = module(RescriptMocha.Promise)

let populateChainQueuesWithRandomEvents = (
  ~numberOfChains=3,
  ~runTime=100000,
  ~maxBlockTime=15,
  (),
) => {
  let allEvents = []

  let arbitraryEventPriorityQueue = SDSL.PriorityQueue.makeAdvanced(
    [],
    // ChainManager.priorityQueueComparitor,
    ChainManager.ExposedForTesting_Hidden.priorityQueueComparitor,
  )
  let chainFetchers = Js.Dict.empty()
  let numberOfMockEventsCreated = ref(0)

  for chainId in 1 to numberOfChains {
    let getCurrentTimestamp = () => {
      let timestampMillis = Js.Date.now()

      // Convert milliseconds to seconds
      Belt.Int.fromFloat(timestampMillis /. 1000.0)
    }
    /// Generates a random number between two ints inclusive
    let getRandomInt = (min, max) => {
      Belt.Int.fromFloat(Js.Math.random() *. float_of_int(max - min + 1) +. float_of_int(min))
    }

    let fetchedEventQueue = ChainEventQueue.make(~maxQueueSize=100000)

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
          chainId,
          blockNumber: currentBlockNumber.contents,
          logIndex,
          event: `mock event (chainId)${chainId->string_of_int} - (blockNumber)${currentBlockNumber.contents->string_of_int} - (logIndex)${logIndex->string_of_int} - (timestamp)${currentTime.contents->string_of_int}`->Obj.magic,
        }

        allEvents->Js.Array2.push(batchItem)->ignore

        switch queuesToUse {
        | 0 => arbitraryEventPriorityQueue->SDSL.PriorityQueue.push(batchItem)->ignore
        | 1 => fetchedEventQueue.queue->SDSL.Queue.push(batchItem)->ignore
        | 2
        | _ =>
          if Js.Math.random() < 0.5 {
            arbitraryEventPriorityQueue->SDSL.PriorityQueue.push(batchItem)->ignore
          } else {
            fetchedEventQueue.queue->SDSL.Queue.push(batchItem)->ignore
          }
        }
        numberOfMockEventsCreated := numberOfMockEventsCreated.contents + 1
      }

      currentTime := currentTime.contents + blockTime
      currentBlockNumber := currentBlockNumber.contents + 1
    }
    let mockChainFetcher: ChainFetcher.t = {
      fetchedEventQueue,
      logger: Logging.logger,
      chainConfig: "TODO"->Obj.magic,
      // This is quite a hack - but it works!
      chainWorker: Rpc((1, {"latestFetchedBlockTimestamp": currentTime.contents})->Obj.magic),
    }
    chainFetchers->Js.Dict.set(chainId->Belt.Int.toString, mockChainFetcher)
  }

  (
    {
      ChainManager.arbitraryEventPriorityQueue,
      chainFetchers,
    },
    numberOfMockEventsCreated.contents,
    allEvents,
  )
}

describe("ChainManager", () => {
  describe("popBlockBatchItems", () => {
    it(
      "when processing through many randomly generated events on different queues, the grouping and ordering is correct",
      () => {
        let (
          mockChainManager,
          numberOfMockEventsCreated,
          allEvents,
        ) = populateChainQueuesWithRandomEvents()
        let defaultFirstEvent: Types.eventBatchQueueItem = {
          timestamp: 0,
          chainId: 0,
          blockNumber: 0,
          logIndex: 0,
          event: `mock initial event`->Obj.magic,
        }

        let numberOfMockEventsReadFromQueues = ref(0)
        let allEventsRead = []
        let rec testThatCreatedEventsAreOrderedCorrectly = lastEvent => {
          let eventsInBlock = ChainManager.popBlockBatchItems(mockChainManager)
          Js.log3(
            "[BEG]recurse",
            eventsInBlock->Belt.Option.mapWithDefault(
              "EMPTY"->Obj.magic,
              e => e->Belt.Array.map(i => i.event),
            ),
            "[END]recurse",
          )

          // ensure that the events are ordered correctly
          switch eventsInBlock {
          | None => true
          | Some(eventsInBlock) =>
            eventsInBlock
            ->Belt.Array.map(
              i => {
                allEventsRead->Js.Array2.push(i)
              },
            )
            ->ignore
            numberOfMockEventsReadFromQueues :=
              numberOfMockEventsReadFromQueues.contents + eventsInBlock->Belt.Array.length
            // Check that events has at least 1 item in it
            Assert.equal(
              eventsInBlock->Belt.Array.length > 0,
              true,
              ~message="if `Some` is returned, the array must have at least 1 item in it.",
            )

            let firstEventInBlock = eventsInBlock->Belt.Array.getExn(0)

            Assert.equal(
              firstEventInBlock->ChainManager.ExposedForTesting_Hidden.getComparitorFromItem >
                lastEvent->ChainManager.ExposedForTesting_Hidden.getComparitorFromItem,
              true,
              ~message="Check that first event in this block group is AFTER the last event before this block group",
            )

            let lastEvent =
              eventsInBlock
              ->Belt.Array.sliceToEnd(1)
              ->Belt.Array.reduce(
                firstEventInBlock,
                (previous, current) => {
                  Assert.equal(
                    previous.blockNumber,
                    current.blockNumber,
                    ~message=`The block number within a block should always be the same, here ${previous.blockNumber->string_of_int} (previous.blockNumber) != ${current.blockNumber->string_of_int}(current.blockNumber)`,
                  )

                  Assert.equal(
                    previous.chainId,
                    current.chainId,
                    ~message=`The chainId within a block should always be the same, here ${previous.chainId->string_of_int} (previous.chainId) != ${current.chainId->string_of_int}(current.chainId)`,
                  )

                  Assert.equal(
                    current.logIndex > previous.logIndex,
                    true,
                    ~message=`Incorrect log index, the offending event pair: ${current.event->Obj.magic} - ${previous.event->Obj.magic}`,
                  )
                  current
                },
              )
            testThatCreatedEventsAreOrderedCorrectly(lastEvent)
          }
        }

        let _ = testThatCreatedEventsAreOrderedCorrectly(defaultFirstEvent)

        // Test that no events were missed
        let amountStillOnQueues =
          mockChainManager.arbitraryEventPriorityQueue->SDSL.PriorityQueue.length +
            mockChainManager.chainFetchers
            ->Js.Dict.values
            ->Belt.Array.reduce(
              0,
              (accum, val) => {
                accum + val.fetchedEventQueue.queue->SDSL.Queue.size
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
