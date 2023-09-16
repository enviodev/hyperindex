// TODO: move to `eventFetching`

type t = {
  chainFetchers: Js.Dict.t<ChainFetcher.t>,
  //The priority queue should only house the latest event from each chain
  //And potentially extra events that are pushed on by newly registered dynamic
  //contracts which missed being fetched by they chainFetcher
  arbitraryEventPriorityQueue: SDSL.PriorityQueue.t<Types.eventBatchQueueItem>,
}

let getComparitorFromItem = (queueItem: Types.eventBatchQueueItem) => {
  let {timestamp, chainId, blockNumber, logIndex} = queueItem
  EventUtils.getEventComparator({timestamp, chainId, blockNumber, logIndex})
}

let priorityQueueComparitor = (a: Types.eventBatchQueueItem, b: Types.eventBatchQueueItem) => {
  if a->getComparitorFromItem < b->getComparitorFromItem {
    -1
  } else {
    1
  }
}

// type blockGroupedBatchItems = array<Types.eventBatchQueueItem>

let chainFetcherPeekComparitorEarliestEvent = (
  a: ChainFetcher.eventQueuePeek,
  b: ChainFetcher.eventQueuePeek,
): bool => {
  switch (a, b) {
  | (Item(itemA), Item(itemB)) => itemA->getComparitorFromItem < itemB->getComparitorFromItem
  | (Item(itemA), NoItem(latestFetchedBlockTimestampB, chainId)) =>
    (itemA.timestamp, itemA.chainId) < (latestFetchedBlockTimestampB, chainId)
  | (NoItem(latestFetchedBlockTimestampA, chainId), Item(itemB)) =>
    (latestFetchedBlockTimestampA, chainId) < (itemB.timestamp, itemB.chainId)
  | (
      NoItem(latestFetchedBlockTimestampA, chainIdA),
      NoItem(latestFetchedBlockTimestampB, chainIdB),
    ) =>
    (latestFetchedBlockTimestampA, chainIdA) < (latestFetchedBlockTimestampB, chainIdB)
  }
}

type nextEventErr = NoItemsInArray

let determineNextEvent = (chainFetchersPeeks: array<ChainFetcher.eventQueuePeek>): result<
  ChainFetcher.eventQueuePeek,
  nextEventErr,
> => {
  let nextItem = chainFetchersPeeks->Belt.Array.reduce(None, (accum, valB) => {
    switch accum {
    | None => Some(valB)
    | Some(valA) =>
      if chainFetcherPeekComparitorEarliestEvent(valA, valB) {
        Some(valA)
      } else {
        Some(valB)
      }
    }
  })

  switch nextItem {
  | None => Error(NoItemsInArray)
  | Some(item) => Ok(item)
  }
}

let make = (~configs: Config.chainConfigs, ~maxQueueSize): t => {
  let chainFetchers =
    configs
    ->Js.Dict.entries
    ->Belt.Array.map(((key, chainConfig)) => {
      (
        key,
        ChainFetcher.make(
          ~chainConfig,
          ~maxQueueSize,
          ~chainWorkerTypeSelected=switch (Env.workerTypeSelected, chainConfig.syncSource) {
          | (RawEventsSelected, _) => RawEventsSelected
          | (_, Rpc(_)) => RpcSelected
          | (_, Skar(_)) => SkarSelected
          | (_, EthArchive(_)) => EthArchiveSelected
          },
        ),
      )
    })
    ->Js.Dict.fromArray
  {
    chainFetchers,
    arbitraryEventPriorityQueue: SDSL.PriorityQueue.makeAdvanced([], priorityQueueComparitor),
  }
}

let startFetchers = (self: t) => {
  self.chainFetchers
  ->Js.Dict.values
  ->Belt.Array.forEach(fetcher => {
    //Start the fetchers
    fetcher->ChainFetcher.startFetchingEvents->ignore
  })
}

exception UndefinedChain(Types.chainId)

let getChainFetcher = (self: t, ~chainId: int): ChainFetcher.t => {
  switch self.chainFetchers->Js.Dict.get(chainId->Belt.Int.toString) {
  | None =>
    Logging.error(`Undefined chain ${chainId->Belt.Int.toString} in chain manager`)
    UndefinedChain(chainId)->raise
  | Some(fetcher) => fetcher
  }
}

