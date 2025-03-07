open Belt
open RescriptMocha

type sourceMock = {
  source: Source.t,
  // Use array of bool instead of array of unit,
  // for better logging during debugging
  getHeightOrThrowCalls: array<bool>,
  resolveGetHeightOrThrow: int => unit,
}

let sourceMock = (~sourceFor=Source.Sync, ~mockGetHeightOrThrow=false, ~pollingInterval=1000) => {
  let getHeightOrThrowCalls = []
  let getHeightOrThrowResolveFns = []
  {
    getHeightOrThrowCalls,
    resolveGetHeightOrThrow: height => {
      getHeightOrThrowResolveFns->Array.forEach(resolve => resolve(height))
    },
    source: {
      {
        name: "MockSource",
        sourceFor,
        poweredByHyperSync: false,
        chain: ChainMap.Chain.makeUnsafe(~chainId=0),
        pollingInterval,
        getBlockHashes: (~blockNumbers as _, ~logger as _) =>
          Js.Exn.raiseError("The getBlockHashes not implemented"),
        getHeightOrThrow: if mockGetHeightOrThrow {
          () => {
            getHeightOrThrowCalls->Js.Array2.push(true)->ignore
            Promise.make((resolve, _reject) => {
              getHeightOrThrowResolveFns->Js.Array2.push(resolve)->ignore
            })
          }
        } else {
          _ => Js.Exn.raiseError("The getHeightOrThrow not implemented")
        },
        getItemsOrThrow: (
          ~fromBlock as _,
          ~toBlock as _,
          ~contractAddressMapping as _,
          ~currentBlockHeight as _,
          ~partitionId as _,
          ~selection as _,
          ~logger as _,
        ) => Js.Exn.raiseError("The getItemsOrThrow not implemented"),
      }
    },
  }
}

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
      ->Js.Array2.push(query.partitionId)
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
  fn: (~currentBlockHeight: int) => Promise.t<int>,
  calls: array<int>,
  resolveAll: int => unit,
  resolveFns: array<int => unit>,
}

