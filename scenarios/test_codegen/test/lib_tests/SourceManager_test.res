open Belt
open Vitest

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
  fn: (~knownHeight: int) => Promise.t<int>,
  calls: array<int>,
  resolveAll: int => unit,
  resolveFns: array<int => unit>,
}

let waitForNewBlockMock = () => {
  let calls = []
  let resolveFns = []
  {
    resolveAll: knownHeight => {
      resolveFns->Js.Array2.forEach(resolve => resolve(knownHeight))
    },
    fn: (~knownHeight) => {
      calls->Js.Array2.push(knownHeight)->ignore
      Promise.make((resolve, _reject) => {
        resolveFns->Js.Array2.push(resolve)->ignore
      })
    },
    calls,
    resolveFns,
  }
}

type onNewBlockMock = {
  fn: (~knownHeight: int) => unit,
  calls: array<int>,
}

let onNewBlockMock = () => {
  let calls = []

  {
    fn: (~knownHeight) => {
      calls->Js.Array2.push(knownHeight)->ignore
    },
    calls,
  }
}

describe("SourceManager creation", () => {
  it("Successfully creates with a sync source", () => {
    let source = Mock.Source.make([]).source
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)
    Assert.equal(sourceManager->SourceManager.getActiveSource, source)
  })

  it("Uses first sync source as initial active source", () => {
    let fallback = Mock.Source.make([], ~sourceFor=Fallback).source
    let sync0 = Mock.Source.make([]).source
    let sync1 = Mock.Source.make([]).source
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
          ~sources=[Mock.Source.make([], ~sourceFor=Fallback).source],
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
  let normalSelection = {FetchState.dependsOnAddresses: false, eventConfigs: []}

  let mockFullPartition = (
    ~partitionIndex,
    ~latestFetchedBlockNumber,
    ~numContracts=2,
  ): FetchState.partition => {
    let addressesByContractName = Js.Dict.empty()
    let addresses = []

    for i in 0 to numContracts - 1 {
      let address = TestHelpers.Addresses.mockAddresses[i]->Option.getExn
      addresses->Array.push(address)
    }

    addressesByContractName->Js.Dict.set("MockContract", addresses)

    {
      id: partitionIndex->Int.toString,
      latestFetchedBlock: {
        blockNumber: latestFetchedBlockNumber,
        blockTimestamp: latestFetchedBlockNumber * 15,
      },
      selection: normalSelection,
      addressesByContractName,
      mergeBlock: None,
      dynamicContract: None,
      mutPendingQueries: [],
      prevQueryRange: 0,
      prevPrevQueryRange: 0,
      latestBlockRangeUpdateBlock: 0,
    }
  }

  let mockFetchState = (
    partitions: array<FetchState.partition>,
    ~endBlock=None,
    ~buffer=[],
    ~targetBufferSize=5000,
    ~knownHeight,
  ): FetchState.t => {
    let indexingContracts = Js.Dict.empty()
    let latestFullyFetchedBlock = ref((partitions->Utils.Array.firstUnsafe).latestFetchedBlock)

    partitions->Array.forEach(partition => {
      if latestFullyFetchedBlock.contents.blockNumber > partition.latestFetchedBlock.blockNumber {
        latestFullyFetchedBlock := partition.latestFetchedBlock
      }
      partition.addressesByContractName
      ->Js.Dict.entries
      ->Array.forEach(
        ((contractName, addresses)) => {
          addresses->Array.forEach(
            address => {
              indexingContracts->Js.Dict.set(
                address->Address.toString,
                {
                  Internal.contractName,
                  startBlock: 0,
                  address,
                  registrationBlock: None,
                },
              )
            },
          )
        },
      )
    })

    let optimizedPartitions = FetchState.OptimizedPartitions.make(
      ~partitions,
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=partitions->Array.length,
      ~dynamicContracts=Utils.Set.make(),
    )

    {
      optimizedPartitions,
      startBlock: 0,
      endBlock,
      buffer,
      normalSelection,
      latestOnBlockBlockNumber: latestFullyFetchedBlock.contents.blockNumber,
      targetBufferSize,
      chainId: 0,
      indexingContracts,
      contractConfigs: Js.Dict.empty(),
      blockLag: 0,
      onBlockConfigs: [],
      knownHeight,
      firstEventBlock: None,
    }
  }

  let neverWaitForNewBlock = async (~knownHeight as _) =>
    Assert.fail("The waitForNewBlock shouldn't be called for the test")

  let neverOnNewBlock = (~knownHeight as _) =>
    Assert.fail("The onNewBlock shouldn't be called for the test")

  let neverExecutePartitionQuery = _ =>
    Assert.fail("The executeQuery shouldn't be called for the test")

  let source: Source.t = Mock.Source.make([]).source

  Async.it(
    "Executes full partitions in any order when we didn't reach concurency limit",
    async () => {
      let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

      let partition0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4)
      let partition1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)
      let partition2 = mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=1)

      let fetchState = mockFetchState([partition0, partition1, partition2], ~knownHeight=10)

      let executeQueryMock = executeQueryMock()

      let fetchNextPromise =
        sourceManager->SourceManager.fetchNext(
          ~fetchState,
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
            toBlock: None,
            isChunk: false,
            selection: normalSelection,
            addressesByContractName: partition2.addressesByContractName,
            indexingContracts: fetchState.indexingContracts,
          },
          {
            partitionId: "0",
            fromBlock: 5,
            toBlock: None,
            isChunk: false,
            selection: normalSelection,
            addressesByContractName: partition0.addressesByContractName,
            indexingContracts: fetchState.indexingContracts,
          },
          {
            partitionId: "1",
            fromBlock: 6,
            toBlock: None,
            isChunk: false,
            selection: normalSelection,
            addressesByContractName: partition1.addressesByContractName,
            indexingContracts: fetchState.indexingContracts,
          },
        ],
        ~message="This is automatically ordered in the current implementation, but not having it ordered won't be a problem as well",
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

      let fetchState = mockFetchState([partition0, partition1, partition2], ~knownHeight=10)

      let executeQueryMock = executeQueryMock()

      let fetchNextPromise =
        sourceManager->SourceManager.fetchNext(
          ~fetchState,
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
            toBlock: None,
            isChunk: false,
            selection: normalSelection,
            addressesByContractName: partition2.addressesByContractName,
            indexingContracts: fetchState.indexingContracts,
          },
          {
            partitionId: "0",
            fromBlock: 5,
            toBlock: None,
            isChunk: false,
            selection: normalSelection,
            addressesByContractName: partition0.addressesByContractName,
            indexingContracts: fetchState.indexingContracts,
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
    "Skips full partitions at the chain last block and the ones at the mergeBlock",
    async () => {
      let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

      let p0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4)
      let p1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)
      let p2 = mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=1)
      let p3 = mockFullPartition(~partitionIndex=3, ~latestFetchedBlockNumber=4)

      let executeQueryMock = executeQueryMock()

      let fetchNextPromise =
        sourceManager->SourceManager.fetchNext(
          ~fetchState=mockFetchState([p0, p1, p2, p3], ~endBlock=Some(5), ~knownHeight=4),
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
        ~fetchState=mockFetchState(
          [mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=0)],
          ~knownHeight=0,
        ),
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
        ~fetchState=mockFetchState(
          [mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=20)],
          ~knownHeight=20,
        ),
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

  Async.it("Waits for new block with knownHeight=0 even when all partitions are done", async () => {
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

    let waitForNewBlockMock = waitForNewBlockMock()
    let onNewBlockMock = onNewBlockMock()

    let fetchNextPromise1 =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState(
          [mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=5)],
          ~endBlock=Some(5),
          ~knownHeight=0,
        ),
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=onNewBlockMock.fn,
        ~stateId=0,
      )

    waitForNewBlockMock.resolveAll(20)

    await fetchNextPromise1

    Assert.deepEqual(waitForNewBlockMock.calls, [0])
    Assert.deepEqual(onNewBlockMock.calls, [20])
  })

  Async.it("Waits for new block when all partitions are at the knownHeight", async () => {
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

    let p0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=5)
    let p1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)

    let waitForNewBlockMock = waitForNewBlockMock()
    let onNewBlockMock = onNewBlockMock()

    let fetchNextPromise =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([p0, p1], ~knownHeight=5),
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=onNewBlockMock.fn,
        ~stateId=0,
      )

    Assert.deepEqual(waitForNewBlockMock.calls, [5])

    // Should do nothing on the second call with the same data
    await sourceManager->SourceManager.fetchNext(
      ~fetchState=mockFetchState([p0, p1], ~knownHeight=5),
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
        ~fetchState=mockFetchState([p0], ~knownHeight=5),
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    Assert.deepEqual(waitForNewBlockMock.calls, [5], ~message=`Should wait for new block`)

    // Should do nothing on the second call with the same data
    await sourceManager->SourceManager.fetchNext(
      ~fetchState=mockFetchState([p0], ~knownHeight=5),
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
        ~fetchState=mockFetchState([p0], ~knownHeight=5),
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

    (waitForNewBlockMock.resolveFns->Utils.Array.firstUnsafe)(7)
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
        ~fetchState=mockFetchState([p0, p1], ~knownHeight=10),
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    Assert.deepEqual(executeQueryMock.callIds, ["0", "1"])

    let fetchNextPromise2 =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([p0, p1, p2, p3], ~knownHeight=10),
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
      ~fetchState=mockFetchState([p0, p1, p2, p3], ~knownHeight=10),
      ~executeQuery=neverExecutePartitionQuery,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )
    // Even if we are in the next state,
    // can't do anything since we account
    // for running fetches from the prev state
    await sourceManager->SourceManager.fetchNext(
      ~fetchState=mockFetchState([p0, p1, p2, p3], ~knownHeight=10)->FetchState.resetPendingQueries,
      ~executeQuery=neverExecutePartitionQuery,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=1,
    )

    (executeQueryMock.resolveFns->Utils.Array.firstUnsafe)()
    (executeQueryMock.resolveFns->Js.Array2.unsafe_get(1))()

    // After resolving one the call with prev stateId won't do anything
    await sourceManager->SourceManager.fetchNext(
      ~fetchState=mockFetchState([p0, p1, p2, p3], ~knownHeight=10),
      ~executeQuery=neverExecutePartitionQuery,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )

    // The same call with stateId=1 will trigger execution of two earliest queries
    let fetchNextPromise3 =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState(
          [p0, p1, p2, p3],
          ~knownHeight=10,
        )->FetchState.resetPendingQueries,
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
      ~fetchState=mockFetchState(
        [
          mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=10),
          mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=10),
          p2,
          p3,
        ],
        ~knownHeight=10,
      ),
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
        ~fetchState=mockFetchState(
          [
            mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4),
            mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5),
            mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=1),
            mockFullPartition(~partitionIndex=3, ~latestFetchedBlockNumber=2),
            mockFullPartition(~partitionIndex=4, ~latestFetchedBlockNumber=3),
          ],
          ~buffer=[
            FetchState_onBlock_test.mockEvent(~blockNumber=1),
            FetchState_onBlock_test.mockEvent(~blockNumber=2),
            FetchState_onBlock_test.mockEvent(~blockNumber=3),
            FetchState_onBlock_test.mockEvent(~blockNumber=4),
            FetchState_onBlock_test.mockEvent(~blockNumber=5),
          ],
          ~targetBufferSize=4,
          ~knownHeight=10,
        ),
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    executeQueryMock.resolveAll()

    await fetchNextPromise

    Assert.deepEqual(
      executeQueryMock.callIds,
      ["2", "3", "4"],
      ~message="Should have skipped partitions that are at max queue size",
    )
  })

  Async.it("Sorts after all the filtering is applied", async () => {
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=1)

    let executeQueryMock = executeQueryMock()

    let fetchNextPromise = sourceManager->SourceManager.fetchNext(
      ~fetchState=mockFetchState(
        [
          // Finished fetching to mergeBlock
          mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=11),
          // Waiting for new block
          mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=10),
          mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=6),
          mockFullPartition(~partitionIndex=3, ~latestFetchedBlockNumber=4),
        ],
        ~endBlock=Some(11),
        ~knownHeight=10,
      ),
      ~executeQuery=executeQueryMock.fn,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )

    executeQueryMock.resolveAll()

    await fetchNextPromise

    Assert.deepEqual(executeQueryMock.callIds, ["3"])
  })
})