//Synchronus operation that returns an optional value and will not wait
//for a value to be on the queue
//TODO: investigate can this function + Async version below be combined to share
//logic
let popBatchItem = (self: t): option<Types.eventBatchQueueItem> => {
  //Peek all next fetched event queue items on all chain fetchers
  let peekChainFetcherFrontItems =
    self.chainFetchers
    ->Js.Dict.values
    ->Belt.Array.map(fetcher => fetcher->ChainFetcher.peekFrontItemOfQueue)

  //Compare the peeked items and determine the next item
  let nextItemFromBuffer = peekChainFetcherFrontItems->determineNextEvent->Belt.Result.getExn

  //Callback for handling popping of chain fetcher events
  let popNextItem = () => {
    switch nextItemFromBuffer {
    | ChainFetcher.NoItem(_, _) => None
    | ChainFetcher.Item(batchItem) =>
      //If there is an item pop it off of the chain fetcher queue and return
      let fetcher = self->getChainFetcher(~chainId=batchItem.chainId)
      fetcher->ChainFetcher.popQueueItem
    }
  }

  //Peek arbitraty events queue
  let peekedArbTopItem = self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.top

  switch peekedArbTopItem {
  //If there is item on the arbitray events queue, pop the relevant item from
  //the chain fetcher queue
  | None => popNextItem()
  | Some(peekedArbItem) =>
    //If there is an item on the arbitrary events queue, compare it to the next
    //item from the chain fetchers
    let arbItemIsEarlier = chainFetcherPeekComparitorEarliestEvent(
      ChainFetcher.Item(peekedArbItem),
      nextItemFromBuffer,
    )

    //If the arbitrary item is earlier, return that
    if arbItemIsEarlier {
      Some(
        //safely pop the item since we have already checked there's one at the front
        self.arbitraryEventPriorityQueue
        ->SDSL.PriorityQueue.pop
        ->Belt.Option.getUnsafe,
      )
    } else {
      //Else pop the next item from chain fetchers
      popNextItem()
    }
  }
}

let getChainIdFromBufferPeekItem = (peekItem: ChainFetcher.eventQueuePeek) => {
  switch peekItem {
  | ChainFetcher.NoItem(_, chainId) => chainId
  | ChainFetcher.Item(batchItem) => batchItem.chainId
  }
}
let getBlockNumberFromBufferPeekItem = (peekItem: ChainFetcher.eventQueuePeek) => {
  switch peekItem {
  | ChainFetcher.NoItem(_, _) => None
  | ChainFetcher.Item(batchItem) => Some(batchItem.blockNumber)
  }
}

