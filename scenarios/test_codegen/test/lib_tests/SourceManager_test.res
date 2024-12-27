open Belt
open RescriptMocha

type executeQueryMock = {
  fn: FetchState.query => Promise.t<unit>,
  calls: array<FetchState.query>,
  callIds: array<string>,
  resolveAll: unit => unit,
  resolveFns: array<unit => unit>,
}

let executeQueryMock = () => {
  let calls = []
  let callIds = []
  let resolveFns = []
  {
    resolveFns,
    resolveAll: () => {
      resolveFns->Js.Array2.forEach(resolve => resolve())
    },
    fn: query => {
      calls->Js.Array2.push(query)->ignore
      callIds
      ->Js.Array2.push(
        switch query {
        | PartitionQuery(query) => "pq-" ++ query.partitionId->Int.toString
        | MergeQuery(query) => "mq-" ++ query.partitionId->Int.toString
        },
      )
      ->ignore
      Promise.make((resolve, _reject) => {
        resolveFns->Js.Array2.push(resolve)->ignore
      })
    },
    callIds,
    calls,
  }
}

type waitForNewBlockMock = {
  fn: (~currentBlockHeight: int, ~logger: Pino.t) => Promise.t<int>,
  calls: array<int>,
  resolveAll: int => unit,
}

let waitForNewBlockMock = () => {
  let calls = []
  let resolveFns = []
  {
    resolveAll: currentBlockHeight => {
      resolveFns->Js.Array2.forEach(resolve => resolve(currentBlockHeight))
    },
    fn: (~currentBlockHeight, ~logger as _) => {
      calls->Js.Array2.push(currentBlockHeight)->ignore
      Promise.make((resolve, _reject) => {
        resolveFns->Js.Array2.push(resolve)->ignore
      })
    },
    calls,
  }
}

type onNewBlockMock = {
  fn: (~currentBlockHeight: int) => unit,
  calls: array<int>,
}

let onNewBlockMock = () => {
  let calls = []

  {
    fn: (~currentBlockHeight) => {
      calls->Js.Array2.push(currentBlockHeight)->ignore
    },
    calls,
  }
}