describe("SourceManager wait for new blocks", () => {
  Async.it(
    "Immediately resolves when the source height is higher than the current height",
    async () => {
      let {source, getHeightOrThrowCalls, resolveGetHeightOrThrow} = Mock.Source.make([
        #getHeightOrThrow,
      ])
      let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

      let p = sourceManager->SourceManager.waitForNewBlock(~knownHeight=0)

      Assert.deepEqual(getHeightOrThrowCalls->Array.length, 1)
      resolveGetHeightOrThrow(1)

      Assert.deepEqual(await p, 1)
    },
  )

  Async.it(
    "Calls all sync sources in parallel. Resolves the first one with valid response",
    async () => {
      let mock0 = Mock.Source.make([#getHeightOrThrow])
      let mock1 = Mock.Source.make([#getHeightOrThrow])
      let sourceManager = SourceManager.make(
        ~sources=[mock0.source, mock1.source],
        ~maxPartitionConcurrency=10,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~knownHeight=0)

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
    let mock0 = Mock.Source.make([#getHeightOrThrow], ~pollingInterval=pollingInterval0)
    let mock1 = Mock.Source.make([#getHeightOrThrow], ~pollingInterval=pollingInterval1)
    let sourceManager = SourceManager.make(
      ~sources=[mock0.source, mock1.source],
      ~maxPartitionConcurrency=10,
    )

    let p = sourceManager->SourceManager.waitForNewBlock(~knownHeight=100)

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

  Async.it("Retries on throw without affecting polling of other sources", async () => {
    let pollingInterval0 = 1
    let pollingInterval1 = 2
    let initialRetryInterval = 4
    let mock0 = Mock.Source.make([#getHeightOrThrow], ~pollingInterval=pollingInterval0)
    let mock1 = Mock.Source.make([#getHeightOrThrow], ~pollingInterval=pollingInterval1)
    let sourceManager = SourceManager.make(
      ~sources=[mock0.source, mock1.source],
      ~maxPartitionConcurrency=10,
      ~getHeightRetryInterval=SourceManager.makeGetHeightRetryInterval(
        ~initialRetryInterval,
        ~backoffMultiplicative=2,
        ~maxRetryInterval=10,
      ),
    )

    let p = sourceManager->SourceManager.waitForNewBlock(~knownHeight=100)

    let ((), ()) = await Promise.all2((
      (
        async () => {
          Assert.deepEqual(mock0.getHeightOrThrowCalls->Array.length, 1)

          mock0.rejectGetHeightOrThrow("ERROR")

          await Utils.delay(initialRetryInterval)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            1,
            ~message="Shouldn't immediately call getHeightOrThrow again",
          )
          await Utils.delay(0)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            2,
            ~message="Should call after a retry",
          )

          mock0.rejectGetHeightOrThrow("ERROR")

          await Utils.delay(initialRetryInterval * 2)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            2,
            ~message="Should increase the retry interval",
          )
          await Utils.delay(0)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            3,
            ~message="Should call after a longer retry",
          )

          mock0.rejectGetHeightOrThrow("ERROR")

          await Utils.delay(10)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            3,
            ~message="Should increase the retry interval but not exceed the max",
          )
          await Utils.delay(0)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            4,
            ~message="Should call after the max retry interval",
          )

          mock0.resolveGetHeightOrThrow(100)
          await Utils.delay(pollingInterval0 + 1)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            5,
            ~message="Should return to normal polling after a successful retry",
          )

          mock0.rejectGetHeightOrThrow("ERROR3")
          await Utils.delay(initialRetryInterval)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            5,
            ~message="Retry interval resets after a successful resolve",
          )
          await Utils.delay(0)
          Assert.deepEqual(
            mock0.getHeightOrThrowCalls->Array.length,
            6,
            ~message="Should call after a retry for error3",
          )
        }
      )(),
      // This is not affected by the source0 and done in parallel

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
      6,
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
      let sync = Mock.Source.make([#getHeightOrThrow], ~pollingInterval)
      let fallback = Mock.Source.make(~sourceFor=Fallback, [#getHeightOrThrow], ~pollingInterval)
      let sourceManager = SourceManager.make(
        ~sources=[sync.source, fallback.source],
        ~maxPartitionConcurrency=10,
        ~newBlockFallbackStallTimeout,
        ~stalledPollingInterval,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~knownHeight=100)

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

      let p = sourceManager->SourceManager.waitForNewBlock(~knownHeight=101)

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
      let sync = Mock.Source.make([#getHeightOrThrow], ~pollingInterval)

      let sourceManager = SourceManager.make(
        ~sources=[sync.source],
        ~maxPartitionConcurrency=10,
        ~newBlockFallbackStallTimeout,
        ~stalledPollingInterval,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~knownHeight=100)

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
describe("SourceManager.executeQuery", () => {
  let selection = {FetchState.dependsOnAddresses: false, eventConfigs: []}
  let addressesByContractName = Js.Dict.empty()

  let mockQuery = (): FetchState.query => {
    partitionId: "0",
    fromBlock: 0,
    toBlock: None,
    isChunk: false,
    selection,
    addressesByContractName,
    indexingContracts: Js.Dict.empty(),
  }

  Async.it("Successfully executes the query", async () => {
    let {source, getItemsOrThrowCalls, resolveGetItemsOrThrow} = Mock.Source.make([
      #getItemsOrThrow,
    ])
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)
    let p = sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~knownHeight=100)
    Assert.deepEqual(
      getItemsOrThrowCalls->Js.Array2.map(call => call.payload),
      [{"fromBlock": 0, "toBlock": None, "retry": 0, "p": "0"}],
    )
    resolveGetItemsOrThrow([])
    Assert.deepEqual((await p).parsedQueueItems, [])
  })

  Async.it("Rethrows unknown errors", async () => {
    let sourceMock = Mock.Source.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(
      ~sources=[sourceMock.source],
      ~maxPartitionConcurrency=10,
    )
    let p = sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~knownHeight=100)
    let error = {
      "message": "Something went wrong",
    }
    sourceMock.getItemsOrThrowCalls->Js.Array2.forEach(call => call.reject(error))
    await Assert.rejects(() => p, ~error)
  })

  Async.it("Immediately retries with the suggested toBlock", async () => {
    let sourceMock = Mock.Source.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(
      ~sources=[
        sourceMock.source,
        // Added second source without mock to the test,
        // to verify that we don't switch to it
        Mock.Source.make([]).source,
      ],
      ~maxPartitionConcurrency=10,
    )
    let p = sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~knownHeight=100)
    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls->Array.length,
      1,
      ~message="Should call getItemsOrThrow",
    )
    (sourceMock.getItemsOrThrowCalls->Utils.Array.firstUnsafe).reject(
      Source.GetItemsError(
        FailedGettingItems({
          exn: %raw(`null`),
          attemptedToBlock: 100,
          retry: WithSuggestedToBlock({toBlock: 10}),
        }),
      ),
    )
    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls->Array.length,
      0,
      ~message="No new calls before the microtask",
    )
    await Promise.resolve() // Wait for microtask, so the rejection is caught

    switch sourceMock.getItemsOrThrowCalls {
    | [call] => {
        Assert.deepEqual(
          call.payload,
          {"fromBlock": 0, "toBlock": Some(10), "retry": 0, "p": "0"},
          ~message=`Should reset retry count on WithSuggestedToBlock error`,
        )
        call.resolve([])
      }
    | _ => Assert.fail("Should have a new call after the microtask")
    }

    Assert.deepEqual((await p).parsedQueueItems, [])
  })

  Async.it(
    "When there are multiple sync sources, it retries 2 times and then immediately switches to another source without waiting for backoff. After that it switches every second retry",
    async () => {
      let sourceMock0 = Mock.Source.make([#getHeightOrThrow, #getItemsOrThrow])
      let sourceMock1 = Mock.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Fallback)
      let newBlockFallbackStallTimeout = 0
      let sourceManager = SourceManager.make(
        ~newBlockFallbackStallTimeout,
        ~sources=[
          sourceMock0.source,
          // Should be skipped until the 10th retry,
          // but we won't test it here
          Mock.Source.make([], ~sourceFor=Fallback).source,
          sourceMock1.source,
        ],
        ~maxPartitionConcurrency=10,
      )

      {
        // Switch the initial active source to fallback,
        // to test that it's included to the rotation
        let p = sourceManager->SourceManager.waitForNewBlock(~knownHeight=100)
        await Utils.delay(newBlockFallbackStallTimeout)
        sourceMock1.resolveGetHeightOrThrow(101)
        Assert.equal(await p, 101)
        Assert.equal(
          sourceManager->SourceManager.getActiveSource,
          sourceMock1.source,
          ~message="Should switch to the fallback source",
        )
      }

      let p = sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~knownHeight=100)

      let handledGetItemsOrThrowCalls = []

      for idx in 0 to 2 {
        switch sourceMock1.getItemsOrThrowCalls {
        | [call] => {
            handledGetItemsOrThrowCalls->Array.push({
              "fromBlock": call.payload["fromBlock"],
              "toBlock": call.payload["toBlock"],
              "retry": call.payload["retry"],
              "source": 1,
            })
            call.reject(
              Source.GetItemsError(
                FailedGettingItems({
                  exn: %raw(`null`),
                  attemptedToBlock: 100,
                  retry: WithBackoff({message: "test", backoffMillis: 0}),
                }),
              ),
            )
          }
        | _ => Assert.fail("Should have one pending call to sourceMock1")
        }

        // Wait for microtask, so the rejection is caught
        await Promise.resolve()
        if idx !== 2 {
          // Don't need to wait for backoff on switch
          await Utils.delay(0)
        }
      }

      switch sourceMock0.getItemsOrThrowCalls {
      | [call] => {
          handledGetItemsOrThrowCalls->Array.push({
            "fromBlock": call.payload["fromBlock"],
            "toBlock": call.payload["toBlock"],
            "retry": call.payload["retry"],
            "source": 0,
          })
          call.reject(
            Source.GetItemsError(
              FailedGettingItems({
                exn: %raw(`null`),
                attemptedToBlock: 100,
                retry: WithBackoff({message: "test", backoffMillis: 0}),
              }),
            ),
          )
        }
      | _ => Assert.fail("Should have one pending call to sourceMock0")
      }

      await Promise.resolve() // Wait for microtask, so the rejection is caught
      await Utils.delay(0)

      switch sourceMock0.getItemsOrThrowCalls {
      | [call] => {
          handledGetItemsOrThrowCalls->Array.push({
            "fromBlock": call.payload["fromBlock"],
            "toBlock": call.payload["toBlock"],
            "retry": call.payload["retry"],
            "source": 0,
          })
          call.reject(
            Source.GetItemsError(
              FailedGettingItems({
                exn: %raw(`null`),
                attemptedToBlock: 100,
                retry: WithBackoff({message: "test", backoffMillis: 0}),
              }),
            ),
          )
        }
      | _ => Assert.fail("Should have one pending call to sourceMock0")
      }

      await Promise.resolve()
      // Doesn't wait for backoff on switch

      switch sourceMock1.getItemsOrThrowCalls {
      | [call] => {
          handledGetItemsOrThrowCalls->Array.push({
            "fromBlock": call.payload["fromBlock"],
            "toBlock": call.payload["toBlock"],
            "retry": call.payload["retry"],
            "source": 1,
          })
          Assert.deepEqual(
            handledGetItemsOrThrowCalls,
            [
              {"fromBlock": 0, "toBlock": None, "retry": 0, "source": 1},
              {"fromBlock": 0, "toBlock": None, "retry": 1, "source": 1},
              {"fromBlock": 0, "toBlock": None, "retry": 2, "source": 1},
              {"fromBlock": 0, "toBlock": None, "retry": 3, "source": 0},
              {"fromBlock": 0, "toBlock": None, "retry": 4, "source": 0},
              {"fromBlock": 0, "toBlock": None, "retry": 5, "source": 1},
            ],
            ~message=`Should start with the initial active source and perform 3 tries.
After that it switches to another sync source.
The fallback source is skipped.
Then sources start switching every second retry.
The fallback sources not included in the rotation until the 10th retry,
but we still attempt the fallback source if it was the initial active source.
        `,
          )

          call.resolve([])
          Assert.deepEqual((await p).parsedQueueItems, [])
        }
      | _ => Assert.fail("Should have one pending call to sourceMock1")
      }
    },
  )
})

describe("SourceManager height subscription", () => {
  Async.it(
    "Creates subscription when getHeightOrThrow returns same height as knownHeight",
    async () => {
      let mock = Mock.Source.make([#getHeightOrThrow, #createHeightSubscription])
      let sourceManager = SourceManager.make(~sources=[mock.source], ~maxPartitionConcurrency=10)

      let p = sourceManager->SourceManager.waitForNewBlock(~knownHeight=100)

      // First call to getHeightOrThrow
      Assert.deepEqual(mock.getHeightOrThrowCalls->Array.length, 1)
      // Return the same height - should trigger subscription creation
      mock.resolveGetHeightOrThrow(100)

      // Wait for the subscription to be created
      await Utils.delay(0)

      Assert.deepEqual(
        mock.heightSubscriptionCalls->Array.length,
        1,
        ~message="Should have created a height subscription",
      )

      // Trigger new height from subscription
      mock.triggerHeightSubscription(101)

      Assert.deepEqual(await p, 101, ~message="Should resolve with the subscription height")
    },
  )

  Async.it("Uses cached height from subscription if higher than knownHeight", async () => {
    let mock = Mock.Source.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(~sources=[mock.source], ~maxPartitionConcurrency=10)

    // First call - create subscription
    let p1 = sourceManager->SourceManager.waitForNewBlock(~knownHeight=100)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    mock.triggerHeightSubscription(105)
    Assert.deepEqual(await p1, 105)

    // Second call - should use cached height immediately without calling getHeightOrThrow
    let p2 = sourceManager->SourceManager.waitForNewBlock(~knownHeight=101)
    Assert.deepEqual(
      mock.getHeightOrThrowCalls->Array.length,
      1,
      ~message="Should not call getHeightOrThrow again since subscription exists",
    )
    Assert.deepEqual(await p2, 105, ~message="Should immediately return cached height")
  })

  Async.it(
    "Waits for next height event when subscription exists but height <= knownHeight",
    async () => {
      let mock = Mock.Source.make([#getHeightOrThrow, #createHeightSubscription])
      let sourceManager = SourceManager.make(~sources=[mock.source], ~maxPartitionConcurrency=10)

      // First call - create subscription and set initial height
      let p1 = sourceManager->SourceManager.waitForNewBlock(~knownHeight=100)
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      mock.triggerHeightSubscription(101)
      Assert.deepEqual(await p1, 101)

      // Second call with higher knownHeight - should wait for next subscription event
      let p2 = sourceManager->SourceManager.waitForNewBlock(~knownHeight=101)
      Assert.deepEqual(
        mock.getHeightOrThrowCalls->Array.length,
        1,
        ~message="Should not call getHeightOrThrow since subscription exists",
      )

      // Trigger new height
      mock.triggerHeightSubscription(102)
      Assert.deepEqual(await p2, 102, ~message="Should wait for and resolve with new height")
    },
  )

  Async.it(
    "[flaky] Falls back to polling when createHeightSubscription is not available",
    async () => {
      let pollingInterval = 1
      let mock = Mock.Source.make([#getHeightOrThrow], ~pollingInterval)
      let sourceManager = SourceManager.make(~sources=[mock.source], ~maxPartitionConcurrency=10)

      let p = sourceManager->SourceManager.waitForNewBlock(~knownHeight=100)

      // Return same height - should trigger polling since no subscription available
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(pollingInterval + 1)

      Assert.deepEqual(
        mock.getHeightOrThrowCalls->Array.length,
        2,
        ~message="Should poll again since no subscription is available",
      )

      mock.resolveGetHeightOrThrow(101)
      Assert.deepEqual(await p, 101)
    },
  )

  Async.it("Ignores subscription heights lower than or equal to knownHeight", async () => {
    let mock = Mock.Source.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(~sources=[mock.source], ~maxPartitionConcurrency=10)

    // First call - create subscription
    let p1 = sourceManager->SourceManager.waitForNewBlock(~knownHeight=100)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    mock.triggerHeightSubscription(101)
    Assert.deepEqual(await p1, 101)

    // Second call with higher knownHeight
    let p2 = sourceManager->SourceManager.waitForNewBlock(~knownHeight=105)

    // Trigger with lower heights - should be ignored
    mock.triggerHeightSubscription(102)
    mock.triggerHeightSubscription(103)
    mock.triggerHeightSubscription(105) // Equal to knownHeight - should be ignored

    // Verify promise is still pending (not resolved with lower height)
    let resolved = ref(false)
    let _ = p2->Promise.thenResolve(
      _ => {
        resolved := true
      },
    )
    await Utils.delay(0)
    Assert.deepEqual(
      resolved.contents,
      false,
      ~message="Should not resolve with height <= knownHeight",
    )

    // Finally trigger with valid height
    mock.triggerHeightSubscription(106)
    Assert.deepEqual(await p2, 106, ~message="Should resolve with height > knownHeight")
  })
})
