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
  it("Successfully creates with a sync source", t => {
    let source = Mock.Source.make([]).source
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(source)
  })

  it("Uses first sync source as initial active source", t => {
    let fallback = Mock.Source.make([], ~sourceFor=Fallback).source
    let sync0 = Mock.Source.make([]).source
    let sync1 = Mock.Source.make([]).source
    let sourceManager = SourceManager.make(
      ~sources=[fallback, sync0, sync1],
      ~maxPartitionConcurrency=10,
    )
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(sync0)
  })

  it("Uses live source as initial active source in live mode", t => {
    let fallback = Mock.Source.make([], ~sourceFor=Fallback).source
    let live = Mock.Source.make([], ~sourceFor=Live).source
    let sourceManager = SourceManager.make(
      ~sources=[fallback, live],
      ~maxPartitionConcurrency=10,
      ~isLive=true,
    )
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(live)
  })

  it("Prefers sync source over live source as initial active source", t => {
    let live = Mock.Source.make([], ~sourceFor=Live).source
    let sync = Mock.Source.make([]).source
    let sourceManager = SourceManager.make(
      ~sources=[live, sync],
      ~maxPartitionConcurrency=10,
    )
    // Sync is always preferred as initial active source (backfill mode)
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(sync)
  })

  it("Fails to create without primary sources", t => {
    t.expect(
      () => {
        SourceManager.make(~sources=[], ~maxPartitionConcurrency=10)
      },
    ).toThrowError("Invalid configuration, no data-source for historical sync provided")
    t.expect(
      () => {
        SourceManager.make(
          ~sources=[Mock.Source.make([], ~sourceFor=Fallback).source],
          ~maxPartitionConcurrency=10,
        )
      },
    ).toThrowError("Invalid configuration, no data-source for historical sync provided")
  })
})

describe("SourceManager.getSourceRole", () => {
  it("Backfill (isLive=false): Sync is Primary, Fallback is Secondary, Live is ignored", t => {
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Sync, ~isLive=false, ~hasLive=false),
    ).toEqual(Some(Primary))
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Fallback, ~isLive=false, ~hasLive=false),
    ).toEqual(Some(Secondary))
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Live, ~isLive=false, ~hasLive=false),
    ).toEqual(None)
    // hasLive doesn't matter during backfill
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Sync, ~isLive=false, ~hasLive=true),
    ).toEqual(Some(Primary))
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Live, ~isLive=false, ~hasLive=true),
    ).toEqual(None)
  })

  it(
    "Live mode with Live source: Live is Primary, Sync+Fallback are Secondary",
    t => {
      t.expect(
        SourceManager.getSourceRole(~sourceFor=Live, ~isLive=true, ~hasLive=true),
      ).toEqual(Some(Primary))
      t.expect(
        SourceManager.getSourceRole(~sourceFor=Sync, ~isLive=true, ~hasLive=true),
      ).toEqual(Some(Secondary))
      t.expect(
        SourceManager.getSourceRole(~sourceFor=Fallback, ~isLive=true, ~hasLive=true),
      ).toEqual(Some(Secondary))
    },
  )

  it(
    "Live mode without Live source: Sync is Primary, Fallback is Secondary",
    t => {
      t.expect(
        SourceManager.getSourceRole(~sourceFor=Sync, ~isLive=true, ~hasLive=false),
      ).toEqual(Some(Primary))
      t.expect(
        SourceManager.getSourceRole(~sourceFor=Fallback, ~isLive=true, ~hasLive=false),
      ).toEqual(Some(Secondary))
    },
  )
})

describe("SourceManager.hasLiveSource", () => {
  it("Returns false when no live sources exist", t => {
    let sync = Mock.Source.make([]).source
    let fallback = Mock.Source.make([], ~sourceFor=Fallback).source
    let sm = SourceManager.make(~sources=[sync, fallback], ~maxPartitionConcurrency=10)
    t.expect(sm->SourceManager.hasLiveSource).toEqual(false)
  })

  it("Returns true when a live source exists", t => {
    let sync = Mock.Source.make([]).source
    let live = Mock.Source.make([], ~sourceFor=Live).source
    let sm = SourceManager.make(~sources=[sync, live], ~maxPartitionConcurrency=10)
    t.expect(sm->SourceManager.hasLiveSource).toEqual(true)
  })
})