type blockGroupedBatchItems = array<Types.eventBatchQueueItem>
let rec getAllBlockLogs = (
  self: t,
  bufferItem: ChainFetcher.eventQueuePeek,
  blockGroupedBatchItems: blockGroupedBatchItems,
) => {
  // Js.log({
  //   "blockGroupedBatchItems": blockGroupedBatchItems->Belt.Array.map(item => item.event),
  // })
  //Callback for handling popping of chain fetcher events
  let popNextItemOnChainQueueAndRecurse = () => {
    switch bufferItem {
    | ChainFetcher.NoItem(_, _) =>
      switch blockGroupedBatchItems {
      | [] => None
      | _ => Some(blockGroupedBatchItems)
      }

    | ChainFetcher.Item(batchItem) =>
      //If there is an item pop it off of the chain fetcher queue and return
      let fetcher = self->getChainFetcher(~chainId=batchItem.chainId)
      let _ = fetcher->ChainFetcher.popQueueItem

      let nextBlockGroupedBatchItems = blockGroupedBatchItems->Belt.Array.concat([batchItem])

      let peakedNextItem = fetcher->ChainFetcher.peekFrontItemOfQueue

      switch peakedNextItem {
      | ChainFetcher.NoItem(_, _) =>
        switch nextBlockGroupedBatchItems {
        | [] => None
        | _ => Some(nextBlockGroupedBatchItems)
        }
      | ChainFetcher.Item(peakedNextChainItem) =>
        if peakedNextChainItem.blockNumber == batchItem.blockNumber {
          // Js.log("continuing in recurse - sam block")
          getAllBlockLogs(self, peakedNextItem, nextBlockGroupedBatchItems)
        } else {
          // Js.log("Return early - next event is in different block.")
          Some(nextBlockGroupedBatchItems)
        }
      }
    }
  }

  //Peek arbitraty events queue
  let peekedArbTopItem = self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.top

  switch peekedArbTopItem {
  //If there is item on the arbitray events queue, pop the relevant item from
  //the chain fetcher queue
  | None =>
    // Js.log("The peekedArbTopItem is EMPTY")
    //Take next item from the given nextItem from buffer
    popNextItemOnChainQueueAndRecurse()
  | Some(peekedArbItem) =>
    // Js.log({"arbPeek": peekedArbItem.event})
    let arbEventIsInSameBlock =
      (peekedArbItem.chainId, Some(peekedArbItem.blockNumber)) ==
        (bufferItem->getChainIdFromBufferPeekItem, bufferItem->getBlockNumberFromBufferPeekItem)
    let arbItemIsEarlier = chainFetcherPeekComparitorEarliestEvent(
      ChainFetcher.Item(peekedArbItem),
      bufferItem, //nextItemFromBuffer,
    )

    // Js.log({
    //   "arbEventIsInSameBlock": arbEventIsInSameBlock,
    //   "arbItemIsEarlier": arbItemIsEarlier,
    // })

    if arbEventIsInSameBlock && arbItemIsEarlier {
      // Js.log("arb item is in same block but earlier")
      let _ = self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.pop

      let nextBlockGroupedBatchItems = blockGroupedBatchItems->Belt.Array.concat([peekedArbItem])

      let fetcher = self->getChainFetcher(~chainId=bufferItem->getChainIdFromBufferPeekItem)
      let peakedNextItem = fetcher->ChainFetcher.peekFrontItemOfQueue

      getAllBlockLogs(self, peakedNextItem, nextBlockGroupedBatchItems)
    } else if arbEventIsInSameBlock {
      // Js.log("is in same block but after")
      popNextItemOnChainQueueAndRecurse()
    } else if arbItemIsEarlier {
      // Js.log("is earier but different block")
      let rec addItemAndCheckNextItemForRecursion = item => {
        let _ = self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.pop
        let nextBlockGroupedBatchItems = blockGroupedBatchItems->Belt.Array.concat([item])

        let optPeekedArbItem = self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.top

        switch optPeekedArbItem {
        | Some(peekedArbItem) =>
          if (
            (peekedArbItem.chainId, peekedArbItem.blockNumber) == (item.chainId, item.blockNumber)
          ) {
            nextBlockGroupedBatchItems->Belt.Array.concat(
              addItemAndCheckNextItemForRecursion(peekedArbItem),
            )
          } else {
            nextBlockGroupedBatchItems
          }

        | None => nextBlockGroupedBatchItems
        }
      }

      Some(addItemAndCheckNextItemForRecursion(peekedArbItem))
    } else {
      // Js.log("after but different block")
      popNextItemOnChainQueueAndRecurse()
    }
  }
}
let popBlockBatchItems = (self: t): option<blockGroupedBatchItems> => {
  //Peek all next fetched event queue items on all chain fetchers
  let peekChainFetcherFrontItems =
    self.chainFetchers
    ->Js.Dict.values
    ->Belt.Array.map(fetcher => fetcher->ChainFetcher.peekFrontItemOfQueue)
  // Js.log({
  //   "topOfEachQueue": peekChainFetcherFrontItems->Belt.Array.map(a =>
  //     switch a {
  //     | ChainFetcher.Item(batchItem) => batchItem.event
  //     | ChainFetcher.NoItem(_, chainId) => `NO ITEM ${chainId->Obj.magic}`->Obj.magic
  //     }
  //   ),
  // })

  //Compare the peeked items and determine the next item
  let nextItemFromBuffer = peekChainFetcherFrontItems->determineNextEvent->Belt.Result.getExn
  // Js.log({
  //   "next buffer item": switch nextItemFromBuffer {
  //   | ChainFetcher.Item(batchItem) => batchItem.event
  //   | ChainFetcher.NoItem(_, chainId) => `NO ITEM ${chainId->Obj.magic}`->Obj.magic
  //   },
  // })

  getAllBlockLogs(self, nextItemFromBuffer, [])
}
let rec popBlockBatchAndAwaitItems = async (self: t): option<blockGroupedBatchItems> => {
  //Peek all next fetched event queue items on all chain fetchers
  let peekChainFetcherFrontItems =
    self.chainFetchers
    ->Js.Dict.values
    ->Belt.Array.map(fetcher => fetcher->ChainFetcher.peekFrontItemOfQueue)
  // Js.log({
  //   "topOfEachQueue": peekChainFetcherFrontItems->Belt.Array.map(a =>
  //     switch a {
  //     | ChainFetcher.Item(batchItem) => batchItem.event
  //     | ChainFetcher.NoItem(_, chainId) => `NO ITEM ${chainId->Obj.magic}`->Obj.magic
  //     }
  //   ),
  // })

  //Compare the peeked items and determine the next item
  let nextItemFromBuffer = peekChainFetcherFrontItems->determineNextEvent->Belt.Result.getExn
  // Js.log({
  //   "next buffer item": switch nextItemFromBuffer {
  //   | ChainFetcher.Item(batchItem) => batchItem.event
  //   | ChainFetcher.NoItem(_, chainId) => `NO ITEM ${chainId->Obj.magic}`->Obj.magic
  //   },
  // })

  switch nextItemFromBuffer {
  | ChainFetcher.NoItem(latestFullyFetchedBlockTimestampAcrossAllChains, chainId) =>
    //Peek arbitraty events queue
    let peekedArbTopItem = self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.top

    switch peekedArbTopItem {
    | Some(peekedArbItem)
      // If there is item on the arbitray events queue AND it is a lower timestamp that the lowest timestamp of any chain queue then pop it for the batch
      // the chain fetcher queue
      if peekedArbItem.timestamp <= latestFullyFetchedBlockTimestampAcrossAllChains =>
      getAllBlockLogs(self, nextItemFromBuffer, [])

    | None =>
      //If higest priority is a "NoItem", it means we need to wait for
      //that chain fetcher to fetch blocks of a higher timestamp
      let fetcher = self->getChainFetcher(~chainId)
      //Add a callback and wait for a new block range to finish being queried
      await fetcher->ChainFetcher.addNewRangeQueriedCallback
      //Once there is confirmation from the chain fetcher that a new range has been
      //queried retry the popAwait batch function
      await self->popBlockBatchAndAwaitItems
    }
  | ChainFetcher.Item(batchItem) => getAllBlockLogs(self, nextItemFromBuffer, [])
  }
}
//TODO: investigate combining logic with the above synchronus version of this function