let waitForNewBlockMock = () => {
  let calls = []
  let resolveFns = []
  {
    resolveAll: currentBlockHeight => {
      resolveFns->Js.Array2.forEach(resolve => resolve(currentBlockHeight))
    },
    fn: (~currentBlockHeight) => {
      calls->Js.Array2.push(currentBlockHeight)->ignore
      Promise.make((resolve, _reject) => {
        resolveFns->Js.Array2.push(resolve)->ignore
      })
    },
    calls,
    resolveFns,
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

describe("SourceManager creation", () => {
  it("Successfully creates with a sync source", () => {
    let source = sourceMock().source
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)
    Assert.equal(sourceManager->SourceManager.getActiveSource, source)
  })

  it("Uses first sync source as initial active source", () => {
    let fallback = sourceMock(~sourceFor=Fallback).source
    let sync0 = sourceMock().source
    let sync1 = sourceMock().source
    let sourceManager = SourceManager.make(
      ~sources=[fallback, sync0, sync1],
      ~maxPartitionConcurrency=10,
    )
    Assert.equal(sourceManager->SourceManager.getActiveSource, sync0)
  })

  it("Fails to create without sync sources", () => {
    Assert.throws(
      () => {
        SourceManager.make(~sources=[], ~maxPartitionConcurrency=10)
      },
      ~error={
        "message": "Invalid configuration, no data-source for historical sync provided",
      },
    )
    Assert.throws(
      () => {
        SourceManager.make(
          ~sources=[sourceMock(~sourceFor=Fallback).source],
          ~maxPartitionConcurrency=10,
        )
      },
      ~error={
        "message": "Invalid configuration, no data-source for historical sync provided",
      },
    )
  })
})

describe("SourceManager fetchNext", () => {
  let normalSelection = {FetchState.isWildcard: true, eventConfigs: []}

  let mockFullPartition = (
    ~partitionIndex,
    ~latestFetchedBlockNumber,
    ~numContracts=2,
    ~fetchedEventQueue=[],
  ): FetchState.partition => {
    let contractAddressMapping = ContractAddressingMap.make()

    for i in 0 to numContracts - 1 {
      let address = TestHelpers.Addresses.mockAddresses[i]->Option.getExn
      contractAddressMapping->ContractAddressingMap.addAddress(~name="MockContract", ~address)
    }

    {
      id: partitionIndex->Int.toString,
      status: {
        fetchingStateId: None,
      },
      latestFetchedBlock: {
        blockNumber: latestFetchedBlockNumber,
        blockTimestamp: latestFetchedBlockNumber * 15,
      },
      selection: normalSelection,
      contractAddressMapping,
      dynamicContracts: [],
      fetchedEventQueue,
    }
  }

  let mockFetchState = (partitions, ~endBlock=None): FetchState.t => {
    {
      partitions,
      endBlock,
      nextPartitionIndex: partitions->Array.length,
      maxAddrInPartition: 2,
      firstEventBlockNumber: None,
      queueSize: %raw(`null`),
      normalSelection,
      latestFullyFetchedBlock: %raw(`null`),
      isFetchingAtHead: false,
      // All the null values should be computed during updateInternal
    }->FetchState.updateInternal
  }

  let neverWaitForNewBlock = async (~currentBlockHeight as _) =>
    Assert.fail("The waitForNewBlock shouldn't be called for the test")

  let neverOnNewBlock = (~currentBlockHeight as _) =>
    Assert.fail("The onNewBlock shouldn't be called for the test")

  let neverExecutePartitionQuery = _ =>
    Assert.fail("The executeQuery shouldn't be called for the test")

  let source: Source.t = sourceMock().source

  Async.it(
    "Executes full partitions in any order when we didn't reach concurency limit",
    async () => {
      let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

      let partition0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4)
      let partition1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)
      let partition2 = mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=1)

      let fetchState = mockFetchState([partition0, partition1, partition2])

      let executeQueryMock = executeQueryMock()

      let fetchNextPromise =
        sourceManager->SourceManager.fetchNext(
          ~fetchState,
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
          {
            partitionId: "0",
            fromBlock: 5,
            target: Head,
            selection: normalSelection,
            contractAddressMapping: partition0.contractAddressMapping,
          },
          {
            partitionId: "1",
            fromBlock: 6,
            target: Head,
            selection: normalSelection,
            contractAddressMapping: partition1.contractAddressMapping,
          },
          {
            partitionId: "2",
            fromBlock: 2,
            target: Head,
            selection: normalSelection,
            contractAddressMapping: partition2.contractAddressMapping,
          },
        ],
      )

      executeQueryMock.resolveAll()

      await fetchNextPromise

      Assert.deepEqual(
        executeQueryMock.calls->Js.Array2.length,
        3,
        ~message="Shouldn't have called more after resolving prev promises",
      )
    },
  )

  Async.it(
    "Slices full partitions to the concurrency limit, takes the earliest queries first",
    async () => {
      let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=2)

      let partition0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4)
      let partition1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)
      let partition2 = mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=1)

      let fetchState = mockFetchState([partition0, partition1, partition2])

      let executeQueryMock = executeQueryMock()

      let fetchNextPromise =
        sourceManager->SourceManager.fetchNext(
          ~fetchState,
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
          {
            partitionId: "2",
            fromBlock: 2,
            target: Head,
            selection: normalSelection,
            contractAddressMapping: partition2.contractAddressMapping,
          },
          {
            partitionId: "0",
            fromBlock: 5,
            target: Head,
            selection: normalSelection,
            contractAddressMapping: partition0.contractAddressMapping,
          },
        ],
      )

      executeQueryMock.resolveAll()

      await fetchNextPromise

      Assert.deepEqual(
        executeQueryMock.calls->Js.Array2.length,
        2,
        ~message="Shouldn't have called more after resolving prev promises",
      )
    },
  )

  Async.it(
    "Skips full partitions at the chain last block and the ones at the endBlock",
    async () => {
      let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

      let p0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4)
      let p1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)
      let p2 = mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=1)
      let p3 = mockFullPartition(~partitionIndex=3, ~latestFetchedBlockNumber=4)

      let executeQueryMock = executeQueryMock()

      let fetchNextPromise =
        sourceManager->SourceManager.fetchNext(
          ~fetchState=mockFetchState([p0, p1, p2, p3], ~endBlock=Some(5)),
          ~maxPerChainQueueSize=1000,
          ~currentBlockHeight=4,
          ~executeQuery=executeQueryMock.fn,
          ~waitForNewBlock=neverWaitForNewBlock,
          ~onNewBlock=neverOnNewBlock,
          ~stateId=0,
        )

      Assert.deepEqual(executeQueryMock.callIds, ["2"])

      executeQueryMock.resolveAll()

      Assert.deepEqual(
        executeQueryMock.calls->Js.Array2.length,
        1,
        ~message="Shouldn't have called more after resolving prev promises",
      )

      await fetchNextPromise
    },
  )

  Async.it("Starts indexing from the initial state", async () => {
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

    let waitForNewBlockMock = waitForNewBlockMock()
    let onNewBlockMock = onNewBlockMock()

    let fetchNextPromise1 =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([
          mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=0),
        ]),
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
        ~fetchState=mockFetchState([
          mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=20),
        ]),
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
      let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

      let waitForNewBlockMock = waitForNewBlockMock()
      let onNewBlockMock = onNewBlockMock()

      let fetchNextPromise1 =
        sourceManager->SourceManager.fetchNext(
          ~fetchState=mockFetchState(
            [mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=5)],
            ~endBlock=Some(5),
          ),
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
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

    let p0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=5)
    let p1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)

    let waitForNewBlockMock = waitForNewBlockMock()
    let onNewBlockMock = onNewBlockMock()

    let fetchNextPromise =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([p0, p1]),
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
      ~fetchState=mockFetchState([p0, p1]),
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

  Async.it("Restarts waiting for new block after a rollback", async () => {
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

    let p0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=5)

    let waitForNewBlockMock = waitForNewBlockMock()
    let onNewBlockMock = onNewBlockMock()

    let fetchNextPromise =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([p0]),
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=5,
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    Assert.deepEqual(waitForNewBlockMock.calls, [5], ~message=`Should wait for new block`)

    // Should do nothing on the second call with the same data
    await sourceManager->SourceManager.fetchNext(
      ~fetchState=mockFetchState([p0]),
      ~maxPerChainQueueSize=1000,
      ~currentBlockHeight=5,
      ~executeQuery=neverExecutePartitionQuery,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )
    Assert.deepEqual(
      waitForNewBlockMock.calls,
      [5],
      ~message=`New call is not added with the same stateId`,
    )

    let fetchNextPromise2 =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([p0]),
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=5,
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=onNewBlockMock.fn,
        ~stateId=1,
      )
    Assert.deepEqual(
      waitForNewBlockMock.calls,
      [5, 5],
      ~message=`Should add a new call after a rollback`,
    )

    (waitForNewBlockMock.resolveFns->Js.Array2.unsafe_get(0))(7)
    (waitForNewBlockMock.resolveFns->Js.Array2.unsafe_get(1))(6)

    await fetchNextPromise
    await fetchNextPromise2

    Assert.deepEqual(
      onNewBlockMock.calls,
      [6],
      ~message=`Should invalidate the waitForNewBlock result with block height 7, which responded after the reorg rollback`,
    )
  })

  Async.it("Can add new partitions until the concurrency limit reached", async () => {
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=3)

    let p0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4)
    let p1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)
    let p2 = mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=2)
    let p3 = mockFullPartition(~partitionIndex=3, ~latestFetchedBlockNumber=1)

    let executeQueryMock = executeQueryMock()

    let fetchNextPromise1 =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([p0, p1]),
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=10,
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    Assert.deepEqual(executeQueryMock.callIds, ["0", "1"])

    let fetchNextPromise2 =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([p0, p1, p2, p3]),
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=10,
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    Assert.deepEqual(
      executeQueryMock.callIds,
      ["0", "1", "3"],
      ~message=`We repeated the fetchNext but now with p2 and p3,
      since p0 and p1 are already fetching, we have concurrency limit left as 1,
      so we choose p3 since it's more behind than p2`,
    )

    // The third call won't do anything, because the concurrency is reached
    await sourceManager->SourceManager.fetchNext(
      ~fetchState=mockFetchState([p0, p1, p2, p3]),
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
      ~fetchState=mockFetchState([p0, p1, p2, p3]),
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
      ~fetchState=mockFetchState([p0, p1, p2, p3]),
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
        ~fetchState=mockFetchState([p0, p1, p2, p3]),
        ~maxPerChainQueueSize=1000,
        ~currentBlockHeight=10,
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=1,
      )

    // Note how partitionId=3 was called again,
    // even though it's still fetching for the prev stateId
    Assert.deepEqual(executeQueryMock.callIds, ["0", "1", "3", "3", "2"])

    // But let's say partitions 0 and 1 were fetched to the known chain height
    // And all the fetching partitions are resolved
    executeQueryMock.resolveAll()

    // Partitions 2 and 3 should be ignored.
    // Eventhogh they are not fetching,
    // but we've alredy called them with the same query
    await sourceManager->SourceManager.fetchNext(
      ~fetchState=mockFetchState([
        mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=10),
        mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=10),
        p2,
        p3,
      ]),
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
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

    let executeQueryMock = executeQueryMock()

    let fetchNextPromise =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([
          mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4),
          mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5),
          mockFullPartition(
            ~partitionIndex=2,
            ~latestFetchedBlockNumber=1,
            ~fetchedEventQueue=["mockEvent1", "mockEvent2", "mockEvent3"]->Utils.magic,
          ),
          mockFullPartition(
            ~partitionIndex=3,
            ~latestFetchedBlockNumber=2,
            ~fetchedEventQueue=["mockEvent4", "mockEvent5"]->Utils.magic,
          ),
          mockFullPartition(~partitionIndex=4, ~latestFetchedBlockNumber=3),
        ]),
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
      ["0", "1", "4"],
      ~message="Should have skipped partitions that are at max queue size",
    )
  })

  Async.it("Sorts after all the filtering is applied", async () => {
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=1)

    let executeQueryMock = executeQueryMock()

    let fetchNextPromise = sourceManager->SourceManager.fetchNext(
      ~fetchState=mockFetchState(
        [
          // Exceeds max queue size
          mockFullPartition(
            ~partitionIndex=0,
            ~latestFetchedBlockNumber=0,
            ~fetchedEventQueue=["mockEvent1", "mockEvent2", "mockEvent3"]->Utils.magic,
          ),
          // Finished fetching to endBlock
          mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=11),
          // Waiting for new block
          mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=10),
          mockFullPartition(~partitionIndex=3, ~latestFetchedBlockNumber=6),
          mockFullPartition(~partitionIndex=4, ~latestFetchedBlockNumber=4),
        ],
        ~endBlock=Some(11),
      ),
      ~maxPerChainQueueSize=10, //each partition should therefore have a max of 2 events
      ~currentBlockHeight=10,
      ~executeQuery=executeQueryMock.fn,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )

    executeQueryMock.resolveAll()

    await fetchNextPromise

    Assert.deepEqual(executeQueryMock.callIds, ["4"])
  })
})

