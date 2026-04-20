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
      resolveFns->Array.forEach(resolve => resolve())
    },
    fn: query => {
      calls->Array.push(query)->ignore
      callIds
      ->Array.push(query.partitionId)
      ->ignore
      Promise.make((resolve, _reject) => {
        resolveFns->Array.push(resolve)->ignore
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
      resolveFns->Array.forEach(resolve => resolve(knownHeight))
    },
    fn: (~knownHeight) => {
      calls->Array.push(knownHeight)->ignore
      Promise.make((resolve, _reject) => {
        resolveFns->Array.push(resolve)->ignore
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
      calls->Array.push(knownHeight)->ignore
    },
    calls,
  }
}

describe("SourceManager creation", () => {
  it("Successfully creates with a sync source", t => {
    let source = MockIndexer.Source.make([]).source
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[source],
      ~maxPartitionConcurrency=10,
    )
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(source)
  })

  it("Uses first sync source as initial active source", t => {
    let fallback = MockIndexer.Source.make([], ~sourceFor=Fallback).source
    let sync0 = MockIndexer.Source.make([]).source
    let sync1 = MockIndexer.Source.make([]).source
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[fallback, sync0, sync1],
      ~maxPartitionConcurrency=10,
    )
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(sync0)
  })

  it("Prefers sync source over live source as initial active source", t => {
    let live = MockIndexer.Source.make([], ~sourceFor=Live).source
    let sync = MockIndexer.Source.make([]).source
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[live, sync],
      ~maxPartitionConcurrency=10,
    )
    // Sync is always preferred as initial active source (backfill mode)
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(sync)
  })

  it("Prefers live source over sync source as initial active source in live mode", t => {
    let sync = MockIndexer.Source.make([]).source
    let live = MockIndexer.Source.make([], ~sourceFor=Live).source
    let sourceManager = SourceManager.make(
      ~isLive=true,
      ~sources=[sync, live],
      ~maxPartitionConcurrency=10,
    )
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(live)
  })

  it("Fails to create without primary sources", t => {
    t.expect(
      () => {
        SourceManager.make(~isLive=false, ~sources=[], ~maxPartitionConcurrency=10)
      },
    ).toThrowError("Invalid configuration, no data-source for historical sync provided")
    t.expect(
      () => {
        SourceManager.make(
          ~isLive=false,
          ~sources=[MockIndexer.Source.make([], ~sourceFor=Fallback).source],
          ~maxPartitionConcurrency=10,
        )
      },
    ).toThrowError("Invalid configuration, no data-source for historical sync provided")
  })
})

describe("SourceManager.getSourceRole", () => {
  it("Backfill (isLive=false): Sync is Primary, Fallback is Secondary, Live is ignored", t => {
    t.expect(SourceManager.getSourceRole(~sourceFor=Sync, ~isLive=false, ~hasLive=false)).toEqual(
      Some(Primary),
    )
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Fallback, ~isLive=false, ~hasLive=false),
    ).toEqual(Some(Secondary))
    t.expect(SourceManager.getSourceRole(~sourceFor=Live, ~isLive=false, ~hasLive=false)).toEqual(
      None,
    )
    // hasLive doesn't matter during backfill
    t.expect(SourceManager.getSourceRole(~sourceFor=Sync, ~isLive=false, ~hasLive=true)).toEqual(
      Some(Primary),
    )
    t.expect(SourceManager.getSourceRole(~sourceFor=Live, ~isLive=false, ~hasLive=true)).toEqual(
      None,
    )
  })

  it("Live mode with Live source: Live is Primary, Sync+Fallback are Secondary", t => {
    t.expect(SourceManager.getSourceRole(~sourceFor=Live, ~isLive=true, ~hasLive=true)).toEqual(
      Some(Primary),
    )
    t.expect(SourceManager.getSourceRole(~sourceFor=Sync, ~isLive=true, ~hasLive=true)).toEqual(
      Some(Secondary),
    )
    t.expect(SourceManager.getSourceRole(~sourceFor=Fallback, ~isLive=true, ~hasLive=true)).toEqual(
      Some(Secondary),
    )
  })

  it("Live mode without Live source: Sync is Primary, Fallback is Secondary", t => {
    t.expect(SourceManager.getSourceRole(~sourceFor=Sync, ~isLive=true, ~hasLive=false)).toEqual(
      Some(Primary),
    )
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Fallback, ~isLive=true, ~hasLive=false),
    ).toEqual(Some(Secondary))
  })
})