/**
Async pop function that will wait for an item to be available before returning
*/
let rec popAndAwaitBatchItem: t => promise<Types.eventBatchQueueItem> = async (
  self: t,
): Types.eventBatchQueueItem => {
  //Peek all next fetched event queue items on all chain fetchers
  let peekChainFetcherFrontItems =
    self.chainFetchers
    ->Js.Dict.values
    ->Belt.Array.map(fetcher => fetcher->ChainFetcher.peekFrontItemOfQueue)

  //Compare the peeked items and determine the next item
  let nextItemFromBuffer = peekChainFetcherFrontItems->determineNextEvent->Belt.Result.getExn

  //Callback for handling popping of chain fetcher events
  let popNextItemAndAwait = async () => {
    switch nextItemFromBuffer {
    | ChainFetcher.NoItem(_, chainId) =>
      //If higest priority is a "NoItem", it means we need to wait for
      //that chain fetcher to fetch blocks of a higher timestamp
      let fetcher = self->getChainFetcher(~chainId)
      //Add a callback and wait for a new block range to finish being queried
      await fetcher->ChainFetcher.addNewRangeQueriedCallback
      //Once there is confirmation from the chain fetcher that a new range has been
      //queried retry the popAwait batch function
      await self->popAndAwaitBatchItem
    | ChainFetcher.Item(batchItem) =>
      //If there is an item pop it off of the chain fetcher queue and return
      let fetcher = self->getChainFetcher(~chainId=batchItem.chainId)
      await fetcher->ChainFetcher.popAndAwaitQueueItem
    }
  }

  //Peek arbitraty events queue
  let peekedArbTopItem = self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.top

  switch peekedArbTopItem {
  //If there is item on the arbitray events queue, pop the relevant item from
  //the chain fetcher queue
  | None => await popNextItemAndAwait()
  | Some(peekedArbItem) =>
    //If there is an item on the arbitrary events queue, compare it to the next
    //item from the chain fetchers
    let arbItemIsEarlier = chainFetcherPeekComparitorEarliestEvent(
      ChainFetcher.Item(peekedArbItem),
      nextItemFromBuffer,
    )

    //If the arbitrary item is earlier, return that
    if arbItemIsEarlier {
      //safely pop the item since we have already checked there's one at the front
      self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.pop->Belt.Option.getUnsafe
    } else {
      //Else pop the next item from chain fetchers
      await popNextItemAndAwait()
    }
  }
}