describe("SourceManager wait for new blocks", () => {
  Async.it(
    "Immediately resolves when the source height is higher than the current height",
    async () => {
      let {source, getHeightOrThrowCalls, resolveGetHeightOrThrow} = sourceMock(
        ~mockGetHeightOrThrow=true,
      )
      let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

      let p = sourceManager->SourceManager.waitForNewBlock(~currentBlockHeight=0)

      Assert.deepEqual(getHeightOrThrowCalls->Array.length, 1)
      resolveGetHeightOrThrow(1)

      Assert.deepEqual(await p, 1)
    },
  )

  Async.it(
    "Calls all sync sources in parallel. Resolves the first one with valid response",
    async () => {
      let mock0 = sourceMock(~mockGetHeightOrThrow=true)
      let mock1 = sourceMock(~mockGetHeightOrThrow=true)
      let sourceManager = SourceManager.make(
        ~sources=[mock0.source, mock1.source],
        ~maxPartitionConcurrency=10,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~currentBlockHeight=0)

      Assert.deepEqual(mock0.getHeightOrThrowCalls->Array.length, 1)
      Assert.deepEqual(mock1.getHeightOrThrowCalls->Array.length, 1)

      mock1.resolveGetHeightOrThrow(2)
      mock0.resolveGetHeightOrThrow(3)

      Assert.deepEqual(
        await p,
        2,
        // This can only be an issue if HyperSync switches to RPC
        // during the most first block height request,
        // but we don't allow both HyperSync and RPC for historical sync
        ~message="Even though mock0 resolved with higher value, mock1 was the first",
      )

      Assert.equal(
        sourceManager->SourceManager.getActiveSource,
        mock1.source,
        ~message=`Should also switch the active source`,
      )

      // No new calls
      Assert.deepEqual(mock0.getHeightOrThrowCalls->Array.length, 1)
      Assert.deepEqual(mock1.getHeightOrThrowCalls->Array.length, 1)
    },
  )

  Async.it("Start polling all sources with it's own rates if new block isn't found", async () => {
    let pollingInterval0 = 1
    let pollingInterval1 = 2
    let mock0 = sourceMock(~mockGetHeightOrThrow=true, ~pollingInterval=pollingInterval0)
    let mock1 = sourceMock(~mockGetHeightOrThrow=true, ~pollingInterval=pollingInterval1)
    let sourceManager = SourceManager.make(
      ~sources=[mock0.source, mock1.source],
      ~maxPartitionConcurrency=10,
    )

    let p = sourceManager->SourceManager.waitForNewBlock(~currentBlockHeight=100)

    let ((), ()) = await Promise.all2((
      (
        async () => {
          Assert.deepEqual(mock0.getHeightOrThrowCalls->Array.length, 1)
          mock0.resolveGetHeightOrThrow(100)

          await Utils.delay(pollingInterval0)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            1,
            ~message="Shouldn't immediately call getHeightOrThrow again",
          )
          await Utils.delay(0)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            2,
            ~message="Should call after a polling interval",
          )

          mock0.resolveGetHeightOrThrow(100)
          await Utils.delay(pollingInterval0 + 1)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            3,
            ~message="Should have a second round",
          )
        }
      )(),
      (
        async () => {
          Assert.deepEqual(mock1.getHeightOrThrowCalls->Array.length, 1)
          mock1.resolveGetHeightOrThrow(100)

          await Utils.delay(pollingInterval1)
          Assert.deepEqual(
            mock1.getHeightOrThrowCalls->Array.length,
            1,
            ~message="Shouldn't immediately call getHeightOrThrow again",
          )
          await Utils.delay(0)
          Assert.deepEqual(
            mock1.getHeightOrThrowCalls->Array.length,
            2,
            ~message="Should call after a polling interval",
          )

          mock1.resolveGetHeightOrThrow(100)
          await Utils.delay(pollingInterval1 + 1)
          Assert.deepEqual(
            mock1.getHeightOrThrowCalls->Array.length,
            3,
            ~message="Should have a second round",
          )
        }
      )(),
    ))

    mock0.resolveGetHeightOrThrow(101)
    mock1.resolveGetHeightOrThrow(100)

    Assert.deepEqual(await p, 101)

    await Utils.delay(
      // Time during which a new polling should definetely happen
      pollingInterval0 + pollingInterval1,
    )
    Assert.deepEqual(
      mock0.getHeightOrThrowCalls->Array.length,
      3,
      ~message="Polling for source 0 should stop after successful response",
    )
    Assert.deepEqual(
      mock1.getHeightOrThrowCalls->Array.length,
      3,
      ~message="Polling for source 1 should stop after successful response",
    )
  })

  Async.it(
    "Starts polling the fallback source after the newBlockFallbackStallTimeout",
    async () => {
      let pollingInterval = 1
      let stalledPollingInterval = 2
      let newBlockFallbackStallTimeout = 8
      let sync = sourceMock(~mockGetHeightOrThrow=true, ~pollingInterval)
      let fallback = sourceMock(~sourceFor=Fallback, ~mockGetHeightOrThrow=true, ~pollingInterval)
      let sourceManager = SourceManager.make(
        ~sources=[sync.source, fallback.source],
        ~maxPartitionConcurrency=10,
        ~newBlockFallbackStallTimeout,
        ~stalledPollingInterval,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~currentBlockHeight=100)

      Assert.deepEqual(sync.getHeightOrThrowCalls->Array.length, 1)
      Assert.deepEqual(fallback.getHeightOrThrowCalls->Array.length, 0)
      sync.resolveGetHeightOrThrow(100)

      await Utils.delay(pollingInterval + 1)
      Assert.deepEqual(
        sync.getHeightOrThrowCalls->Array.length,
        2,
        ~message="Should call after a polling interval",
      )
      Assert.deepEqual(
        fallback.getHeightOrThrowCalls->Array.length,
        0,
        ~message="Fallback is still not called",
      )

      await Utils.delay(newBlockFallbackStallTimeout)
      Assert.deepEqual(
        sync.getHeightOrThrowCalls->Array.length,
        2,
        ~message="Shouldn't increase, since the request is still pending",
      )
      Assert.deepEqual(
        fallback.getHeightOrThrowCalls->Array.length,
        1,
        ~message="Should start polling the fallback source",
      )

      sync.resolveGetHeightOrThrow(100)
      fallback.resolveGetHeightOrThrow(100)

      // After newBlockFallbackStallTimeout, the polling interval should be
      // increased to stalledPollingInterval for both sync and fallback sources
      await Utils.delay(stalledPollingInterval)
      Assert.deepEqual(
        sync.getHeightOrThrowCalls->Array.length,
        2,
        ~message="Sync source should still wait for the polling interval",
      )
      Assert.deepEqual(
        fallback.getHeightOrThrowCalls->Array.length,
        1,
        ~message="Fallback source should still wait for the polling interval",
      )
      await Utils.delay(0)
      Assert.deepEqual(
        sync.getHeightOrThrowCalls->Array.length,
        3,
        ~message="Should call after stalledPollingInterval",
      )
      Assert.deepEqual(
        fallback.getHeightOrThrowCalls->Array.length,
        2,
        ~message="Should call after stalledPollingInterval",
      )

      fallback.resolveGetHeightOrThrow(101)

      Assert.deepEqual(await p, 101, ~message="Returns the fallback source response")

      Assert.equal(
        sourceManager->SourceManager.getActiveSource,
        fallback.source,
        ~message=`Changes the active source to the fallback`,
      )

      await Utils.delay(
        // Time during which a new polling should definetely happen
        stalledPollingInterval + 1,
      )
      Assert.deepEqual(
        sync.getHeightOrThrowCalls->Array.length,
        3,
        ~message="Polling for sync source should stop after successful response",
      )
      Assert.deepEqual(
        fallback.getHeightOrThrowCalls->Array.length,
        2,
        ~message="Polling for fallback source should stop after successful response",
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~currentBlockHeight=101)

      Assert.deepEqual(
        sync.getHeightOrThrowCalls->Array.length,
        4,
        ~message="Should call on the next waitForNewBlock",
      )
      Assert.deepEqual(
        fallback.getHeightOrThrowCalls->Array.length,
        3,
        ~message=`Even if the source is a fallback - it's currently active.
        Since we don't wait for a timeout again in case
        all main sync sources are still not valid,
        we immediately call the active source on the next waitForNewBlock.`,
      )

      sync.resolveGetHeightOrThrow(102)

      Assert.deepEqual(await p, 102, ~message="Returns the sync source response")

      Assert.equal(
        sourceManager->SourceManager.getActiveSource,
        sync.source,
        ~message=`Changes the active source back to the sync`,
      )

      await Utils.delay(
        // Time during which a new polling should definetely happen
        stalledPollingInterval + 1,
      )
      Assert.deepEqual(
        sync.getHeightOrThrowCalls->Array.length,
        4,
        ~message="Polling for sync source should stop after successful response",
      )
      Assert.deepEqual(
        fallback.getHeightOrThrowCalls->Array.length,
        3,
        ~message="Polling for fallback source should stop after successful response",
      )
    },
  )

  Async.it(
    "Continues polling even after newBlockFallbackStallTimeout when there are no fallback sources",
    async () => {
      let pollingInterval = 1
      let stalledPollingInterval = 2
      let newBlockFallbackStallTimeout = 8
      let sync = sourceMock(~mockGetHeightOrThrow=true, ~pollingInterval)

      let sourceManager = SourceManager.make(
        ~sources=[sync.source],
        ~maxPartitionConcurrency=10,
        ~newBlockFallbackStallTimeout,
        ~stalledPollingInterval,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~currentBlockHeight=100)

      Assert.deepEqual(sync.getHeightOrThrowCalls->Array.length, 1)
      sync.resolveGetHeightOrThrow(100)

      await Utils.delay(pollingInterval + 1)
      Assert.deepEqual(
        sync.getHeightOrThrowCalls->Array.length,
        2,
        ~message="Should call after a polling interval",
      )

      await Utils.delay(newBlockFallbackStallTimeout)
      Assert.deepEqual(
        sync.getHeightOrThrowCalls->Array.length,
        2,
        ~message="Shouldn't increase, since the request is still pending",
      )

      sync.resolveGetHeightOrThrow(100)

      // After newBlockFallbackStallTimeout, the polling interval should be
      // increased to stalledPollingInterval for both sync and fallback sources
      await Utils.delay(stalledPollingInterval)
      Assert.deepEqual(
        sync.getHeightOrThrowCalls->Array.length,
        2,
        ~message="Sync source should still wait for the polling interval",
      )
      await Utils.delay(0)
      Assert.deepEqual(
        sync.getHeightOrThrowCalls->Array.length,
        3,
        ~message="Should call after stalledPollingInterval",
      )

      sync.resolveGetHeightOrThrow(101)

      Assert.deepEqual(await p, 101, ~message="Returns the sync source response")
    },
  )
})