describe("SourceManager fetchNext", () => {
  let mockFetchState = (
    ~partitionId,
    ~latestFetchedBlockNumber,
    ~fetchedEventQueue=[],
    ~numContracts=1,
  ): FetchState.t => {
    let contractAddressMapping = ContractAddressingMap.make()

    for i in 0 to numContracts - 1 {
      let address = TestHelpers.Addresses.mockAddresses[i]->Option.getExn
      contractAddressMapping->ContractAddressingMap.addAddress(~address, ~name="MockContract")
    }

    let register: FetchState.register = {
      id: FetchState.rootRegisterId,
      latestFetchedBlock: {
        blockNumber: latestFetchedBlockNumber,
        blockTimestamp: latestFetchedBlockNumber * 15,
      },
      contractAddressMapping,
      fetchedEventQueue,
      dynamicContracts: FetchState.DynamicContractsMap.empty,
      firstEventBlockNumber: None,
    }

    {
      partitionId,
      responseCount: 0,
      registers: [register],
      mostBehindRegister: register,
      nextMostBehindRegister: None,
      isFetchingAtHead: false,
      pendingDynamicContracts: [],
    }
  }

  let neverWaitForNewBlock = async (~currentBlockHeight as _, ~logger as _) =>
    Assert.fail("The waitForNewBlock shouldn't be called for the test")

  let neverOnNewBlock = (~currentBlockHeight as _) =>
    Assert.fail("The onNewBlock shouldn't be called for the test")

  let neverExecutePartitionQuery = _ =>
    Assert.fail("The executeQuery shouldn't be called for the test")

  Async.it("Executes partitions in any order when we didn't reach concurency limit", async () => {
    let sourceManager = SourceManager.make(
      ~maxPartitionConcurrency=10,
      ~endBlock=None,
      ~logger=Logging.logger,
    )

    let fetchState0 = mockFetchState(~partitionId=0, ~latestFetchedBlockNumber=4)
    let fetchState1 = mockFetchState(~partitionId=1, ~latestFetchedBlockNumber=5)
    let fetchState2 = mockFetchState(~partitionId=2, ~latestFetchedBlockNumber=1)

    let executeQueryMock = executeQueryMock()

    let fetchNextPromise =
      sourceManager->SourceManager.fetchNext(
        ~allPartitions=[fetchState0, fetchState1, fetchState2],
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=10,
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    Assert.deepEqual(
      executeQueryMock.calls,
      [
        PartitionQuery({
          partitionId: 0,
          idempotencyKey: 0,
          fetchStateRegisterId: fetchState0.mostBehindRegister.id,
          fromBlock: 5,
          toBlock: None,
          contractAddressMapping: fetchState0.mostBehindRegister.contractAddressMapping,
        }),
        PartitionQuery({
          partitionId: 1,
          idempotencyKey: 0,
          fetchStateRegisterId: fetchState0.mostBehindRegister.id,
          fromBlock: 6,
          toBlock: None,
          contractAddressMapping: fetchState0.mostBehindRegister.contractAddressMapping,
        }),
        PartitionQuery({
          partitionId: 2,
          idempotencyKey: 0,
          fetchStateRegisterId: fetchState0.mostBehindRegister.id,
          fromBlock: 2,
          toBlock: None,
          contractAddressMapping: fetchState0.mostBehindRegister.contractAddressMapping,
        }),
      ],
    )

    executeQueryMock.resolveAll()

    await fetchNextPromise

    Assert.deepEqual(
      executeQueryMock.calls->Js.Array2.length,
      3,
      ~message="Shouldn't have called more after resolving prev promises",
    )
  })

  Async.it(
    "Slices partitions to the concurrency limit, takes the earliest queries first",
    async () => {
      let sourceManager = SourceManager.make(
        ~maxPartitionConcurrency=2,
        ~endBlock=None,
        ~logger=Logging.logger,
      )

      let fetchState0 = mockFetchState(~partitionId=0, ~latestFetchedBlockNumber=4)
      let fetchState1 = mockFetchState(~partitionId=1, ~latestFetchedBlockNumber=5)
      let fetchState2 = mockFetchState(~partitionId=2, ~latestFetchedBlockNumber=1)

      let executeQueryMock = executeQueryMock()

      let fetchNextPromise =
        sourceManager->SourceManager.fetchNext(
          ~allPartitions=[fetchState0, fetchState1, fetchState2],
          ~maxPerChainQueueSize=1000,
          ~currentBlockHeight=10,
          ~executeQuery=executeQueryMock.fn,
          ~waitForNewBlock=neverWaitForNewBlock,
          ~onNewBlock=neverOnNewBlock,
          ~stateId=0,
        )

      Assert.deepEqual(executeQueryMock.callIds, ["pq-2", "pq-0"])

      executeQueryMock.resolveAll()

      await fetchNextPromise

      Assert.deepEqual(
        executeQueryMock.calls->Js.Array2.length,
        2,
        ~message="Shouldn't have called more after resolving prev promises",
      )
    },
  )

  Async.it("Skips partitions at the chain last block and the ones at the endBlock", async () => {
    let sourceManager = SourceManager.make(
      ~maxPartitionConcurrency=10,
      ~endBlock=Some(5),
      ~logger=Logging.logger,
    )

    let fetchState0 = mockFetchState(~partitionId=0, ~latestFetchedBlockNumber=4)
    let fetchState1 = mockFetchState(~partitionId=1, ~latestFetchedBlockNumber=5)
    let fetchState2 = mockFetchState(~partitionId=2, ~latestFetchedBlockNumber=1)
    let fetchState3 = mockFetchState(~partitionId=3, ~latestFetchedBlockNumber=4)

    let executeQueryMock = executeQueryMock()

    let fetchNextPromise =
      sourceManager->SourceManager.fetchNext(
        ~allPartitions=[fetchState0, fetchState1, fetchState2, fetchState3],
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=4,
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    Assert.deepEqual(executeQueryMock.callIds, ["pq-2"])

    executeQueryMock.resolveAll()

    Assert.deepEqual(
      executeQueryMock.calls->Js.Array2.length,
      1,
      ~message="Shouldn't have called more after resolving prev promises",
    )

    await fetchNextPromise
  })

  Async.it("Starts indexing from the initial state", async () => {
    let sourceManager = SourceManager.make(
      ~maxPartitionConcurrency=10,
      ~endBlock=None,
      ~logger=Logging.logger,
    )

    let waitForNewBlockMock = waitForNewBlockMock()
    let onNewBlockMock = onNewBlockMock()

    let fetchNextPromise1 =
      sourceManager->SourceManager.fetchNext(
        ~allPartitions=[mockFetchState(~partitionId=0, ~latestFetchedBlockNumber=0)],
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=0,
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=onNewBlockMock.fn,
        ~stateId=0,
      )

    waitForNewBlockMock.resolveAll(20)

    await fetchNextPromise1

    Assert.deepEqual(waitForNewBlockMock.calls, [0])
    Assert.deepEqual(onNewBlockMock.calls, [20])

    // Can wait the second time
    let fetchNextPromise2 =
      sourceManager->SourceManager.fetchNext(
        ~allPartitions=[mockFetchState(~partitionId=0, ~latestFetchedBlockNumber=20)],
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=20,
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=onNewBlockMock.fn,
        ~stateId=0,
      )

    waitForNewBlockMock.resolveAll(40)

    await fetchNextPromise2

    Assert.deepEqual(waitForNewBlockMock.calls, [0, 20])
    Assert.deepEqual(onNewBlockMock.calls, [20, 40])
  })

  Async.it(
    "Waits for new block with currentBlockHeight=0 even when all partitions are done",
    async () => {
      let sourceManager = SourceManager.make(
        ~maxPartitionConcurrency=10,
        ~endBlock=Some(5),
        ~logger=Logging.logger,
      )

      let waitForNewBlockMock = waitForNewBlockMock()
      let onNewBlockMock = onNewBlockMock()

      let fetchNextPromise1 =
        sourceManager->SourceManager.fetchNext(
          ~allPartitions=[mockFetchState(~partitionId=0, ~latestFetchedBlockNumber=5)],
          ~maxPerChainQueueSize=1000,
          ~currentBlockHeight=0,
          ~executeQuery=neverExecutePartitionQuery,
          ~waitForNewBlock=waitForNewBlockMock.fn,
          ~onNewBlock=onNewBlockMock.fn,
          ~stateId=0,
        )

      waitForNewBlockMock.resolveAll(20)

      await fetchNextPromise1

      Assert.deepEqual(waitForNewBlockMock.calls, [0])
      Assert.deepEqual(onNewBlockMock.calls, [20])
    },
  )

  Async.it("Waits for new block when all partitions are at the currentBlockHeight", async () => {
    let sourceManager = SourceManager.make(
      ~maxPartitionConcurrency=10,
      ~endBlock=None,
      ~logger=Logging.logger,
    )

    let fetchState0 = mockFetchState(~partitionId=0, ~latestFetchedBlockNumber=5)
    let fetchState1 = mockFetchState(~partitionId=1, ~latestFetchedBlockNumber=5)

    let waitForNewBlockMock = waitForNewBlockMock()
    let onNewBlockMock = onNewBlockMock()

    let fetchNextPromise =
      sourceManager->SourceManager.fetchNext(
        ~allPartitions=[fetchState0, fetchState1],
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=5,
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=onNewBlockMock.fn,
        ~stateId=0,
      )

    Assert.deepEqual(waitForNewBlockMock.calls, [5])

    // Should do nothing on the second call with the same data
    await sourceManager->SourceManager.fetchNext(
      ~allPartitions=[fetchState0, fetchState1],
      ~maxPerChainQueueSize=1000,
      ~currentBlockHeight=5,
      ~executeQuery=neverExecutePartitionQuery,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )

    Assert.deepEqual(onNewBlockMock.calls, [])
    waitForNewBlockMock.resolveAll(6)

    await Promise.resolve()
    Assert.deepEqual(onNewBlockMock.calls, [6])

    await fetchNextPromise

    Assert.deepEqual(waitForNewBlockMock.calls->Js.Array2.length, 1)
    Assert.deepEqual(onNewBlockMock.calls->Js.Array2.length, 1)
  })

  Async.it("Can add new partitions until the concurrency limit reached", async () => {
    let sourceManager = SourceManager.make(
      ~maxPartitionConcurrency=3,
      ~endBlock=None,
      ~logger=Logging.logger,
    )

    let fetchState0 = mockFetchState(~partitionId=0, ~latestFetchedBlockNumber=4)
    let fetchState1 = mockFetchState(~partitionId=1, ~latestFetchedBlockNumber=5)
    let fetchState2 = mockFetchState(~partitionId=2, ~latestFetchedBlockNumber=2)
    let fetchState3 = mockFetchState(~partitionId=3, ~latestFetchedBlockNumber=1)

    let executeQueryMock = executeQueryMock()

    let fetchNextPromise1 =
      sourceManager->SourceManager.fetchNext(
        ~allPartitions=[fetchState0, fetchState1],
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=10,
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    Assert.deepEqual(executeQueryMock.callIds, ["pq-0", "pq-1"])

    let fetchNextPromise2 =
      sourceManager->SourceManager.fetchNext(
        ~allPartitions=[fetchState0, fetchState1, fetchState2, fetchState3],
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=10,
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    Assert.deepEqual(executeQueryMock.callIds, ["pq-0", "pq-1", "pq-3"])

    // The third call won't do anything, because the concurrency is reached
    await sourceManager->SourceManager.fetchNext(
      ~allPartitions=[fetchState0, fetchState1, fetchState2, fetchState3],
      ~maxPerChainQueueSize=1000,
      ~currentBlockHeight=10,
      ~executeQuery=neverExecutePartitionQuery,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )
    // Even if we are in the next state,
    // can't do anything since we account
    // for running fetches from the prev state
    await sourceManager->SourceManager.fetchNext(
      ~allPartitions=[fetchState0, fetchState1, fetchState2, fetchState3],
      ~maxPerChainQueueSize=1000,
      ~currentBlockHeight=10,
      ~executeQuery=neverExecutePartitionQuery,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=1,
    )

    (executeQueryMock.resolveFns->Js.Array2.unsafe_get(0))()
    (executeQueryMock.resolveFns->Js.Array2.unsafe_get(1))()

    // After resolving one the call with prev stateId won't do anything
    await sourceManager->SourceManager.fetchNext(
      ~allPartitions=[fetchState0, fetchState1, fetchState2, fetchState3],
      ~maxPerChainQueueSize=1000,
      ~currentBlockHeight=10,
      ~executeQuery=neverExecutePartitionQuery,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )

    // The same call with stateId=1 will trigger execution of two earliest queries
    let fetchNextPromise3 =
      sourceManager->SourceManager.fetchNext(
        ~allPartitions=[fetchState0, fetchState1, fetchState2, fetchState3],
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=10,
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=1,
      )

    // Note how partitionId=3 was called again,
    // even though it's still fetching for the prev stateId
    Assert.deepEqual(executeQueryMock.callIds, ["pq-0", "pq-1", "pq-3", "pq-3", "pq-2"])

    // But let's say partitions 0 and 1 were fetched to the known chain height
    // And all the fetching partitions are resolved
    executeQueryMock.resolveAll()

    // Partitions 2 and 3 should be ignored.
    // Eventhogh they are not fetching,
    // but we've alredy called them with the same query
    await sourceManager->SourceManager.fetchNext(
      ~allPartitions=[
        mockFetchState(~partitionId=0, ~latestFetchedBlockNumber=10),
        mockFetchState(~partitionId=1, ~latestFetchedBlockNumber=10),
        fetchState2,
        fetchState3,
      ],
      ~maxPerChainQueueSize=1000,
      ~currentBlockHeight=10,
      ~executeQuery=neverExecutePartitionQuery,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )

    await fetchNextPromise1
    await fetchNextPromise2
    await fetchNextPromise3

    Assert.deepEqual(
      executeQueryMock.calls->Js.Array2.length,
      5,
      ~message="Shouldn't have called more after resolving prev promises",
    )
  })

  Async.it("Should not query partitions that are at max queue size", async () => {
    let sourceManager = SourceManager.make(
      ~maxPartitionConcurrency=10,
      ~endBlock=None,
      ~logger=Logging.logger,
    )

    let executeQueryMock = executeQueryMock()

    let fetchNextPromise =
      sourceManager->SourceManager.fetchNext(
        ~allPartitions=[
          mockFetchState(~partitionId=0, ~latestFetchedBlockNumber=4),
          mockFetchState(~partitionId=1, ~latestFetchedBlockNumber=5),
          mockFetchState(
            ~partitionId=2,
            ~latestFetchedBlockNumber=1,
            ~fetchedEventQueue=["mockEvent1", "mockEvent2", "mockEvent3"]->Utils.magic,
          ),
          mockFetchState(
            ~partitionId=3,
            ~latestFetchedBlockNumber=2,
            ~fetchedEventQueue=["mockEvent4", "mockEvent5"]->Utils.magic,
          ),
          mockFetchState(~partitionId=4, ~latestFetchedBlockNumber=3),
        ],
        ~maxPerChainQueueSize=10, //each partition should therefore have a max of 2 events
        ~currentBlockHeight=10,
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    executeQueryMock.resolveAll()

    await fetchNextPromise

    Assert.deepEqual(
      executeQueryMock.callIds,
      ["pq-0", "pq-1", "pq-4"],
      ~message="Should have skipped partitions that are at max queue size",
    )
  })

  Async.it("Sorts after all the filtering is applied", async () => {
    let sourceManager = SourceManager.make(
      ~maxPartitionConcurrency=1,
      ~endBlock=Some(11),
      ~logger=Logging.logger,
    )

    let executeQueryMock = executeQueryMock()

    let fetchNextPromise = sourceManager->SourceManager.fetchNext(
      ~allPartitions=[
        // Exceeds max queue size
        mockFetchState(
          ~partitionId=0,
          ~latestFetchedBlockNumber=0,
          ~fetchedEventQueue=["mockEvent1", "mockEvent2", "mockEvent3"]->Utils.magic,
        ),
        // Finished fetching to endBlock
        mockFetchState(~partitionId=1, ~latestFetchedBlockNumber=11),
        // Waiting for new block
        mockFetchState(~partitionId=2, ~latestFetchedBlockNumber=10),
        mockFetchState(~partitionId=3, ~latestFetchedBlockNumber=6),
        mockFetchState(~partitionId=4, ~latestFetchedBlockNumber=4),
      ],
      ~maxPerChainQueueSize=10, //each partition should therefore have a max of 2 events
      ~currentBlockHeight=10,
      ~executeQuery=executeQueryMock.fn,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )

    executeQueryMock.resolveAll()

    await fetchNextPromise

    Assert.deepEqual(executeQueryMock.callIds, ["pq-4"])
  })
})