let createBatch = async (self: t, ~minBatchSize: int, ~maxBatchSize: int): array<
  Types.eventBatchQueueItem,
> => {
  let refTime = Hrtime.makeTimer()

  let batch = []
  while batch->Belt.Array.length < minBatchSize {
    let item = await self->popAndAwaitBatchItem
    batch->Js.Array2.push(item)->ignore
  }

  let moreItemsToPop = ref(true)
  while moreItemsToPop.contents && batch->Belt.Array.length < maxBatchSize {
    let optItem = self->popBatchItem
    switch optItem {
    | None => moreItemsToPop := false
    | Some(item) => batch->Js.Array2.push(item)->ignore
    }
  }
  let fetchedEventsBuffer =
    self.chainFetchers
    ->Js.Dict.values
    ->Belt.Array.map(fetcher => (
      fetcher.chainConfig.chainId->Belt.Int.toString,
      fetcher.fetchedEventQueue.queue->SDSL.Queue.size,
    ))
    ->Belt.Array.concat([
      ("arbitrary", self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.length),
    ])
    ->Js.Dict.fromArray

  let timeElapsed = refTime->Hrtime.timeSince->Hrtime.toMillis

  Logging.trace({
    "message": "New batch created for processing",
    "batch size": batch->Array.length,
    "buffers": fetchedEventsBuffer,
    "time taken (ms)": timeElapsed,
  })

  batch
}

let addItemToArbitraryEvents = (self: t, item: Types.eventBatchQueueItem) => {
  self.arbitraryEventPriorityQueue->SDSL.PriorityQueue.push(item)->ignore
}

// module Test = {
/* type t = {
  chainFetchers: Js.Dict.t<ChainFetcher.t>,
  //The priority queue should only house the latest event from each chain
  //And potentially extra events that are pushed on by newly registered dynamic
  //contracts which missed being fetched by they chainFetcher
  arbitraryEventPriorityQueue: SDSL.PriorityQueue.t<Types.eventBatchQueueItem>,
} */

let allEvents = []
let populateChainQueuesWithRandomEvents = () => {
  let numberOfChains = 3

  let arbitraryEventPriorityQueue = SDSL.PriorityQueue.makeAdvanced([], priorityQueueComparitor)
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
    let startTimestamp = endTimestamp - 1000000

    let averageBlockTime = getRandomInt(1, 15)
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
      Js.log2("queuesToUse", queuesToUse)
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

        let addItemToArbQueue = () => {
          Js.log({"new arb event": batchItem.event})
          arbitraryEventPriorityQueue->SDSL.PriorityQueue.push(batchItem)->ignore
        }
        let addItemToChainQueue = () => {
          Js.log({"new CHAIN event": batchItem.event})
          fetchedEventQueue.queue->SDSL.Queue.push(batchItem)->ignore
        }

        switch queuesToUse {
        | 0 => addItemToArbQueue()
        | 1 => addItemToChainQueue()
        | 2
        | _ =>
          if Js.Math.random() < 0.5 {
            addItemToArbQueue()
          } else {
            addItemToChainQueue()
          }
        }

        /* switch queuesToUse {
        | 0 => arbitraryEventPriorityQueue->SDSL.PriorityQueue.push(batchItem)->ignore
        | 1 => fetchedEventQueue.queue->SDSL.Queue.push(batchItem)->ignore
        | 2
        | _ =>
          if Js.Math.random() < 0.5 {
            arbitraryEventPriorityQueue->SDSL.PriorityQueue.push(batchItem)->ignore
          } else {
            fetchedEventQueue.queue->SDSL.Queue.push(batchItem)->ignore
          }
        }*/
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
      arbitraryEventPriorityQueue,
      chainFetchers,
    },
    numberOfMockEventsCreated.contents,
  )
}