describe("SourceManager source priority with Live sources", () => {
  let selection = {FetchState.dependsOnAddresses: false, eventConfigs: []}
  let addressesByContractName = Dict.make()

  let mockQuery = (): FetchState.query => {
    partitionId: "0",
    fromBlock: 0,
    toBlock: None,
    isChunk: false,
    selection,
    addressesByContractName,
    indexingContracts: Dict.make(),
  }

  Async.it(
    "During isLive=true with Live source: Live is primary, Sync+Fallback are secondary in waitForNewBlock",
    async t => {
      let syncMock = MockIndexer.Source.make([#getHeightOrThrow])
      let liveMock = MockIndexer.Source.make([#getHeightOrThrow], ~sourceFor=Live)
      let fallbackMock = MockIndexer.Source.make([#getHeightOrThrow], ~sourceFor=Fallback)
      let newBlockStallTimeoutLive = 5
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
        ~newBlockStallTimeoutLive,
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
      let syncMock = MockIndexer.Source.make([#getHeightOrThrow])
      let liveMock = MockIndexer.Source.make([#getHeightOrThrow], ~sourceFor=Live)
      let fallbackMock = MockIndexer.Source.make([#getHeightOrThrow], ~sourceFor=Fallback)
      let newBlockStallTimeoutLive = 5
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
        ~newBlockStallTimeoutLive,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)

      // Live doesn't find new block
      liveMock.resolveGetHeightOrThrow(100)

      // Wait for stall timeout
      await Utils.delay(newBlockStallTimeoutLive)

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
    "During isLive=true with Live source: recovery from secondary goes to Live (not Sync)",
    async t => {
      let syncMock = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow])
      let liveMock = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Live)
      let fallbackMock = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow],
        ~sourceFor=Fallback,
      )
      let newBlockStallTimeoutLive = 0
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~newBlockStallTimeoutLive,
        ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
      )

      {
        // Switch to fallback via waitForNewBlock with isLive=true

        let p = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)
        await Utils.delay(newBlockStallTimeoutLive)
        fallbackMock.resolveGetHeightOrThrow(101)
        t.expect(await p).toBe(101)
        t.expect(sourceManager->SourceManager.getActiveSource).toBe(fallbackMock.source)
      }

      {
        // Live never failed in executeQuery, recovery is immediate.
        // With isLive=true, Live is Primary so recovery goes to Live, not Sync.

        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=true,
            ~knownHeight=100,
          )
        // The query goes to Live (recovered primary), not fallback
        switch liveMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => JsError.throwWithMessage("Expected one pending call to liveMock")
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
      let syncMock = MockIndexer.Source.make([#getHeightOrThrow])
      let fallbackMock = MockIndexer.Source.make([#getHeightOrThrow], ~sourceFor=Fallback)
      let sourceManager = SourceManager.make(
        ~isLive=false,
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
    let addressesByContractName = Dict.make()
    let addresses = []

    for i in 0 to numContracts - 1 {
      let address = Envio.TestHelpers.Addresses.mockAddresses[i]->Option.getOrThrow
      addresses->Array.push(address)
    }

    addressesByContractName->Dict.set("MockContract", addresses)

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
    let indexingContracts = Dict.make()
    let latestFullyFetchedBlock = ref((partitions->Utils.Array.firstUnsafe).latestFetchedBlock)

    partitions->Array.forEach(partition => {
      if latestFullyFetchedBlock.contents.blockNumber > partition.latestFetchedBlock.blockNumber {
        latestFullyFetchedBlock := partition.latestFetchedBlock
      }
      partition.addressesByContractName
      ->Dict.toArray
      ->Array.forEach(
        ((contractName, addresses)) => {
          addresses->Array.forEach(
            address => {
              indexingContracts->Dict.set(
                address->Address.toString,
                ({
                  contractName,
                  address,
                  registrationBlock: -1,
                  effectiveStartBlock: 0,
                }: FetchState.indexingAddress),
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
      contractConfigs: Dict.make(),
      blockLag: 0,
      onBlockConfigs: [],
      knownHeight,
      firstEventBlock: None,
    }
  }

  let neverWaitForNewBlock = async (~knownHeight as _) =>
    JsError.throwWithMessage("The waitForNewBlock shouldn't be called for the test")

  let neverOnNewBlock = (~knownHeight as _) =>
    JsError.throwWithMessage("The onNewBlock shouldn't be called for the test")

  let neverExecutePartitionQuery = _ =>
    JsError.throwWithMessage("The executeQuery shouldn't be called for the test")

  let source: Source.t = MockIndexer.Source.make([]).source

  Async.it(
    "Executes full partitions in any order when we didn't reach concurency limit",
    async t => {
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[source],
        ~maxPartitionConcurrency=10,
      )

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
      ).toEqual([
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
      ])

      executeQueryMock.resolveAll()

      await fetchNextPromise

      t.expect(
        executeQueryMock.calls->Array.length,
        ~message="Shouldn't have called more after resolving prev promises",
      ).toEqual(3)
    },
  )

  Async.it(
    "Slices full partitions to the concurrency limit, takes the earliest queries first",
    async t => {
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[source],
        ~maxPartitionConcurrency=2,
      )

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

      t.expect(executeQueryMock.calls).toEqual([
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
      ])

      executeQueryMock.resolveAll()

      await fetchNextPromise

      t.expect(
        executeQueryMock.calls->Array.length,
        ~message="Shouldn't have called more after resolving prev promises",
      ).toEqual(2)
    },
  )

  Async.it(
    "Skips full partitions at the chain last block and the ones at the mergeBlock",
    async t => {
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[source],
        ~maxPartitionConcurrency=10,
      )

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
        executeQueryMock.calls->Array.length,
        ~message="Shouldn't have called more after resolving prev promises",
      ).toEqual(1)

      await fetchNextPromise
    },
  )

  Async.it("Starts indexing from the initial state", async t => {
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[source],
      ~maxPartitionConcurrency=10,
    )

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
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[source],
      ~maxPartitionConcurrency=10,
    )

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
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[source],
      ~maxPartitionConcurrency=10,
    )

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

    t.expect(waitForNewBlockMock.calls->Array.length).toEqual(1)
    t.expect(onNewBlockMock.calls->Array.length).toEqual(1)
  })

  Async.it("Restarts waiting for new block after a rollback", async t => {
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[source],
      ~maxPartitionConcurrency=10,
    )

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
    ).toEqual([5])

    let fetchNextPromise2 =
      sourceManager->SourceManager.fetchNext(
        ~fetchState=mockFetchState([p0], ~knownHeight=5),
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=onNewBlockMock.fn,
        ~stateId=1,
      )
    t.expect(waitForNewBlockMock.calls, ~message=`Should add a new call after a rollback`).toEqual([
      5,
      5,
    ])

    (waitForNewBlockMock.resolveFns->Utils.Array.firstUnsafe)(7)
    (waitForNewBlockMock.resolveFns->Array.getUnsafe(1))(6)

    await fetchNextPromise
    await fetchNextPromise2

    t.expect(
      onNewBlockMock.calls,
      ~message=`Should invalidate the waitForNewBlock result with block height 7, which responded after the reorg rollback`,
    ).toEqual([6])
  })

  Async.it("Can add new partitions until the concurrency limit reached", async t => {
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[source],
      ~maxPartitionConcurrency=3,
    )

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
    ).toEqual(["0", "1", "3"])

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
    (executeQueryMock.resolveFns->Array.getUnsafe(1))()

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
      executeQueryMock.calls->Array.length,
      ~message="Shouldn't have called more after resolving prev promises",
    ).toEqual(5)
  })

  Async.it("Should not query partitions that are at max queue size", async t => {
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[source],
      ~maxPartitionConcurrency=10,
    )

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
    ).toEqual(["2", "3", "4"])
  })

  Async.it("Sorts after all the filtering is applied", async t => {
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[source],
      ~maxPartitionConcurrency=1,
    )

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
      let {source, getHeightOrThrowCalls, resolveGetHeightOrThrow} = MockIndexer.Source.make([
        #getHeightOrThrow,
      ])
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[source],
        ~maxPartitionConcurrency=10,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=0)

      t.expect(getHeightOrThrowCalls->Array.length).toEqual(1)
      resolveGetHeightOrThrow(1)

      t.expect(await p).toEqual(1)
    },
  )

  Async.it(
    "Calls all sync sources in parallel. Resolves the first one with valid response",
    async t => {
      let mock0 = MockIndexer.Source.make([#getHeightOrThrow])
      let mock1 = MockIndexer.Source.make([#getHeightOrThrow])
      let sourceManager = SourceManager.make(
        ~isLive=false,
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
      ).toEqual(2)

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message=`Should also switch the active source`,
      ).toBe(mock1.source)

      // No new calls
      t.expect(mock0.getHeightOrThrowCalls->Array.length).toEqual(1)
      t.expect(mock1.getHeightOrThrowCalls->Array.length).toEqual(1)
    },
  )

  Async.it("Excludes live source from height fetch when isLive is false", async t => {
    let syncMock = MockIndexer.Source.make([#getHeightOrThrow])
    let liveMock = MockIndexer.Source.make([#getHeightOrThrow], ~sourceFor=Live)
    let sourceManager = SourceManager.make(
      ~isLive=false,
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
  })

  Async.it("Includes live source in height fetch when isLive is true", async t => {
    let syncMock = MockIndexer.Source.make([#getHeightOrThrow])
    let liveMock = MockIndexer.Source.make([#getHeightOrThrow], ~sourceFor=Live)
    let sourceManager = SourceManager.make(
      ~isLive=false,
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
      ~message="Should use live source as active (won the race)",
    ).toBe(liveMock.source)
  })

  Async.itWithOptions(
    "Start polling all sources with it's own rates if new block isn't found",
    {retry: 3},
    async t => {
      let pollingInterval0 = 1
      let pollingInterval1 = 2
      let mock0 = MockIndexer.Source.make([#getHeightOrThrow], ~pollingInterval=pollingInterval0)
      let mock1 = MockIndexer.Source.make([#getHeightOrThrow], ~pollingInterval=pollingInterval1)
      let sourceManager = SourceManager.make(
        ~isLive=false,
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
            ).toEqual(1)
            await Utils.delay(0)
            t.expect(
              mock0.getHeightOrThrowCalls->Array.length,
              ~message="Should call after a polling interval",
            ).toEqual(2)

            mock0.resolveGetHeightOrThrow(100)
            await Utils.delay(pollingInterval0 + 1)
            t.expect(
              mock0.getHeightOrThrowCalls->Array.length,
              ~message="Should have a second round",
            ).toEqual(3)
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
            ).toEqual(1)
            await Utils.delay(0)
            t.expect(
              mock1.getHeightOrThrowCalls->Array.length,
              ~message="Should call after a polling interval",
            ).toEqual(2)

            mock1.resolveGetHeightOrThrow(100)
            await Utils.delay(pollingInterval1 + 1)
            t.expect(
              mock1.getHeightOrThrowCalls->Array.length,
              ~message="Should have a second round",
            ).toEqual(3)
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
      ).toEqual(3)
      t.expect(
        mock1.getHeightOrThrowCalls->Array.length,
        ~message="Polling for source 1 should stop after successful response",
      ).toEqual(3)
    },
  )

  Async.itWithOptions(
    "Retries on throw without affecting polling of other sources",
    {retry: 3},
    async t => {
      let pollingInterval0 = 1
      let pollingInterval1 = 2
      let initialRetryInterval = 4
      let mock0 = MockIndexer.Source.make([#getHeightOrThrow], ~pollingInterval=pollingInterval0)
      let mock1 = MockIndexer.Source.make([#getHeightOrThrow], ~pollingInterval=pollingInterval1)
      let sourceManager = SourceManager.make(
        ~isLive=false,
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
            ).toEqual(1)
            await Utils.delay(0)
            t.expect(
              mock0.getHeightOrThrowCalls->Array.length,
              ~message="Should call after a retry",
            ).toEqual(2)

            mock0.rejectGetHeightOrThrow("ERROR")

            await Utils.delay(initialRetryInterval * 2)
            t.expect(
              mock0.getHeightOrThrowCalls->Array.length,
              ~message="Should increase the retry interval",
            ).toEqual(2)
            await Utils.delay(0)
            t.expect(
              mock0.getHeightOrThrowCalls->Array.length,
              ~message="Should call after a longer retry",
            ).toEqual(3)

            mock0.rejectGetHeightOrThrow("ERROR")

            await Utils.delay(10)
            t.expect(
              mock0.getHeightOrThrowCalls->Array.length,
              ~message="Should increase the retry interval but not exceed the max",
            ).toEqual(3)
            await Utils.delay(0)
            t.expect(
              mock0.getHeightOrThrowCalls->Array.length,
              ~message="Should call after the max retry interval",
            ).toEqual(4)

            mock0.resolveGetHeightOrThrow(100)
            await Utils.delay(pollingInterval0 + 1)
            t.expect(
              mock0.getHeightOrThrowCalls->Array.length,
              ~message="Should return to normal polling after a successful retry",
            ).toEqual(5)

            mock0.rejectGetHeightOrThrow("ERROR3")
            await Utils.delay(initialRetryInterval)
            t.expect(
              mock0.getHeightOrThrowCalls->Array.length,
              ~message="Retry interval resets after a successful resolve",
            ).toEqual(5)
            await Utils.delay(0)
            t.expect(
              mock0.getHeightOrThrowCalls->Array.length,
              ~message="Should call after a retry for error3",
            ).toEqual(6)
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
            ).toEqual(1)
            await Utils.delay(0)
            t.expect(
              mock1.getHeightOrThrowCalls->Array.length,
              ~message="Should call after a polling interval",
            ).toEqual(2)

            mock1.resolveGetHeightOrThrow(100)
            await Utils.delay(pollingInterval1 + 1)
            t.expect(
              mock1.getHeightOrThrowCalls->Array.length,
              ~message="Should have a second round",
            ).toEqual(3)
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
      ).toEqual(6)
      t.expect(
        mock1.getHeightOrThrowCalls->Array.length,
        ~message="Polling for source 1 should stop after successful response",
      ).toEqual(3)
    },
  )

  Async.itWithOptions(
    "Starts polling the fallback source after the newBlockStallTimeout",
    {retry: 3},
    async t => {
      let pollingInterval = 1
      let stalledPollingInterval = 2
      let newBlockStallTimeout = 8
      let sync = MockIndexer.Source.make([#getHeightOrThrow], ~pollingInterval)
      let fallback = MockIndexer.Source.make(
        ~sourceFor=Fallback,
        [#getHeightOrThrow],
        ~pollingInterval,
      )
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[sync.source, fallback.source],
        ~maxPartitionConcurrency=10,
        ~newBlockStallTimeout,
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
      ).toEqual(2)
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Fallback is still not called",
      ).toEqual(0)

      await Utils.delay(newBlockStallTimeout)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Shouldn't increase, since the request is still pending",
      ).toEqual(2)
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Should start polling the fallback source",
      ).toEqual(1)

      sync.resolveGetHeightOrThrow(100)
      fallback.resolveGetHeightOrThrow(100)

      // After newBlockStallTimeout, the polling interval should be
      // increased to stalledPollingInterval for both sync and fallback sources
      await Utils.delay(stalledPollingInterval)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Sync source should still wait for the polling interval",
      ).toEqual(2)
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Fallback source should still wait for the polling interval",
      ).toEqual(1)
      await Utils.delay(0)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Should call after stalledPollingInterval",
      ).toEqual(3)
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Should call after stalledPollingInterval",
      ).toEqual(2)

      fallback.resolveGetHeightOrThrow(101)

      t.expect(await p, ~message="Returns the fallback source response").toEqual(101)

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message=`Changes the active source to the fallback`,
      ).toBe(fallback.source)

      await Utils.delay(
        // Time during which a new polling should definetely happen
        stalledPollingInterval + 1,
      )
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Polling for sync source should stop after successful response",
      ).toEqual(3)
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Polling for fallback source should stop after successful response",
      ).toEqual(2)

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=101)

      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Should call on the next waitForNewBlock",
      ).toEqual(4)
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Fallback is secondary, not polled immediately on next waitForNewBlock",
      ).toEqual(2)

      sync.resolveGetHeightOrThrow(102)

      t.expect(await p, ~message="Returns the sync source response").toEqual(102)

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message=`Changes the active source back to the sync`,
      ).toBe(sync.source)

      await Utils.delay(
        // Time during which a new polling should definetely happen
        stalledPollingInterval + 1,
      )
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Polling for sync source should stop after successful response",
      ).toEqual(4)
      t.expect(
        fallback.getHeightOrThrowCalls->Array.length,
        ~message="Polling for fallback source should stop after successful response",
      ).toEqual(2)
    },
  )

  Async.itWithOptions(
    "Continues polling even after newBlockStallTimeout when there are no fallback sources",
    {retry: 3},
    async t => {
      let pollingInterval = 1
      let stalledPollingInterval = 2
      let newBlockStallTimeout = 8
      let sync = MockIndexer.Source.make([#getHeightOrThrow], ~pollingInterval)

      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[sync.source],
        ~maxPartitionConcurrency=10,
        ~newBlockStallTimeout,
        ~stalledPollingInterval,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)

      t.expect(sync.getHeightOrThrowCalls->Array.length).toEqual(1)
      sync.resolveGetHeightOrThrow(100)

      await Utils.delay(pollingInterval + 1)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Should call after a polling interval",
      ).toEqual(2)

      await Utils.delay(newBlockStallTimeout)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Shouldn't increase, since the request is still pending",
      ).toEqual(2)

      sync.resolveGetHeightOrThrow(100)

      // After newBlockStallTimeout, the polling interval should be
      // increased to stalledPollingInterval for both sync and fallback sources
      await Utils.delay(stalledPollingInterval)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Sync source should still wait for the polling interval",
      ).toEqual(2)
      await Utils.delay(0)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Should call after stalledPollingInterval",
      ).toEqual(3)

      sync.resolveGetHeightOrThrow(101)

      t.expect(await p, ~message="Returns the sync source response").toEqual(101)
    },
  )
})
describe("SourceManager.executeQuery", () => {
  let selection = {FetchState.dependsOnAddresses: false, eventConfigs: []}
  let addressesByContractName = Dict.make()

  let mockQuery = (): FetchState.query => {
    partitionId: "0",
    fromBlock: 0,
    toBlock: None,
    isChunk: false,
    selection,
    addressesByContractName,
    indexingContracts: Dict.make(),
  }

  Async.it("Successfully executes the query", async t => {
    let {source, getItemsOrThrowCalls, resolveGetItemsOrThrow} = MockIndexer.Source.make([
      #getItemsOrThrow,
    ])
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[source],
      ~maxPartitionConcurrency=10,
    )
    let p =
      sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
    t.expect(getItemsOrThrowCalls->Array.map(call => call.payload)).toEqual([
      {"fromBlock": 0, "toBlock": None, "retry": 0, "p": "0"},
    ])
    resolveGetItemsOrThrow([])
    t.expect((await p).parsedQueueItems).toEqual([])
  })

  Async.it("Rethrows unknown errors", async t => {
    let sourceMock = MockIndexer.Source.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[sourceMock.source],
      ~maxPartitionConcurrency=10,
    )
    let p =
      sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
    let error = {
      "message": "Something went wrong",
    }
    sourceMock.getItemsOrThrowCalls->Array.forEach(call => call.reject(error))
    try {
      let _ = await p
      JsError.throwWithMessage("Should not have resolved")
    } catch {
    | JsExn(e) => t.expect(e->JsExn.message).toEqual(Some(error["message"]))
    }
  })

  Async.it("Immediately retries with the suggested toBlock", async t => {
    let sourceMock = MockIndexer.Source.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[
        sourceMock.source,
        // Added second source without mock to the test,
        // to verify that we don't switch to it
        MockIndexer.Source.make([]).source,
      ],
      ~maxPartitionConcurrency=10,
    )
    let p =
      sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.length,
      ~message="Should call getItemsOrThrow",
    ).toEqual(1)
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
    ).toEqual(0)
    await Promise.resolve() // Wait for microtask, so the rejection is caught

    switch sourceMock.getItemsOrThrowCalls {
    | [call] => {
        t.expect(
          call.payload,
          ~message=`Should reset retry count on WithSuggestedToBlock error`,
        ).toEqual({"fromBlock": 0, "toBlock": Some(10), "retry": 0, "p": "0"})
        call.resolve([])
      }
    | _ => JsError.throwWithMessage("Should have a new call after the microtask")
    }

    t.expect((await p).parsedQueueItems).toEqual([])
  })

  Async.it(
    "Retries on same source twice before switching, then alternates every second retry",
    async t => {
      let syncMock = MockIndexer.Source.make([#getItemsOrThrow])
      let fallbackMock = MockIndexer.Source.make([#getItemsOrThrow], ~sourceFor=Fallback)
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[syncMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
      )

      // getNextSources picks sync (primary, recovered) at the start
      let p =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isLive=false,
          ~knownHeight=100,
        )

      let handledGetItemsOrThrowCalls = []
      let withBackoff = Source.GetItemsError(
        FailedGettingItems({
          exn: %raw(`null`),
          attemptedToBlock: 100,
          retry: WithBackoff({message: "test", backoffMillis: 0}),
        }),
      )

      // Retries 0, 1, 2 on sync (primary)
      for idx in 0 to 2 {
        switch syncMock.getItemsOrThrowCalls {
        | [call] => {
            handledGetItemsOrThrowCalls->Array.push({
              "fromBlock": call.payload["fromBlock"],
              "toBlock": call.payload["toBlock"],
              "retry": call.payload["retry"],
              "source": "sync",
            })
            call.reject(withBackoff)
          }
        | _ => JsError.throwWithMessage("Should have one pending call to syncMock")
        }
        await Promise.resolve()
        if idx !== 2 {
          await Utils.delay(0)
        }
      }

      // Retry 3 on fallback (sync failed, fallback is recovered secondary)
      switch fallbackMock.getItemsOrThrowCalls {
      | [call] => {
          handledGetItemsOrThrowCalls->Array.push({
            "fromBlock": call.payload["fromBlock"],
            "toBlock": call.payload["toBlock"],
            "retry": call.payload["retry"],
            "source": "fallback",
          })
          call.reject(withBackoff)
        }
      | _ => JsError.throwWithMessage("Should have one pending call to fallbackMock")
      }

      await Promise.resolve()
      await Utils.delay(0)

      // Retry 4 on fallback (odd retry, no switch)
      switch fallbackMock.getItemsOrThrowCalls {
      | [call] => {
          handledGetItemsOrThrowCalls->Array.push({
            "fromBlock": call.payload["fromBlock"],
            "toBlock": call.payload["toBlock"],
            "retry": call.payload["retry"],
            "source": "fallback",
          })
          call.reject(withBackoff)
        }
      | _ => JsError.throwWithMessage("Should have one pending call to fallbackMock")
      }

      await Promise.resolve()
      await Utils.delay(0)

      // Retry 5 on sync (fallback failed, sync has oldest lastFailedAt)
      switch syncMock.getItemsOrThrowCalls {
      | [call] => {
          handledGetItemsOrThrowCalls->Array.push({
            "fromBlock": call.payload["fromBlock"],
            "toBlock": call.payload["toBlock"],
            "retry": call.payload["retry"],
            "source": "sync",
          })
          t.expect(
            handledGetItemsOrThrowCalls,
            ~message=`Starts on primary (sync), retries 3 times, switches to secondary (fallback).
Retries 2 times on fallback, switches back to sync (oldest lastFailedAt).
        `,
          ).toEqual([
            {"fromBlock": 0, "toBlock": None, "retry": 0, "source": "sync"},
            {"fromBlock": 0, "toBlock": None, "retry": 1, "source": "sync"},
            {"fromBlock": 0, "toBlock": None, "retry": 2, "source": "sync"},
            {"fromBlock": 0, "toBlock": None, "retry": 3, "source": "fallback"},
            {"fromBlock": 0, "toBlock": None, "retry": 4, "source": "fallback"},
            {"fromBlock": 0, "toBlock": None, "retry": 5, "source": "sync"},
          ])

          call.resolve([])
          t.expect((await p).parsedQueueItems).toEqual([])
        }
      | _ => JsError.throwWithMessage("Should have one pending call to syncMock")
      }
    },
  )

  Async.it(
    "When switching to secondary via waitForNewBlock, immediately recovers to primary since it never failed",
    async t => {
      let syncMock = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow])
      let fallbackMock = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow],
        ~sourceFor=Fallback,
      )
      let newBlockStallTimeout = 0
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~newBlockStallTimeout,
        ~sources=[syncMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
      )

      {
        // Switch active source to fallback via waitForNewBlock

        let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)
        await Utils.delay(newBlockStallTimeout)
        fallbackMock.resolveGetHeightOrThrow(101)
        t.expect(await p).toBe(101)
        t.expect(
          sourceManager->SourceManager.getActiveSource,
          ~message="Should have switched to fallback",
        ).toBe(fallbackMock.source)
      }

      {
        // Even though active is fallback, sync never failed in executeQuery
        // so getNextSources returns sync as the first working primary

        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=false,
            ~knownHeight=100,
          )
        // Query goes to sync (recovered primary), not fallback
        switch syncMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => JsError.throwWithMessage("Expected one pending call to syncMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should recover to sync source immediately",
      ).toBe(syncMock.source)
    },
  )

  Async.it(
    "After primary fails in executeQuery, waits for recovery timeout before retrying it",
    async t => {
      let syncMock = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow])
      let fallbackMock = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow],
        ~sourceFor=Fallback,
      )
      let recoveryTimeout = 5.0
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~recoveryTimeout,
        ~sources=[syncMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
      )

      {
        // Fail sync with WithBackoff errors until it switches to fallback

        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=false,
            ~knownHeight=100,
          )
        // Fail sync twice (retries 0, 1 don't switch), then on retry 2 it switches
        for idx in 0 to 2 {
          switch syncMock.getItemsOrThrowCalls {
          | [call] =>
            call.reject(
              Source.GetItemsError(
                FailedGettingItems({
                  exn: %raw(`null`),
                  attemptedToBlock: 100,
                  retry: WithBackoff({message: "test fail", backoffMillis: 0}),
                }),
              ),
            )
          | _ => JsError.throwWithMessage("Should have one pending call to syncMock")
          }
          await Promise.resolve()
          if idx !== 2 {
            await Utils.delay(0)
          }
        }
        // Now it should have switched to fallback
        await Utils.delay(0)
        switch fallbackMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => JsError.throwWithMessage("Should have one pending call to fallbackMock")
        }
        let _ = await p
        t.expect(
          sourceManager->SourceManager.getActiveSource,
          ~message="Should have switched to fallback after sync failures",
        ).toBe(fallbackMock.source)
      }

      {
        // Query before timeout — should stay on fallback (sync has lastFailedAt set)

        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=false,
            ~knownHeight=100,
          )
        switch fallbackMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => JsError.throwWithMessage("Expected one pending call to fallbackMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should stay on fallback before recovery timeout elapses",
      ).toBe(fallbackMock.source)

      // Wait for recovery timeout to elapse
      await Utils.delay(recoveryTimeout->Float.toInt)

      {
        // Query after timeout — recovery switches to sync before querying

        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=false,
            ~knownHeight=100,
          )
        // Query goes to sync (recovered primary)
        switch syncMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => JsError.throwWithMessage("Expected one pending call to syncMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="After recovery timeout, should switch back to sync source",
      ).toBe(syncMock.source)
    },
  )

  Async.it("Does not attempt recovery when active source is already a sync source", async t => {
    let syncMock = MockIndexer.Source.make([#getItemsOrThrow])
    let recoveryTimeout = 0.0
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[syncMock.source],
      ~maxPartitionConcurrency=10,
      ~recoveryTimeout,
    )

    // Run several queries on sync source — even with zero timeout, no recovery should happen
    for _ in 0 to 5 {
      let p =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isLive=false,
          ~knownHeight=100,
        )
      switch syncMock.getItemsOrThrowCalls {
      | [call] => call.resolve([])
      | _ => JsError.throwWithMessage("Expected one pending call to syncMock")
      }
      let _ = await p
    }

    t.expect(
      sourceManager->SourceManager.getActiveSource,
      ~message="Active source should remain the sync source",
    ).toBe(syncMock.source)
  })

  Async.it(
    "Does not attempt recovery when active source is already primary (live source)",
    async t => {
      let liveMock = MockIndexer.Source.make([#getItemsOrThrow], ~sourceFor=Live)
      let recoveryTimeout = 0.0
      let sourceManager = SourceManager.make(
        ~isLive=true,
        ~sources=[liveMock.source],
        ~maxPartitionConcurrency=10,
        ~recoveryTimeout,
      )

      // Run several queries on live source — even with zero timeout, no switch should happen
      for _ in 0 to 5 {
        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=true,
            ~knownHeight=100,
          )
        switch liveMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => JsError.throwWithMessage("Expected one pending call to liveMock")
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
    "When switching to secondary via waitForNewBlock in live mode, immediately recovers to live primary",
    async t => {
      let syncMock = MockIndexer.Source.make([#getHeightOrThrow])
      let liveMock = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Live)
      let fallbackMock = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow],
        ~sourceFor=Fallback,
      )
      let newBlockStallTimeoutLive = 0
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~newBlockStallTimeoutLive,
        ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
      )

      {
        // Switch activeSource to fallback via waitForNewBlock

        let p = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)
        await Utils.delay(newBlockStallTimeoutLive)
        fallbackMock.resolveGetHeightOrThrow(101)
        t.expect(await p).toBe(101)
        t.expect(
          sourceManager->SourceManager.getActiveSource,
          ~message="Should have switched to fallback",
        ).toBe(fallbackMock.source)
      }

      {
        // Live never failed in executeQuery, so getNextSources picks it immediately

        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=true,
            ~knownHeight=100,
          )
        // Query goes to live (primary when isLive=true), not fallback
        switch liveMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => JsError.throwWithMessage("Expected one pending call to liveMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should recover to live source immediately",
      ).toBe(liveMock.source)
    },
  )

  Async.it(
    "lastFailedAt clears on success, allowing recovery to work again after re-failure",
    async t => {
      let syncMock = MockIndexer.Source.make([#getItemsOrThrow])
      let fallbackMock = MockIndexer.Source.make([#getItemsOrThrow], ~sourceFor=Fallback)
      let recoveryTimeout = 5.0
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~recoveryTimeout,
        ~sources=[syncMock.source, fallbackMock.source],
        ~maxPartitionConcurrency=10,
      )

      {
        // Fail sync with WithBackoff until it switches to fallback

        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=false,
            ~knownHeight=100,
          )
        for idx in 0 to 2 {
          switch syncMock.getItemsOrThrowCalls {
          | [call] =>
            call.reject(
              Source.GetItemsError(
                FailedGettingItems({
                  exn: %raw(`null`),
                  attemptedToBlock: 100,
                  retry: WithBackoff({message: "test fail", backoffMillis: 0}),
                }),
              ),
            )
          | _ => JsError.throwWithMessage("Should have one pending call to syncMock")
          }
          await Promise.resolve()
          if idx !== 2 {
            await Utils.delay(0)
          }
        }
        await Utils.delay(0)
        switch fallbackMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => JsError.throwWithMessage("Should have one pending call to fallbackMock")
        }
        let _ = await p
        t.expect(
          sourceManager->SourceManager.getActiveSource,
          ~message="Should be on fallback after sync failures",
        ).toBe(fallbackMock.source)
      }

      // Wait for recovery timeout, then recover to sync
      await Utils.delay(recoveryTimeout->Float.toInt)

      {
        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=false,
            ~knownHeight=100,
          )
        // Recovery switches to sync before query
        switch syncMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => JsError.throwWithMessage("Expected one pending call to syncMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should have recovered to sync",
      ).toBe(syncMock.source)

      {
        // Fail sync again to switch back to fallback

        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=false,
            ~knownHeight=101,
          )
        for idx in 0 to 2 {
          switch syncMock.getItemsOrThrowCalls {
          | [call] =>
            call.reject(
              Source.GetItemsError(
                FailedGettingItems({
                  exn: %raw(`null`),
                  attemptedToBlock: 101,
                  retry: WithBackoff({message: "test fail", backoffMillis: 0}),
                }),
              ),
            )
          | _ => JsError.throwWithMessage("Should have one pending call to syncMock")
          }
          await Promise.resolve()
          if idx !== 2 {
            await Utils.delay(0)
          }
        }
        await Utils.delay(0)
        switch fallbackMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => JsError.throwWithMessage("Should have one pending call to fallbackMock")
        }
        let _ = await p
        t.expect(
          sourceManager->SourceManager.getActiveSource,
          ~message="Should be on fallback again after second sync failure",
        ).toBe(fallbackMock.source)
      }

      // Wait for recovery timeout again and recover
      await Utils.delay(recoveryTimeout->Float.toInt)

      {
        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isLive=false,
            ~knownHeight=102,
          )
        switch syncMock.getItemsOrThrowCalls {
        | [call] => call.resolve([])
        | _ => JsError.throwWithMessage("Expected one pending call to syncMock")
        }
        let _ = await p
      }

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should recover to sync again after second recovery period",
      ).toBe(syncMock.source)
    },
  )

  Async.it(
    "Disabling one of two Live sources keeps hasLive true, disabling both clears it",
    async t => {
      let syncMock = MockIndexer.Source.make([#getItemsOrThrow])
      let liveMock0 = MockIndexer.Source.make([#getItemsOrThrow], ~sourceFor=Live)
      let liveMock1 = MockIndexer.Source.make([#getItemsOrThrow], ~sourceFor=Live)
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[syncMock.source, liveMock0.source, liveMock1.source],
        ~maxPartitionConcurrency=10,
      )

      // In isLive=true mode with hasLive=true, Live sources are Primary.
      // getNextSources picks liveMock0 (first primary).
      // Disable liveMock0 via UnsupportedSelection.
      let p1 =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isLive=true,
          ~knownHeight=100,
        )
      liveMock0.getItemsOrThrowCalls->Array.forEach(
        call => call.reject(Source.GetItemsError(UnsupportedSelection({message: "test disable"}))),
      )
      // liveMock1 should be the next source (still Live, still Primary)
      await Utils.delay(0)
      liveMock1.getItemsOrThrowCalls->Array.forEach(call => call.resolve([]))
      let _ = await p1
      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should switch to liveMock1 after disabling liveMock0",
      ).toBe(liveMock1.source)

      // Now disable liveMock1 too
      let p2 =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isLive=true,
          ~knownHeight=100,
        )
      liveMock1.getItemsOrThrowCalls->Array.forEach(
        call => call.reject(Source.GetItemsError(UnsupportedSelection({message: "test disable"}))),
      )
      // With both Live sources disabled, hasLive should be false.
      // Sync becomes Primary and should get the query.
      await Utils.delay(0)
      syncMock.getItemsOrThrowCalls->Array.forEach(call => call.resolve([]))
      let _ = await p2
      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should fall back to sync after all Live sources are disabled",
      ).toBe(syncMock.source)
    },
  )

  Async.it("Prefers activeSource when it's valid but not first in getNextSources", async t => {
    let syncMock0 = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow])
    let syncMock1 = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow])
    let newBlockStallTimeout = 0
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~newBlockStallTimeout,
      ~sources=[syncMock0.source, syncMock1.source],
      ~maxPartitionConcurrency=10,
    )

    {
      // Switch activeSource to syncMock1 via waitForNewBlock

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)
      await Utils.delay(newBlockStallTimeout)
      syncMock1.resolveGetHeightOrThrow(101)
      t.expect(await p).toBe(101)
      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="activeSource should be syncMock1",
      ).toBe(syncMock1.source)
    }

    {
      // executeQuery: syncMock1 is activeSource AND in getNextSources (both are working primaries).
      // Should prefer syncMock1, not switch to syncMock0.

      let p =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isLive=false,
          ~knownHeight=100,
        )
      switch syncMock1.getItemsOrThrowCalls {
      | [call] => call.resolve([])
      | _ => JsError.throwWithMessage("Expected query to go to syncMock1 (activeSource)")
      }
      let _ = await p
    }

    t.expect(
      sourceManager->SourceManager.getActiveSource,
      ~message="Should stay on syncMock1",
    ).toBe(syncMock1.source)
  })

  Async.it(
    "ImpossibleForTheQuery switches to another source without setting lastFailedAt",
    async t => {
      let syncMock0 = MockIndexer.Source.make([#getItemsOrThrow])
      let syncMock1 = MockIndexer.Source.make([#getItemsOrThrow])
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[syncMock0.source, syncMock1.source],
        ~maxPartitionConcurrency=10,
      )

      let p =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isLive=false,
          ~knownHeight=100,
        )

      // syncMock0 gets the query first (activeSource). Fail with ImpossibleForTheQuery.
      switch syncMock0.getItemsOrThrowCalls {
      | [call] =>
        call.reject(
          Source.GetItemsError(
            FailedGettingItems({
              exn: %raw(`null`),
              attemptedToBlock: 100,
              retry: ImpossibleForTheQuery({message: "test impossible"}),
            }),
          ),
        )
      | _ => JsError.throwWithMessage("Expected one pending call to syncMock0")
      }

      await Promise.resolve()

      // Should switch to syncMock1
      switch syncMock1.getItemsOrThrowCalls {
      | [call] => call.resolve([])
      | _ => JsError.throwWithMessage("Expected one pending call to syncMock1")
      }

      let _ = await p

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should switch to syncMock1 after ImpossibleForTheQuery on syncMock0",
      ).toBe(syncMock1.source)

      // Verify syncMock0 is still usable for next query (lastFailedAt was not set).
      // Fail syncMock1 with ImpossibleForTheQuery so the system must fall back to syncMock0.

      let p2 =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isLive=false,
          ~knownHeight=100,
        )
      switch syncMock1.getItemsOrThrowCalls {
      | [call] =>
        call.reject(
          Source.GetItemsError(
            FailedGettingItems({
              exn: %raw(`null`),
              attemptedToBlock: 100,
              retry: ImpossibleForTheQuery({message: "test impossible on mock1"}),
            }),
          ),
        )
      | _ => JsError.throwWithMessage("Expected one pending call to syncMock1")
      }
      await Promise.resolve()
      switch syncMock0.getItemsOrThrowCalls {
      | [call] => call.resolve([])
      | _ => JsError.throwWithMessage("Expected syncMock0 to be usable (lastFailedAt not set)")
      }
      let _ = await p2
      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="syncMock0 should be usable since ImpossibleForTheQuery doesn't set lastFailedAt",
      ).toBe(syncMock0.source)
    },
  )

  Async.it(
    "Multiple ImpossibleForTheQuery excludes sources sequentially within a single query",
    async t => {
      let syncMock0 = MockIndexer.Source.make([#getItemsOrThrow])
      let syncMock1 = MockIndexer.Source.make([#getItemsOrThrow])
      let syncMock2 = MockIndexer.Source.make([#getItemsOrThrow])
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[syncMock0.source, syncMock1.source, syncMock2.source],
        ~maxPartitionConcurrency=10,
      )

      let p =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isLive=false,
          ~knownHeight=100,
        )

      // syncMock0 gets the query first. Fail with ImpossibleForTheQuery.
      switch syncMock0.getItemsOrThrowCalls {
      | [call] =>
        call.reject(
          Source.GetItemsError(
            FailedGettingItems({
              exn: %raw(`null`),
              attemptedToBlock: 100,
              retry: ImpossibleForTheQuery({message: "impossible on mock0"}),
            }),
          ),
        )
      | _ => JsError.throwWithMessage("Expected one pending call to syncMock0")
      }
      await Promise.resolve()

      // syncMock1 gets the query next. Also fail with ImpossibleForTheQuery.
      switch syncMock1.getItemsOrThrowCalls {
      | [call] =>
        call.reject(
          Source.GetItemsError(
            FailedGettingItems({
              exn: %raw(`null`),
              attemptedToBlock: 100,
              retry: ImpossibleForTheQuery({message: "impossible on mock1"}),
            }),
          ),
        )
      | _ => JsError.throwWithMessage("Expected one pending call to syncMock1")
      }
      await Promise.resolve()

      // syncMock2 gets the query. Both mock0 and mock1 are excluded.
      switch syncMock2.getItemsOrThrowCalls {
      | [call] => call.resolve([])
      | _ => JsError.throwWithMessage("Expected one pending call to syncMock2")
      }
      let _ = await p

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should end up on syncMock2 after excluding mock0 and mock1",
      ).toBe(syncMock2.source)
    },
  )

  Async.it("Tier fallback: when all primaries are in recovery, uses working secondary", async t => {
    let syncMock = MockIndexer.Source.make([#getItemsOrThrow])
    let fallbackMock = MockIndexer.Source.make([#getItemsOrThrow], ~sourceFor=Fallback)
    let recoveryTimeout = 50.0
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[syncMock.source, fallbackMock.source],
      ~maxPartitionConcurrency=10,
      ~recoveryTimeout,
    )

    // Fail sync with WithBackoff enough times to trigger a switch (retries 0, 1, 2)
    let p1 =
      sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
    let withBackoff = Source.GetItemsError(
      FailedGettingItems({
        exn: %raw(`null`),
        attemptedToBlock: 100,
        retry: WithBackoff({message: "test backoff", backoffMillis: 0}),
      }),
    )
    for idx in 0 to 2 {
      switch syncMock.getItemsOrThrowCalls {
      | [call] => call.reject(withBackoff)
      | _ =>
        JsError.throwWithMessage(
          `Expected one pending call to syncMock at retry ${idx->Int.toString}`,
        )
      }
      await Promise.resolve()
      if idx !== 2 {
        await Utils.delay(0)
      }
    }
    // After retry 2 (shouldSwitch=true), lastFailedAt is set on sync.
    // Next iteration picks fallback (working secondary) since sync is in recovery.
    await Utils.delay(0)
    switch fallbackMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ =>
      JsError.throwWithMessage("Expected fallback to get the query after sync entered recovery")
    }
    let _ = await p1

    t.expect(
      sourceManager->SourceManager.getActiveSource,
      ~message="Should switch to fallback (secondary) when primary is in recovery",
    ).toBe(fallbackMock.source)

    {
      // Before recovery timeout: sync is still in recovery, fallback should be used

      let p2 =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isLive=false,
          ~knownHeight=100,
        )
      switch fallbackMock.getItemsOrThrowCalls {
      | [call] => call.resolve([])
      | _ => JsError.throwWithMessage("Expected fallback to be used before recovery timeout")
      }
      let _ = await p2
      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should stay on fallback before recovery timeout",
      ).toBe(fallbackMock.source)
    }

    // After recovery timeout: sync recovers, becomes primary again
    await Utils.delay(recoveryTimeout->Float.toInt)

    let p3 =
      sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
    switch syncMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ => JsError.throwWithMessage("Expected sync to recover after timeout")
    }
    let _ = await p3
    t.expect(
      sourceManager->SourceManager.getActiveSource,
      ~message="Should recover to sync after recovery timeout",
    ).toBe(syncMock.source)
  })

  Async.it("ExcludedSources filtering causes tier fallback to secondary", async t => {
    let syncMock0 = MockIndexer.Source.make([#getItemsOrThrow])
    let syncMock1 = MockIndexer.Source.make([#getItemsOrThrow])
    let fallbackMock = MockIndexer.Source.make([#getItemsOrThrow], ~sourceFor=Fallback)
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[syncMock0.source, syncMock1.source, fallbackMock.source],
      ~maxPartitionConcurrency=10,
    )

    let p =
      sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)

    // Exclude syncMock0 via ImpossibleForTheQuery
    switch syncMock0.getItemsOrThrowCalls {
    | [call] =>
      call.reject(
        Source.GetItemsError(
          FailedGettingItems({
            exn: %raw(`null`),
            attemptedToBlock: 100,
            retry: ImpossibleForTheQuery({message: "impossible on mock0"}),
          }),
        ),
      )
    | _ => JsError.throwWithMessage("Expected one pending call to syncMock0")
    }
    await Promise.resolve()

    // Exclude syncMock1 via ImpossibleForTheQuery
    switch syncMock1.getItemsOrThrowCalls {
    | [call] =>
      call.reject(
        Source.GetItemsError(
          FailedGettingItems({
            exn: %raw(`null`),
            attemptedToBlock: 100,
            retry: ImpossibleForTheQuery({message: "impossible on mock1"}),
          }),
        ),
      )
    | _ => JsError.throwWithMessage("Expected one pending call to syncMock1")
    }
    await Promise.resolve()

    // All primaries excluded — should fall back to secondary (fallback)
    switch fallbackMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ =>
      JsError.throwWithMessage("Expected fallback to get the query after all primaries excluded")
    }
    let _ = await p

    t.expect(
      sourceManager->SourceManager.getActiveSource,
      ~message="Should fall back to secondary when all primaries are excluded",
    ).toBe(fallbackMock.source)
  })

  Async.it("WithBackoff with single source retries with delay, no crash", async t => {
    let syncMock = MockIndexer.Source.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[syncMock.source],
      ~maxPartitionConcurrency=10,
    )

    let p =
      sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
    let withBackoff = Source.GetItemsError(
      FailedGettingItems({
        exn: %raw(`null`),
        attemptedToBlock: 100,
        retry: WithBackoff({message: "test backoff", backoffMillis: 0}),
      }),
    )

    // Fail 4 times (retries 0, 1, 2, 3) — covers both shouldSwitch=false and shouldSwitch=true
    for idx in 0 to 3 {
      switch syncMock.getItemsOrThrowCalls {
      | [call] => call.reject(withBackoff)
      | _ => JsError.throwWithMessage(`Expected one pending call at retry ${idx->Int.toString}`)
      }
      await Promise.resolve()
      await Utils.delay(0)
    }

    // On retry 4, succeed
    switch syncMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ => JsError.throwWithMessage("Expected one pending call for final resolve")
    }
    let _ = await p

    t.expect(
      sourceManager->SourceManager.getActiveSource,
      ~message="Single source should still be active after retries",
    ).toBe(syncMock.source)
  })

  Async.it(
    "ActiveSource excluded via ImpossibleForTheQuery falls back to next candidate",
    async t => {
      let syncMock0 = MockIndexer.Source.make([#getItemsOrThrow])
      let syncMock1 = MockIndexer.Source.make([#getItemsOrThrow])
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[syncMock0.source, syncMock1.source],
        ~maxPartitionConcurrency=10,
      )

      // First query: succeed on syncMock0 (activeSource), then fail with ImpossibleForTheQuery on next query
      // to switch activeSource to syncMock1
      let p0 =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isLive=false,
          ~knownHeight=100,
        )
      switch syncMock0.getItemsOrThrowCalls {
      | [call] =>
        call.reject(
          Source.GetItemsError(
            FailedGettingItems({
              exn: %raw(`null`),
              attemptedToBlock: 100,
              retry: ImpossibleForTheQuery({message: "impossible on mock0"}),
            }),
          ),
        )
      | _ => JsError.throwWithMessage("Expected one pending call to syncMock0")
      }
      await Promise.resolve()
      switch syncMock1.getItemsOrThrowCalls {
      | [call] => call.resolve([])
      | _ => JsError.throwWithMessage("Expected syncMock1 to get the query")
      }
      let _ = await p0

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="activeSource should be syncMock1",
      ).toBe(syncMock1.source)

      // Now in next query, syncMock1 (activeSource) gets the query first.
      // Fail with ImpossibleForTheQuery — it should fall back to syncMock0.
      let p =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isLive=false,
          ~knownHeight=100,
        )
      switch syncMock1.getItemsOrThrowCalls {
      | [call] =>
        call.reject(
          Source.GetItemsError(
            FailedGettingItems({
              exn: %raw(`null`),
              attemptedToBlock: 100,
              retry: ImpossibleForTheQuery({message: "impossible on activeSource"}),
            }),
          ),
        )
      | _ => JsError.throwWithMessage("Expected one pending call to syncMock1")
      }
      await Promise.resolve()

      switch syncMock0.getItemsOrThrowCalls {
      | [call] => call.resolve([])
      | _ =>
        JsError.throwWithMessage("Expected syncMock0 to get the query after activeSource excluded")
      }
      let _ = await p

      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should fall back to syncMock0 when activeSource is excluded",
      ).toBe(syncMock0.source)
    },
  )

  Async.it("Disabling a Sync source does not affect hasLive", async t => {
    let syncMock = MockIndexer.Source.make([#getItemsOrThrow])
    let liveMock = MockIndexer.Source.make([#getItemsOrThrow], ~sourceFor=Live)
    let fallbackMock = MockIndexer.Source.make([#getItemsOrThrow], ~sourceFor=Fallback)
    let sourceManager = SourceManager.make(
      ~isLive=false,
      ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
      ~maxPartitionConcurrency=10,
    )

    // In isLive=true mode, liveMock is Primary (hasLive=true).
    // Disable sync via UnsupportedSelection — should NOT affect hasLive.
    let p1 =
      sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=true, ~knownHeight=100)
    // liveMock is primary in live mode, gets query first
    switch liveMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ => JsError.throwWithMessage("Expected liveMock to get the query in live mode")
    }
    let _ = await p1

    // Now disable sync via a backfill query where sync is primary
    let p2 =
      sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=false, ~knownHeight=100)
    switch syncMock.getItemsOrThrowCalls {
    | [call] =>
      call.reject(Source.GetItemsError(UnsupportedSelection({message: "test disable sync"})))
    | _ => JsError.throwWithMessage("Expected one pending call to syncMock")
    }
    await Utils.delay(0)
    // fallbackMock should get the query as secondary (Live has no role in backfill)
    switch fallbackMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ => JsError.throwWithMessage("Expected fallbackMock to get the query after sync disabled")
    }
    let _ = await p2

    // In isLive=true mode again, liveMock should still be Primary (hasLive unaffected by sync disable)
    let p3 =
      sourceManager->SourceManager.executeQuery(~query=mockQuery(), ~isLive=true, ~knownHeight=100)
    switch liveMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ =>
      JsError.throwWithMessage("Expected liveMock to be primary in live mode (hasLive still true)")
    }
    let _ = await p3

    t.expect(
      sourceManager->SourceManager.getActiveSource,
      ~message="Live source should remain primary — disabling Sync doesn't affect hasLive",
    ).toBe(liveMock.source)
  })
})

describe("SourceManager height subscription", () => {
  Async.it(
    "Creates subscription when getHeightOrThrow returns same height as knownHeight",
    async t => {
      let mock = MockIndexer.Source.make([#getHeightOrThrow, #createHeightSubscription])
      let sourceManager = SourceManager.make(
        ~isLive=true,
        ~sources=[mock.source],
        ~maxPartitionConcurrency=10,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)

      // First call to getHeightOrThrow
      t.expect(mock.getHeightOrThrowCalls->Array.length).toEqual(1)
      // Return the same height - should trigger subscription creation
      mock.resolveGetHeightOrThrow(100)

      // Wait for the subscription to be created
      await Utils.delay(0)

      t.expect(
        mock.heightSubscriptionCalls->Array.length,
        ~message="Should have created a height subscription",
      ).toEqual(1)

      // Trigger new height from subscription
      mock.triggerHeightSubscription(101)

      t.expect(await p, ~message="Should resolve with the subscription height").toEqual(101)
    },
  )

  Async.it("Uses cached height from subscription if higher than knownHeight", async t => {
    let mock = MockIndexer.Source.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(
      ~isLive=true,
      ~sources=[mock.source],
      ~maxPartitionConcurrency=10,
    )

    // First call - create subscription
    let p1 = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    mock.triggerHeightSubscription(105)
    t.expect(await p1).toEqual(105)

    // Second call - should use cached height immediately without calling getHeightOrThrow
    let p2 = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=101)
    t.expect(
      mock.getHeightOrThrowCalls->Array.length,
      ~message="Should not call getHeightOrThrow again since subscription exists",
    ).toEqual(1)
    t.expect(await p2, ~message="Should immediately return cached height").toEqual(105)
  })

  Async.it(
    "Waits for next height event when subscription exists but height <= knownHeight",
    async t => {
      let mock = MockIndexer.Source.make([#getHeightOrThrow, #createHeightSubscription])
      let sourceManager = SourceManager.make(
        ~isLive=true,
        ~sources=[mock.source],
        ~maxPartitionConcurrency=10,
      )

      // First call - create subscription and set initial height
      let p1 = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      mock.triggerHeightSubscription(101)
      t.expect(await p1).toEqual(101)

      // Second call with higher knownHeight - should wait for next subscription event
      let p2 = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=101)
      t.expect(
        mock.getHeightOrThrowCalls->Array.length,
        ~message="Should not call getHeightOrThrow since subscription exists",
      ).toEqual(1)

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
      let mock = MockIndexer.Source.make([#getHeightOrThrow], ~pollingInterval)
      let sourceManager = SourceManager.make(
        ~isLive=false,
        ~sources=[mock.source],
        ~maxPartitionConcurrency=10,
      )

      let p = sourceManager->SourceManager.waitForNewBlock(~isLive=false, ~knownHeight=100)

      // Return same height - should trigger polling since no subscription available
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(pollingInterval + 1)

      t.expect(
        mock.getHeightOrThrowCalls->Array.length,
        ~message="Should poll again since no subscription is available",
      ).toEqual(2)

      mock.resolveGetHeightOrThrow(101)
      t.expect(await p).toEqual(101)
    },
  )

  Async.it(
    "Falls back to REST polling when subscription goes quiet for half the stall timeout",
    async t => {
      let stallTimeout = 20
      let mock = MockIndexer.Source.make([#getHeightOrThrow, #createHeightSubscription])
      let sourceManager = SourceManager.make(
        ~isLive=true,
        ~sources=[mock.source],
        ~maxPartitionConcurrency=10,
        ~newBlockStallTimeoutLive=stallTimeout,
      )

      // First call - create subscription
      let p1 = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      mock.triggerHeightSubscription(101)
      t.expect(await p1).toEqual(101)

      // Second call - subscription exists but won't deliver
      let p2 = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=101)

      // Wait for stallTimeout/2 to trigger REST polling fallback
      await Utils.delay(stallTimeout / 2 + 5)

      t.expect(
        mock.getHeightOrThrowCalls->Array.length,
        ~message="Should have called getHeightOrThrow as polling fallback",
      ).toBeGreaterThanOrEqual(2)

      // Resolve the REST polling with a new height
      mock.resolveGetHeightOrThrow(102)

      t.expect(await p2, ~message="Should resolve via REST polling fallback").toEqual(102)
    },
  )

  Async.it("Ignores subscription heights lower than or equal to knownHeight", async t => {
    let mock = MockIndexer.Source.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(
      ~isLive=true,
      ~sources=[mock.source],
      ~maxPartitionConcurrency=10,
    )

    // First call - create subscription
    let p1 = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=100)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    mock.triggerHeightSubscription(101)
    t.expect(await p1).toEqual(101)

    // Second call with higher knownHeight
    let p2 = sourceManager->SourceManager.waitForNewBlock(~isLive=true, ~knownHeight=105)

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
    t.expect(resolved.contents, ~message="Should not resolve with height <= knownHeight").toEqual(
      false,
    )

    // Finally trigger with valid height
    mock.triggerHeightSubscription(106)
    t.expect(await p2, ~message="Should resolve with height > knownHeight").toEqual(106)
  })
})