describe("SourceManager source priority with Live sources", () => {
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

  Async.it(
    "During isLive=true with Live source: Live is primary, Sync+Fallback are secondary in waitForNewBlock",
    async t => {
      let syncMock = Mock.Source.make([#getHeightOrThrow])
      let liveMock = Mock.Source.make([#getHeightOrThrow], ~sourceFor=Live)
      let fallbackMock = Mock.Source.make([#getHeightOrThrow], ~sourceFor=Fallback)
      let newBlockFallbackStallTimeoutLive = 5
      let sourceManager = SourceManager.make(
        ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
        ~newBlockFallbackStallTimeoutLive,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)

      // Live is primary - should be called immediately
      t.expect(
        liveMock.getHeightOrThrowCalls->Array.length,
        ~message="Live source should be called as primary",
      ).toEqual(1)
      // Sync and Fallback are secondary - should NOT be called yet
      t.expect(
        syncMock.getHeightOrThrowCalls->Array.length,
        ~message="Sync source should not be called yet (secondary)",
      ).toEqual(0)
      t.expect(
        fallbackMock.getHeightOrThrowCalls->Array.length,
        ~message="Fallback source should not be called yet (secondary)",
      ).toEqual(0)

      liveMock.resolveGetHeightOrThrow(101)

      t.expect(await p).toEqual(101)
      t.expect(sourceManager->SourceManager.getActiveSource).toBe(liveMock.source)
    },
  )

  Async.it(
    "During isLive=true with Live source: Sync and Fallback are used as secondary after timeout",
    async t => {
      let syncMock = Mock.Source.make([#getHeightOrThrow])
      let liveMock = Mock.Source.make([#getHeightOrThrow], ~sourceFor=Live)
      let fallbackMock = Mock.Source.make([#getHeightOrThrow], ~sourceFor=Fallback)
      let newBlockFallbackStallTimeoutLive = 5
      let sourceManager = SourceManager.make(
        ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
        ~newBlockFallbackStallTimeoutLive,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)

      // Live doesn't find new block
      liveMock.resolveGetHeightOrThrow(100)

      // Wait for stall timeout
      await Utils.delay(newBlockFallbackStallTimeoutLive)

      // After timeout, Sync and Fallback should be called as secondaries
      t.expect(
        syncMock.getHeightOrThrowCalls->Array.length,
        ~message="Sync source should be called after stall timeout",
      ).toEqual(1)
      t.expect(
        fallbackMock.getHeightOrThrowCalls->Array.length,
        ~message="Fallback source should be called after stall timeout",
      ).toEqual(1)

      syncMock.resolveGetHeightOrThrow(101)

      t.expect(await p).toEqual(101)
      t.expect(sourceManager->SourceManager.getActiveSource).toBe(syncMock.source)
    },
  )

  Async.it(
    "During isLive=true with Live source: recovery from secondary goes to Live",
    async t => {
      let syncMock = Mock.Source.make([#getHeightOrThrow, #getItemsOrThrow])
      let liveMock = Mock.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Live)
      let fallbackMock = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow],
        ~sourceFor=Fallback,
      )
      let newBlockFallbackStallTimeoutLive = 0
      let fallbackRecoveryTimeout = 5
      let sourceManager = SourceManager.make(
        ~newBlockFallbackStallTimeoutLive,
        ~fallbackRecoveryTimeout,
        ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
      )

      // Switch to fallback via waitForNewBlock with isLive=true
      {
        let p = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)
        await Utils.delay(newBlockFallbackStallTimeoutLive)
        fallbackMock.resolveGetHeightOrThrow(101)
        t.expect(await p).toBe(101)
        t.expect(sourceManager->SourceManager.getActiveSource).toBe(fallbackMock.source)
      }

      // Wait for fallback recovery timeout to elapse
      await Utils.delay(fallbackRecoveryTimeout)

      // Run a successful query on fallback — should trigger recovery
      {
        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=true,
            ~knownHeight=100,
          )
        switch fallbackMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => Js.Exn.raiseError("Expected one pending call to fallbackMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should recover to Live source (primary when isLive=true), not Sync",
      ).toBe(liveMock.source)
    },
  )

  Async.it(
    "During isLive=true without Live source: Sync is primary, Fallback is secondary",
    async t => {
      let syncMock = Mock.Source.make([#getHeightOrThrow])
      let fallbackMock = Mock.Source.make([#getHeightOrThrow], ~sourceFor=Fallback)
      let sourceManager = SourceManager.make(
        ~sources=[syncMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=0)

      t.expect(
        syncMock.getHeightOrThrowCalls->Array.length,
        ~message="Sync should be called as primary when no live source exists",
      ).toEqual(1)
      t.expect(
        fallbackMock.getHeightOrThrowCalls->Array.length,
        ~message="Fallback should not be called yet",
      ).toEqual(0)

      syncMock.resolveGetHeightOrThrow(1)
      t.expect(await p).toEqual(1)
    },
  )
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
    Js.Exn.raiseError("The waitForNewBlock shouldn't be called for the test")

  let neverOnNewBlock = (~knownHeight as _) =>
    Js.Exn.raiseError("The onNewBlock shouldn't be called for the test")

  let neverExecutePartitionQuery = _ =>
    Js.Exn.raiseError("The executeQuery shouldn't be called for the test")

  let source: Source.t = Mock.Source.make([]).source

  Async.it(
    "Executes full partitions in any order when we didn't reach concurency limit",
    async t => {
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

      t.expect(
        executeQueryMock.calls,
        ~message="This is automatically ordered in the current implementation, but not having it ordered won't be a problem as well",
      ).toEqual(
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
      )

      executeQueryMock.resolveAll()

      await fetchNextPromise

      t.expect(
        executeQueryMock.calls->Js.Array2.length,
        ~message="Shouldn't have called more after resolving prev promises",
      ).toEqual(
        3,
      )
    },
  )

  Async.it(
    "Slices full partitions to the concurrency limit, takes the earliest queries first",
    async t => {
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

      t.expect(
        executeQueryMock.calls,
      ).toEqual(
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

      t.expect(
        executeQueryMock.calls->Js.Array2.length,
        ~message="Shouldn't have called more after resolving prev promises",
      ).toEqual(
        2,
      )
    },
  )

  Async.it(
    "Skips full partitions at the chain last block and the ones at the mergeBlock",
    async t => {
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

      t.expect(executeQueryMock.callIds).toEqual(["2"])

      executeQueryMock.resolveAll()

      t.expect(
        executeQueryMock.calls->Js.Array2.length,
        ~message="Shouldn't have called more after resolving prev promises",
      ).toEqual(
        1,
      )

      await fetchNextPromise
    },
  )

  Async.it("Starts indexing from the initial state", async t => {
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

    t.expect(waitForNewBlockMock.calls).toEqual([0])
    t.expect(onNewBlockMock.calls).toEqual([20])

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

    t.expect(waitForNewBlockMock.calls).toEqual([0, 20])
    t.expect(onNewBlockMock.calls).toEqual([20, 40])
  })

  Async.it("Waits for new block with knownHeight=0 even when all partitions are done", async t => {
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

    t.expect(waitForNewBlockMock.calls).toEqual([0])
    t.expect(onNewBlockMock.calls).toEqual([20])
  })

  Async.it("Waits for new block when all partitions are at the knownHeight", async t => {
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

    t.expect(waitForNewBlockMock.calls).toEqual([5])

    // Should do nothing on the second call with the same data
    await sourceManager->SourceManager.fetchNext(
      ~fetchState=mockFetchState([p0, p1], ~knownHeight=5),
      ~executeQuery=neverExecutePartitionQuery,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )

    t.expect(onNewBlockMock.calls).toEqual([])
    waitForNewBlockMock.resolveAll(6)

    await Promise.resolve()
    t.expect(onNewBlockMock.calls).toEqual([6])

    await fetchNextPromise

    t.expect(waitForNewBlockMock.calls->Js.Array2.length).toEqual(1)
    t.expect(onNewBlockMock.calls->Js.Array2.length).toEqual(1)
  })

  Async.it("Restarts waiting for new block after a rollback", async t => {
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

    t.expect(waitForNewBlockMock.calls, ~message=`Should wait for new block`).toEqual([5])

    // Should do nothing on the second call with the same data
    await sourceManager->SourceManager.fetchNext(
      ~fetchState=mockFetchState([p0], ~knownHeight=5),
      ~executeQuery=neverExecutePartitionQuery,
      ~waitForNewBlock=neverWaitForNewBlock,
      ~onNewBlock=neverOnNewBlock,
      ~stateId=0,
    )
    t.expect(
      waitForNewBlockMock.calls,
      ~message=`New call is not added with the same stateId`,
    ).toEqual(
      [5],
    )

    let fetchNextPromise2 =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([p0], ~knownHeight=5),
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=onNewBlockMock.fn,
        ~stateId=1,
      )
    t.expect(
      waitForNewBlockMock.calls,
      ~message=`Should add a new call after a rollback`,
    ).toEqual(
      [5, 5],
    )

    (waitForNewBlockMock.resolveFns->Utils.Array.firstUnsafe)(7)
    (waitForNewBlockMock.resolveFns->Js.Array2.unsafe_get(1))(6)

    await fetchNextPromise
    await fetchNextPromise2

    t.expect(
      onNewBlockMock.calls,
      ~message=`Should invalidate the waitForNewBlock result with block height 7, which responded after the reorg rollback`,
    ).toEqual(
      [6],
    )
  })

  Async.it("Can add new partitions until the concurrency limit reached", async t => {
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

    t.expect(executeQueryMock.callIds).toEqual(["0", "1"])

    let fetchNextPromise2 =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([p0, p1, p2, p3], ~knownHeight=10),
        ~executeQuery=executeQueryMock.fn,
        ~waitForNewBlock=neverWaitForNewBlock,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    t.expect(
      executeQueryMock.callIds,
      ~message=`We repeated the fetchNext but now with p2 and p3,
      since p0 and p1 are already fetching, we have concurrency limit left as 1,
      so we choose p3 since it's more behind than p2`,
    ).toEqual(
      ["0", "1", "3"],
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
    t.expect(executeQueryMock.callIds).toEqual(["0", "1", "3", "3", "2"])

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

    t.expect(
      executeQueryMock.calls->Js.Array2.length,
      ~message="Shouldn't have called more after resolving prev promises",
    ).toEqual(
      5,
    )
  })

  Async.it("Should not query partitions that are at max queue size", async t => {
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

    t.expect(
      executeQueryMock.callIds,
      ~message="Should have skipped partitions that are at max queue size",
    ).toEqual(
      ["2", "3", "4"],
    )
  })

  Async.it("Sorts after all the filtering is applied", async t => {
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

    t.expect(executeQueryMock.callIds).toEqual(["3"])
  })
})

describe("SourceManager wait for new blocks", () => {
  Async.it(
    "Immediately resolves when the source height is higher than the current height",
    async t => {
      let {source, getHeightOrThrowCalls, resolveGetHeightOrThrow} = Mock.Source.make([
        #getHeightOrThrow,
      ])
      let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=0)

      t.expect(getHeightOrThrowCalls->Array.length).toEqual(1)
      resolveGetHeightOrThrow(1)

      t.expect(await p).toEqual(1)
    },
  )

  Async.it(
    "Calls all sync sources in parallel. Resolves the first one with valid response",
    async t => {
      let mock0 = Mock.Source.make([#getHeightOrThrow])
      let mock1 = Mock.Source.make([#getHeightOrThrow])
      let sourceManager = SourceManager.make(
        ~sources=[mock0.source, mock1.source],
        ~maxPartitionConcurrency=10,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=0)

      t.expect(mock0.getHeightOrThrowCalls->Array.length).toEqual(1)
      t.expect(mock1.getHeightOrThrowCalls->Array.length).toEqual(1)

      mock1.resolveGetHeightOrThrow(2)
      mock0.resolveGetHeightOrThrow(3)

      t.expect(
        await p,
        // This can only be an issue if HyperSync switches to RPC
        // during the most first block height request,
        // but we don't allow both HyperSync and RPC for historical sync
        ~message="Even though mock0 resolved with higher value, mock1 was the first",
      ).toEqual(
        2,
      )

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message=`Should also switch the active source`,
      ).toBe(
        mock1.source,
      )

      // No new calls
      t.expect(mock0.getHeightOrThrowCalls->Array.length).toEqual(1)
      t.expect(mock1.getHeightOrThrowCalls->Array.length).toEqual(1)
    },
  )

  Async.it(
    "Excludes live source from height fetch when isLive is false",
    async t => {
      let syncMock = Mock.Source.make([#getHeightOrThrow])
      let liveMock = Mock.Source.make([#getHeightOrThrow], ~sourceFor=Live)
      let sourceManager = SourceManager.make(
        ~sources=[syncMock.source, liveMock.source],
        ~maxPartitionConcurrency=10,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=0)

      t.expect(
        syncMock.getHeightOrThrowCalls->Array.length,
        ~message="Should call sync source",
      ).toEqual(1)
      t.expect(
        liveMock.getHeightOrThrowCalls->Array.length,
        ~message="Should not call live source when isLive is false",
      ).toEqual(0)

      syncMock.resolveGetHeightOrThrow(1)
      t.expect(await p).toEqual(1)
      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should stay on sync source",
      ).toBe(syncMock.source)
    },
  )

  Async.it(
    "Includes live source in height fetch when isLive is true",
    async t => {
      let syncMock = Mock.Source.make([#getHeightOrThrow])
      let liveMock = Mock.Source.make([#getHeightOrThrow], ~sourceFor=Live)
      let sourceManager = SourceManager.make(
        ~sources=[syncMock.source, liveMock.source],
        ~maxPartitionConcurrency=10,
      )
      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=0)

      // With new priority logic: Live is Primary, Sync is Secondary when Live is present
      t.expect(
        syncMock.getHeightOrThrowCalls->Array.length,
        ~message="Sync source should not be called yet (secondary when Live present)",
      ).toEqual(0)
      t.expect(
        liveMock.getHeightOrThrowCalls->Array.length,
        ~message="Should call live source as primary when isLive is true",
      ).toEqual(1)

      liveMock.resolveGetHeightOrThrow(1)
      t.expect(await p).toEqual(1)
      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should use live source as active",
      ).toBe(liveMock.source)
    },
  )

  Async.itWithOptions("Start polling all sources with it's own rates if new block isn't found", {retry: 3}, async t => {
    let pollingInterval0 = 1
    let pollingInterval1 = 2
    let mock0 = Mock.Source.make([#getHeightOrThrow], ~pollingInterval=pollingInterval0)
    let mock1 = Mock.Source.make([#getHeightOrThrow], ~pollingInterval=pollingInterval1)
    let sourceManager = SourceManager.make(
      ~sources=[mock0.source, mock1.source],
      ~maxPartitionConcurrency=10,
    )

    let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)

    let ((), ()) = await Promise.all2((
      (
        async () => {
          t.expect(mock0.getHeightOrThrowCalls->Array.length).toEqual(1)
          mock0.resolveGetHeightOrThrow(100)

          await Utils.delay(pollingInterval0)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Shouldn't immediately call getHeightOrThrow again",
          ).toEqual(
            1,
          )
          await Utils.delay(0)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Should call after a polling interval",
          ).toEqual(
            2,
          )

          mock0.resolveGetHeightOrThrow(100)
          await Utils.delay(pollingInterval0 + 1)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Should have a second round",
          ).toEqual(
            3,
          )
        }
      )(),
      (
        async () => {
          t.expect(mock1.getHeightOrThrowCalls->Array.length).toEqual(1)
          mock1.resolveGetHeightOrThrow(100)

          await Utils.delay(pollingInterval1)
          t.expect(
            mock1.getHeightOrThrowCalls->Array.length,
            ~message="Shouldn't immediately call getHeightOrThrow again",
          ).toEqual(
            1,
          )
          await Utils.delay(0)
          t.expect(
            mock1.getHeightOrThrowCalls->Array.length,
            ~message="Should call after a polling interval",
          ).toEqual(
            2,
          )

          mock1.resolveGetHeightOrThrow(100)
          await Utils.delay(pollingInterval1 + 1)
          t.expect(
            mock1.getHeightOrThrowCalls->Array.length,
            ~message="Should have a second round",
          ).toEqual(
            3,
          )
        }
      )(),
    ))

    mock0.resolveGetHeightOrThrow(101)
    mock1.resolveGetHeightOrThrow(100)

    t.expect(await p).toEqual(101)

    await Utils.delay(
      // Time during which a new polling should definetely happen
      pollingInterval0 + pollingInterval1,
    )
    t.expect(
      mock0.getHeightOrThrowCalls->Array.length,
      ~message="Polling for source 0 should stop after successful response",
    ).toEqual(
      3,
    )
    t.expect(
      mock1.getHeightOrThrowCalls->Array.length,
      ~message="Polling for source 1 should stop after successful response",
    ).toEqual(
      3,
    )
  })

  Async.itWithOptions("Retries on throw without affecting polling of other sources", {retry: 3}, async t => {
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

    let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)

    let ((), ()) = await Promise.all2((
      (
        async () => {
          t.expect(mock0.getHeightOrThrowCalls->Array.length).toEqual(1)

          mock0.rejectGetHeightOrThrow("ERROR")

          await Utils.delay(initialRetryInterval)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Shouldn't immediately call getHeightOrThrow again",
          ).toEqual(
            1,
          )
          await Utils.delay(0)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Should call after a retry",
          ).toEqual(
            2,
          )

          mock0.rejectGetHeightOrThrow("ERROR")

          await Utils.delay(initialRetryInterval * 2)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Should increase the retry interval",
          ).toEqual(
            2,
          )
          await Utils.delay(0)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Should call after a longer retry",
          ).toEqual(
            3,
          )

          mock0.rejectGetHeightOrThrow("ERROR")

          await Utils.delay(10)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Should increase the retry interval but not exceed the max",
          ).toEqual(
            3,
          )
          await Utils.delay(0)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Should call after the max retry interval",
          ).toEqual(
            4,
          )

          mock0.resolveGetHeightOrThrow(100)
          await Utils.delay(pollingInterval0 + 1)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Should return to normal polling after a successful retry",
          ).toEqual(
            5,
          )

          mock0.rejectGetHeightOrThrow("ERROR3")
          await Utils.delay(initialRetryInterval)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Retry interval resets after a successful resolve",
          ).toEqual(
            5,
          )
          await Utils.delay(0)
          t.expect(
            mock0.getHeightOrThrowCalls->Array.length,
            ~message="Should call after a retry for error3",
          ).toEqual(
            6,
          )
        }
      )(),
      // This is not affected by the source0 and done in parallel

      (
        async () => {
          t.expect(mock1.getHeightOrThrowCalls->Array.length).toEqual(1)
          mock1.resolveGetHeightOrThrow(100)

          await Utils.delay(pollingInterval1)
          t.expect(
            mock1.getHeightOrThrowCalls->Array.length,
            ~message="Shouldn't immediately call getHeightOrThrow again",
          ).toEqual(
            1,
          )
          await Utils.delay(0)
          t.expect(
            mock1.getHeightOrThrowCalls->Array.length,
            ~message="Should call after a polling interval",
          ).toEqual(
            2,
          )

          mock1.resolveGetHeightOrThrow(100)
          await Utils.delay(pollingInterval1 + 1)
          t.expect(
            mock1.getHeightOrThrowCalls->Array.length,
            ~message="Should have a second round",
          ).toEqual(
            3,
          )
        }
      )(),
    ))

    mock0.resolveGetHeightOrThrow(101)
    mock1.resolveGetHeightOrThrow(100)

    t.expect(await p).toEqual(101)

    await Utils.delay(
      // Time during which a new polling should definetely happen
      pollingInterval0 + pollingInterval1,
    )
    t.expect(
      mock0.getHeightOrThrowCalls->Array.length,
      ~message="Polling for source 0 should stop after successful response",
    ).toEqual(
      6,
    )
    t.expect(
      mock1.getHeightOrThrowCalls->Array.length,
      ~message="Polling for source 1 should stop after successful response",
    ).toEqual(
      3,
    )
  })

  Async.itWithOptions(
    "Starts polling the fallback source after the newBlockFallbackStallTimeout",
    {retry: 3},
    async t => {
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

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)

      t.expect(sync.getHeightOrThrowCalls->Array.length).toEqual(1)
      t.expect(fallback.getHeightOrThrowCalls->Array.length).toEqual(0)
      sync.resolveGetHeightOrThrow(100)

      await Utils.delay(pollingInterval + 1)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Should call after a polling interval",
      ).toEqual(
        2,
      )
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Fallback is still not called",
      ).toEqual(
        0,
      )

      await Utils.delay(newBlockFallbackStallTimeout)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Shouldn't increase, since the request is still pending",
      ).toEqual(
        2,
      )
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Should start polling the fallback source",
      ).toEqual(
        1,
      )

      sync.resolveGetHeightOrThrow(100)
      fallback.resolveGetHeightOrThrow(100)

      // After newBlockFallbackStallTimeout, the polling interval should be
      // increased to stalledPollingInterval for both sync and fallback sources
      await Utils.delay(stalledPollingInterval)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Sync source should still wait for the polling interval",
      ).toEqual(
        2,
      )
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Fallback source should still wait for the polling interval",
      ).toEqual(
        1,
      )
      await Utils.delay(0)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Should call after stalledPollingInterval",
      ).toEqual(
        3,
      )
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Should call after stalledPollingInterval",
      ).toEqual(
        2,
      )

      fallback.resolveGetHeightOrThrow(101)

      t.expect(await p, ~message="Returns the fallback source response").toEqual(101)

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message=`Changes the active source to the fallback`,
      ).toBe(
        fallback.source,
      )

      await Utils.delay(
        // Time during which a new polling should definetely happen
        stalledPollingInterval + 1,
      )
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Polling for sync source should stop after successful response",
      ).toEqual(
        3,
      )
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Polling for fallback source should stop after successful response",
      ).toEqual(
        2,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=101)

      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Should call on the next waitForNewBlock",
      ).toEqual(
        4,
      )
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message=`Even if the source is a fallback - it's currently active.
        Since we don't wait for a timeout again in case
        all main sync sources are still not valid,
        we immediately call the active source on the next waitForNewBlock.`,
      ).toEqual(
        3,
      )

      sync.resolveGetHeightOrThrow(102)

      t.expect(await p, ~message="Returns the sync source response").toEqual(102)

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message=`Changes the active source back to the sync`,
      ).toBe(
        sync.source,
      )

      await Utils.delay(
        // Time during which a new polling should definetely happen
        stalledPollingInterval + 1,
      )
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Polling for sync source should stop after successful response",
      ).toEqual(
        4,
      )
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Polling for fallback source should stop after successful response",
      ).toEqual(
        3,
      )
    },
  )

  Async.itWithOptions(
    "Continues polling even after newBlockFallbackStallTimeout when there are no fallback sources",
    {retry: 3},
    async t => {
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

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)

      t.expect(sync.getHeightOrThrowCalls->Array.length).toEqual(1)
      sync.resolveGetHeightOrThrow(100)

      await Utils.delay(pollingInterval + 1)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Should call after a polling interval",
      ).toEqual(
        2,
      )

      await Utils.delay(newBlockFallbackStallTimeout)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Shouldn't increase, since the request is still pending",
      ).toEqual(
        2,
      )

      sync.resolveGetHeightOrThrow(100)

      // After newBlockFallbackStallTimeout, the polling interval should be
      // increased to stalledPollingInterval for both sync and fallback sources
      await Utils.delay(stalledPollingInterval)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Sync source should still wait for the polling interval",
      ).toEqual(
        2,
      )
      await Utils.delay(0)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Should call after stalledPollingInterval",
      ).toEqual(
        3,
      )

      sync.resolveGetHeightOrThrow(101)

      t.expect(await p, ~message="Returns the sync source response").toEqual(101)
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

  Async.it("Successfully executes the query", async t => {
    let {source, getItemsOrThrowCalls, resolveGetItemsOrThrow} = Mock.Source.make([
      #getItemsOrThrow,
    ])
    let sourceManager = SourceManager.make(~sources=[source], ~maxPartitionConcurrency=10)
    let p = sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
    t.expect(
      getItemsOrThrowCalls->Js.Array2.map(call => call.payload),
    ).toEqual(
      [{"fromBlock": 0, "toBlock": None, "retry": 0, "p": "0"}],
    )
    resolveGetItemsOrThrow([])
    t.expect((await p).parsedQueueItems).toEqual([])
  })

  Async.it("Rethrows unknown errors", async t => {
    let sourceMock = Mock.Source.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(
      ~sources=[sourceMock.source],
      ~maxPartitionConcurrency=10,
    )
    let p = sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
    let error = {
      "message": "Something went wrong",
    }
    sourceMock.getItemsOrThrowCalls->Js.Array2.forEach(call => call.reject(error))
    try {
      let _ = await p
      Js.Exn.raiseError("Should not have resolved")
    } catch {
    | Js.Exn.Error(e) =>
      t.expect(
        e->Js.Exn.message,
      ).toEqual(Some(error["message"]))
    }
  })

  Async.it("Immediately retries with the suggested toBlock", async t => {
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
    let p = sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.length,
      ~message="Should call getItemsOrThrow",
    ).toEqual(
      1,
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
    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.length,
      ~message="No new calls before the microtask",
    ).toEqual(
      0,
    )
    await Promise.resolve() // Wait for microtask, so the rejection is caught

    switch sourceMock.getItemsOrThrowCalls {
    | [call] => {
        t.expect(
          call.payload,
          ~message=`Should reset retry count on WithSuggestedToBlock error`,
        ).toEqual(
          {"fromBlock": 0, "toBlock": Some(10), "retry": 0, "p": "0"},
        )
        call.resolve([])
      }
    | _ => Js.Exn.raiseError("Should have a new call after the microtask")
    }

    t.expect((await p).parsedQueueItems).toEqual([])
  })

  Async.it(
    "When there are multiple sync sources, it retries 2 times and then immediately switches to another source without waiting for backoff. After that it switches every second retry",
    async t => {
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
        let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)
        await Utils.delay(newBlockFallbackStallTimeout)
        sourceMock1.resolveGetHeightOrThrow(101)
        t.expect(await p).toBe(101)
        t.expect(
          sourceManager->SourceManager.getActiveSource,
          ~message="Should switch to the fallback source",
        ).toBe(
          sourceMock1.source,
        )
      }

      let p = sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)

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
        | _ => Js.Exn.raiseError("Should have one pending call to sourceMock1")
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
      | _ => Js.Exn.raiseError("Should have one pending call to sourceMock0")
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
      | _ => Js.Exn.raiseError("Should have one pending call to sourceMock0")
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
          t.expect(
            handledGetItemsOrThrowCalls,
            ~message=`Should start with the initial active source and perform 3 tries.
After that it switches to another sync source.
The fallback source is skipped.
Then sources start switching every second retry.
The fallback sources not included in the rotation until the 10th retry,
but we still attempt the fallback source if it was the initial active source.
        `,
          ).toEqual(
            [
              {"fromBlock": 0, "toBlock": None, "retry": 0, "source": 1},
              {"fromBlock": 0, "toBlock": None, "retry": 1, "source": 1},
              {"fromBlock": 0, "toBlock": None, "retry": 2, "source": 1},
              {"fromBlock": 0, "toBlock": None, "retry": 3, "source": 0},
              {"fromBlock": 0, "toBlock": None, "retry": 4, "source": 0},
              {"fromBlock": 0, "toBlock": None, "retry": 5, "source": 1},
            ],
          )

          call.resolve([])
          t.expect((await p).parsedQueueItems).toEqual([])
        }
      | _ => Js.Exn.raiseError("Should have one pending call to sourceMock1")
      }
    },
  )

  Async.it(
    "After fallback recovery timeout elapses, switches back to the primary sync source",
    async t => {
      let syncMock = Mock.Source.make([#getHeightOrThrow, #getItemsOrThrow])
      let fallbackMock = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow],
        ~sourceFor=Fallback,
      )
      let newBlockFallbackStallTimeout = 0
      let fallbackRecoveryTimeout = 5
      let sourceManager = SourceManager.make(
        ~newBlockFallbackStallTimeout,
        ~fallbackRecoveryTimeout,
        ~sources=[syncMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
      )

      // Switch active source to fallback via waitForNewBlock
      {
        let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)
        await Utils.delay(newBlockFallbackStallTimeout)
        fallbackMock.resolveGetHeightOrThrow(101)
        t.expect(await p).toBe(101)
        t.expect(
          sourceManager->SourceManager.getActiveSource,
          ~message="Should have switched to fallback",
        ).toBe(fallbackMock.source)
      }

      // Query before timeout — should stay on fallback
      {
        let p =
          sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
        switch fallbackMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => Js.Exn.raiseError("Expected one pending call to fallbackMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should stay on fallback before timeout elapses",
      ).toBe(fallbackMock.source)

      // Wait for fallback recovery timeout to elapse
      await Utils.delay(fallbackRecoveryTimeout)

      // Query after timeout — should trigger recovery to sync
      {
        let p =
          sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
        switch fallbackMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => Js.Exn.raiseError("Expected one pending call to fallbackMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="After recovery timeout, should switch back to sync source",
      ).toBe(syncMock.source)

      // Verify the next query goes to the sync source
      let p =
        sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
      t.expect(
        syncMock.getItemsOrThrowCalls->Array.length,
        ~message="Next query should use sync source",
      ).toEqual(1)
      switch syncMock.getItemsOrThrowCalls {
      | [call] => call.resolve([])
      | _ => Js.Exn.raiseError("Expected one pending call to syncMock")
      }
      t.expect((await p).parsedQueueItems).toEqual([])
    },
  )

  Async.it(
    "Does not attempt recovery when active source is already a sync source",
    async t => {
      let syncMock = Mock.Source.make([#getItemsOrThrow])
      let fallbackRecoveryTimeout = 0
      let sourceManager = SourceManager.make(
        ~sources=[syncMock.source],
        ~maxPartitionConcurrency=10,
        ~fallbackRecoveryTimeout,
      )

      // Run several queries on sync source — even with zero timeout, no recovery should happen
      for _ in 0 to 5 {
        let p =
          sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
        switch syncMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => Js.Exn.raiseError("Expected one pending call to syncMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Active source should remain the sync source",
      ).toBe(syncMock.source)
    },
  )

  Async.it(
    "Does not attempt recovery when active source is a live source",
    async t => {
      let liveMock = Mock.Source.make([#getItemsOrThrow], ~sourceFor=Live)
      let fallbackRecoveryTimeout = 0
      let sourceManager = SourceManager.make(
        ~sources=[liveMock.source],
        ~maxPartitionConcurrency=10,
        ~fallbackRecoveryTimeout,
      )

      // Run several queries on live source — even with zero timeout, no recovery should happen
      for _ in 0 to 5 {
        let p =
          sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
        switch liveMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => Js.Exn.raiseError("Expected one pending call to liveMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Active source should remain the live source",
      ).toBe(liveMock.source)
    },
  )

  Async.it(
    "After fallback recovery timeout, can recover to a live source when isLive",
    async t => {
      let liveMock = Mock.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Live)
      let fallbackMock = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow],
        ~sourceFor=Fallback,
      )
      let newBlockFallbackStallTimeoutLive = 0
      let fallbackRecoveryTimeout = 5
      let sourceManager = SourceManager.make(
        ~newBlockFallbackStallTimeoutLive,
        ~fallbackRecoveryTimeout,
        ~sources=[liveMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
      )
      // Switch active source to fallback via waitForNewBlock
      {
        let p = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)
        await Utils.delay(newBlockFallbackStallTimeoutLive)
        fallbackMock.resolveGetHeightOrThrow(101)
        t.expect(await p).toBe(101)
        t.expect(
          sourceManager->SourceManager.getActiveSource,
          ~message="Should have switched to fallback",
        ).toBe(fallbackMock.source)
      }

      // Wait for fallback recovery timeout to elapse
      await Utils.delay(fallbackRecoveryTimeout)

      // Run a successful query — should trigger recovery to live
      {
        let p =
          sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=true, ~knownHeight=100)
        switch fallbackMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => Js.Exn.raiseError("Expected one pending call to fallbackMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="After recovery timeout, should switch back to live source",
      ).toBe(liveMock.source)
    },
  )

  Async.it(
    "Recovery timestamp resets when returning to primary, and recovery works again after re-fallback",
    async t => {
      let syncMock = Mock.Source.make([#getHeightOrThrow, #getItemsOrThrow])
      let fallbackMock = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow],
        ~sourceFor=Fallback,
      )
      let newBlockFallbackStallTimeout = 0
      let fallbackRecoveryTimeout = 5
      let sourceManager = SourceManager.make(
        ~newBlockFallbackStallTimeout,
        ~fallbackRecoveryTimeout,
        ~sources=[syncMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
      )

      // Switch to fallback
      {
        let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)
        await Utils.delay(newBlockFallbackStallTimeout)
        fallbackMock.resolveGetHeightOrThrow(101)
        let _ = await p
      }

      // Wait for recovery timeout and trigger recovery
      await Utils.delay(fallbackRecoveryTimeout)
      {
        let p =
          sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
        switch fallbackMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => Js.Exn.raiseError("Expected one pending call to fallbackMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should have recovered to sync",
      ).toBe(syncMock.source)

      // Sync source succeeds - timestamp should be cleared since active is Primary
      {
        let p =
          sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
        switch syncMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => Js.Exn.raiseError("Expected one pending call to syncMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Active source should remain sync after successful query",
      ).toBe(syncMock.source)

      // Now simulate sync going down again via waitForNewBlock
      {
        let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=101)
        await Utils.delay(newBlockFallbackStallTimeout)
        fallbackMock.resolveGetHeightOrThrow(102)
        let _ = await p
        t.expect(
          sourceManager->SourceManager.getActiveSource,
          ~message="Should switch back to fallback via waitForNewBlock",
        ).toBe(fallbackMock.source)
      }

      // Wait for recovery timeout again and trigger recovery
      await Utils.delay(fallbackRecoveryTimeout)
      {
        let p =
          sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=102)
        switch fallbackMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => Js.Exn.raiseError("Expected one pending call to fallbackMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should recover to sync again after second fallback period",
      ).toBe(syncMock.source)
    },
  )
})

describe("SourceManager height subscription", () => {
  Async.it(
    "Creates subscription when getHeightOrThrow returns same height as knownHeight",
    async t => {
      let mock = Mock.Source.make([#getHeightOrThrow, #createHeightSubscription])
      let sourceManager = SourceManager.make(~sources=[mock.source], ~maxPartitionConcurrency=10)

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)

      // First call to getHeightOrThrow
      t.expect(mock.getHeightOrThrowCalls->Array.length).toEqual(1)
      // Return the same height - should trigger subscription creation
      mock.resolveGetHeightOrThrow(100)

      // Wait for the subscription to be created
      await Utils.delay(0)

      t.expect(
        mock.heightSubscriptionCalls->Array.length,
        ~message="Should have created a height subscription",
      ).toEqual(
        1,
      )

      // Trigger new height from subscription
      mock.triggerHeightSubscription(101)

      t.expect(await p, ~message="Should resolve with the subscription height").toEqual(101)
    },
  )

  Async.it("Uses cached height from subscription if higher than knownHeight", async t => {
    let mock = Mock.Source.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(~sources=[mock.source], ~maxPartitionConcurrency=10)

    // First call - create subscription
    let p1 = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    mock.triggerHeightSubscription(105)
    t.expect(await p1).toEqual(105)

    // Second call - should use cached height immediately without calling getHeightOrThrow
    let p2 = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=101)
    t.expect(
      mock.getHeightOrThrowCalls->Array.length,
      ~message="Should not call getHeightOrThrow again since subscription exists",
    ).toEqual(
      1,
    )
    t.expect(await p2, ~message="Should immediately return cached height").toEqual(105)
  })

  Async.it(
    "Waits for next height event when subscription exists but height <= knownHeight",
    async t => {
      let mock = Mock.Source.make([#getHeightOrThrow, #createHeightSubscription])
      let sourceManager = SourceManager.make(~sources=[mock.source], ~maxPartitionConcurrency=10)

      // First call - create subscription and set initial height
      let p1 = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      mock.triggerHeightSubscription(101)
      t.expect(await p1).toEqual(101)

      // Second call with higher knownHeight - should wait for next subscription event
      let p2 = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=101)
      t.expect(
        mock.getHeightOrThrowCalls->Array.length,
        ~message="Should not call getHeightOrThrow since subscription exists",
      ).toEqual(
        1,
      )

      // Trigger new height
      mock.triggerHeightSubscription(102)
      t.expect(await p2, ~message="Should wait for and resolve with new height").toEqual(102)
    },
  )

  Async.itWithOptions(
    "Falls back to polling when createHeightSubscription is not available",
    {retry: 3},
    async t => {
      let pollingInterval = 1
      let mock = Mock.Source.make([#getHeightOrThrow], ~pollingInterval)
      let sourceManager = SourceManager.make(~sources=[mock.source], ~maxPartitionConcurrency=10)

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)

      // Return same height - should trigger polling since no subscription available
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(pollingInterval + 1)

      t.expect(
        mock.getHeightOrThrowCalls->Array.length,
        ~message="Should poll again since no subscription is available",
      ).toEqual(
        2,
      )

      mock.resolveGetHeightOrThrow(101)
      t.expect(await p).toEqual(101)
    },
  )

  Async.it("Ignores subscription heights lower than or equal to knownHeight", async t => {
    let mock = Mock.Source.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(~sources=[mock.source], ~maxPartitionConcurrency=10)

    // First call - create subscription
    let p1 = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    mock.triggerHeightSubscription(101)
    t.expect(await p1).toEqual(101)

    // Second call with higher knownHeight
    let p2 = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=105)

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
    t.expect(
      resolved.contents,
      ~message="Should not resolve with height <= knownHeight",
    ).toEqual(
      false,
    )

    // Finally trigger with valid height
    mock.triggerHeightSubscription(106)
    t.expect(await p2, ~message="Should resolve with height > knownHeight").toEqual(106)
  })
})