let (mockChainManager, numberOfMockEventsCreated) = populateChainQueuesWithRandomEvents()
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
  let eventsInBlock = popBlockBatchItems(mockChainManager)
  Js.log3(
    "[BEG]recurse",
    eventsInBlock->Belt.Option.mapWithDefault("EMPTY"->Obj.magic, e =>
      e->Belt.Array.map(i => i.event)
    ),
    "[END]recurse",
  )

  // ensure that the events are ordered correctly
  switch eventsInBlock {
  | None => true
  | Some(eventsInBlock) =>
    eventsInBlock
    ->Belt.Array.map(i => {
      allEventsRead->Js.Array2.push(i)
    })
    ->ignore
    numberOfMockEventsReadFromQueues :=
      numberOfMockEventsReadFromQueues.contents + eventsInBlock->Belt.Array.length
    let firstEventInBlock = eventsInBlock->Belt.Array.getExn(0)

    // Check that events has at least 1 item in it
    if firstEventInBlock->getComparitorFromItem > lastEvent->getComparitorFromItem {
      ()
    } else {
      Js.log("there is an error")
    }

    let wasError = ref(false)

    let lastEvent =
      eventsInBlock
      ->Belt.Array.sliceToEnd(1)
      ->Belt.Array.reduce(firstEventInBlock, (previous, current) => {
        if previous.blockNumber != current.blockNumber {
          Js.log("\n\n!!!!!!!!!!!!!!!!!!!!\n\n\!!!!!!!!!!!!!!!!!!!!")
          Js.log2("We have a bug!", (previous.blockNumber, "!=", current.blockNumber))
          Js.log("\n\n!!!!!!!!!!!!!!!!!!!!\n\n\!!!!!!!!!!!!!!!!!!!!")
          wasError := true
        }

        // check for chainId etc.

        if current.logIndex > previous.logIndex {
          ()
        } else {
          Js.log("\n\n!!!!!!!!!!!!!!!!!!!!\n\n\!!!!!!!!!!!!!!!!!!!!")
          Js.log("\n\n!!!!!!!!!!!!!!!!!!!!\n\n\!!!!!!!!!!!!!!!!!!!!")
          Js.log("We have a bug! Incorrect log index")
          Js.log2(current.event, previous.event)
          Js.log("\n\n!!!!!!!!!!!!!!!!!!!!\n\n\!!!!!!!!!!!!!!!!!!!!")
          Js.log("\n\n!!!!!!!!!!!!!!!!!!!!\n\n\!!!!!!!!!!!!!!!!!!!!")
          wasError := true
        }
        Js.log("no issues")
        current
      })
    if !wasError.contents {
      testThatCreatedEventsAreOrderedCorrectly(lastEvent)
    } else {
      true
    }

  // let
  }
}
Js.log("before")
let _ = testThatCreatedEventsAreOrderedCorrectly(defaultFirstEvent)
Js.log("after")
// }

Js.log("hello")
let amountStillOnQueues =
  mockChainManager.arbitraryEventPriorityQueue->SDSL.PriorityQueue.length +
    mockChainManager.chainFetchers
    ->Js.Dict.values
    ->Belt.Array.reduce(0, (accum, val) => {
      accum + val.fetchedEventQueue.queue->SDSL.Queue.size
    })

Js.log4(
  amountStillOnQueues + numberOfMockEventsReadFromQueues.contents == numberOfMockEventsCreated,
  numberOfMockEventsReadFromQueues.contents,
  numberOfMockEventsCreated,
  amountStillOnQueues,
)
// Js.log({
//   "difference": numberOfMockEventsCreated - numberOfMockEventsReadFromQueues.contents,
//   "allEventsRead": allEventsRead->Belt.Array.map(i => i.event),
//   "eventsCreated": allEvents->Belt.Array.map(i => i.event),
//   "eventsOnArbChain": mockChainManager.arbitraryEventPriorityQueue
//   ->SDSL.PriorityQueue.toArray
//   ->Belt.Array.map(i => i.event),
//   "eventsOnChainQueues": mockChainManager.chainFetchers
//   ->Js.Dict.values
//   ->Js.Array2.map(chainFetcher => {
//     let length = chainFetcher.fetchedEventQueue.queue->SDSL.Queue.size
//
//     Belt.Array.make(length, 0)->Belt.Array.map(_ => {
//       chainFetcher.fetchedEventQueue.queue->SDSL.Queue.pop
//     })
//   }),
// })
// Test.populateChainQueuesWithRandomEvents()->ignore
