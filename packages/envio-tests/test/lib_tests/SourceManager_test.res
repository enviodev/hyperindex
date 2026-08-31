open Vitest

// Spread into query literals so the common fields don't have to be repeated;
// every other field is overridden at the call site.
let defaultQuery: FetchState.query = {
  partitionId: "0",
  fromBlock: 0,
  toBlock: None,
  isChunk: false,
  itemsTarget: Some(0),
  itemsEst: 0,
  selection: {FetchState.dependsOnAddresses: false, onEventRegistrations: []},
  addresses: TestAddresses.setOf([]),
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

describe("native request failures", () => {
  it("keeps timings and maps a wrapped HyperSync rate limit", t => {
    let exn = try {
      JsError.throwWithMessage(`ENVIO_NATIVE_FAILURE:{"message":"RATE_LIMITED:2500","requestStats":[{"method":"getBlockHashes","seconds":0.25}]}`)
    } catch {
    | exn => exn
    }
    t.expect({
      "requestStats": (exn->Source.unpackNativeRequestFailure).requestStats,
      "mapped": exn->HyperSync.mapNativeFailureExn,
    }).toEqual({
      "requestStats": [{Source.method: "getBlockHashes", seconds: 0.25}],
      "mapped": Source.RateLimited({
        resetMs: 2500,
        requestStats: [{Source.method: "getBlockHashes", seconds: 0.25}],
      }),
    })
  })
})

describe("SourceManager creation", () => {
  it("Successfully creates with a sync source", t => {
    let source = MockSource.make([]).source
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[source])
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(source)
  })

  it("Uses first sync source as initial active source", t => {
    let fallback = MockSource.make([], ~sourceFor=Fallback).source
    let sync0 = MockSource.make([]).source
    let sync1 = MockSource.make([]).source
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[fallback, sync0, sync1])
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(sync0)
  })

  it("Prefers sync source over live source as initial active source", t => {
    let live = MockSource.make([], ~sourceFor=Realtime).source
    let sync = MockSource.make([]).source
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[live, sync])
    // Sync is always preferred as initial active source (backfill mode)
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(sync)
  })

  it("Prefers live source over sync source as initial active source in live mode", t => {
    let sync = MockSource.make([]).source
    let live = MockSource.make([], ~sourceFor=Realtime).source
    let sourceManager = SourceManager.make(~isRealtime=true, ~sources=[sync, live])
    t.expect(sourceManager->SourceManager.getActiveSource).toBe(live)
  })

  it("Fails to create without primary sources", t => {
    t->toThrowErrorEqual(
      () => {
        SourceManager.make(~isRealtime=false, ~sources=[])
      },
      "Invalid configuration, no data-source for historical sync provided",
    )
    t->toThrowErrorEqual(
      () => {
        SourceManager.make(
          ~isRealtime=false,
          ~sources=[MockSource.make([], ~sourceFor=Fallback).source],
        )
      },
      "Invalid configuration, no data-source for historical sync provided",
    )
  })
})

describe("SourceManager.getSourceRole", () => {
  it("Backfill (isRealtime=false): Sync is Primary, Fallback is Secondary, Live is ignored", t => {
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Sync, ~isRealtime=false, ~hasRealtime=false),
    ).toEqual(Some(Primary))
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Fallback, ~isRealtime=false, ~hasRealtime=false),
    ).toEqual(Some(Secondary))
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Realtime, ~isRealtime=false, ~hasRealtime=false),
    ).toEqual(None)
    // hasRealtime doesn't matter during backfill
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Sync, ~isRealtime=false, ~hasRealtime=true),
    ).toEqual(Some(Primary))
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Realtime, ~isRealtime=false, ~hasRealtime=true),
    ).toEqual(None)
  })

  it("Live mode with Live source: Live is Primary, Sync+Fallback are Secondary", t => {
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Realtime, ~isRealtime=true, ~hasRealtime=true),
    ).toEqual(Some(Primary))
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Sync, ~isRealtime=true, ~hasRealtime=true),
    ).toEqual(Some(Secondary))
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Fallback, ~isRealtime=true, ~hasRealtime=true),
    ).toEqual(Some(Secondary))
  })

  it("Live mode without Live source: Sync is Primary, Fallback is Secondary", t => {
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Sync, ~isRealtime=true, ~hasRealtime=false),
    ).toEqual(Some(Primary))
    t.expect(
      SourceManager.getSourceRole(~sourceFor=Fallback, ~isRealtime=true, ~hasRealtime=false),
    ).toEqual(Some(Secondary))
  })
})

describe("SourceManager source priority with Live sources", () => {
  let selection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}
  let addresses = TestAddresses.setOf([])

  let mockQuery = (): FetchState.query => {
    partitionId: "0",
    itemsTarget: Some(5000),
    itemsEst: 5000,
    fromBlock: 0,
    toBlock: None,
    isChunk: false,
    selection,
    addresses,
  }

  Async.it(
    "During isRealtime=true with Live source: Live is primary, Sync+Fallback are secondary in waitForNewBlock",
    async t => {
      let syncMock = MockSource.make([#getHeightOrThrow])
      let liveMock = MockSource.make([#getHeightOrThrow], ~sourceFor=Realtime)
      let fallbackMock = MockSource.make([#getHeightOrThrow], ~sourceFor=Fallback)
      let newBlockStallTimeoutRealtime = 5
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
        ~newBlockStallTimeoutRealtime,
      )

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=true,
          ~knownHeight=100,
          ~reducedPolling=false,
        )

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
    "During isRealtime=true with Live source: Sync and Fallback are used as secondary after timeout",
    async t => {
      let syncMock = MockSource.make([#getHeightOrThrow])
      let liveMock = MockSource.make([#getHeightOrThrow], ~sourceFor=Realtime)
      let fallbackMock = MockSource.make([#getHeightOrThrow], ~sourceFor=Fallback)
      let newBlockStallTimeoutRealtime = 5
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
        ~newBlockStallTimeoutRealtime,
      )

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=true,
          ~knownHeight=100,
          ~reducedPolling=false,
        )

      // Live doesn't find new block
      liveMock.resolveGetHeightOrThrow(100)

      // Wait for stall timeout
      await Utils.delay(newBlockStallTimeoutRealtime)

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
    "During isRealtime=true with Live source: recovery from secondary goes to Live (not Sync)",
    async t => {
      let syncMock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow])
      let liveMock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Realtime)
      let fallbackMock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Fallback)
      let newBlockStallTimeoutRealtime = 0
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~newBlockStallTimeoutRealtime,
        ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
      )

      {
        // Switch to fallback via waitForNewBlock with isRealtime=true

        let p =
          sourceManager->SourceManager.waitForNewBlock(
            ~isRealtime=true,
            ~knownHeight=100,
            ~reducedPolling=false,
          )
        await Utils.delay(newBlockStallTimeoutRealtime)
        fallbackMock.resolveGetHeightOrThrow(101)
        t.expect(await p).toBe(101)
        t.expect(sourceManager->SourceManager.getActiveSource).toBe(fallbackMock.source)
      }

      {
        // Live never failed in executeQuery, recovery is immediate.
        // With isRealtime=true, Live is Primary so recovery goes to Live, not Sync.

        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isRealtime=true,
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
        ~message="Should recover to Live source (primary when isRealtime=true), not Sync",
      ).toBe(liveMock.source)
    },
  )

  Async.it(
    "During isRealtime=true without Live source: Sync is primary, Fallback is secondary",
    async t => {
      let syncMock = MockSource.make([#getHeightOrThrow])
      let fallbackMock = MockSource.make([#getHeightOrThrow], ~sourceFor=Fallback)
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[syncMock.source, fallbackMock.source],
      )

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=true,
          ~knownHeight=0,
          ~reducedPolling=false,
        )

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
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}

  // Selection (getNextQuery) now happens in CrossChainState; SourceManager only
  // dispatches the chosen action. This shim keeps the per-chain tests focused on
  // dispatch by computing the action from the chain's own fetch state.
  let fetchNext = (
    sourceManager,
    ~fetchState: FetchState.t,
    ~executeQuery,
    ~waitForNewBlock,
    ~onNewBlock,
    ~stateId,
  ) => {
    let action =
      fetchState->FetchState.getNextQuery(
        ~chainTargetBlock=fetchState.knownHeight,
        ~chainTargetItems=50_000.,
      )
    // CrossChainState marks queries in flight when admitting them; dispatch no
    // longer does, so mirror that here before dispatching.
    switch action {
    | Ready(queries) => fetchState->FetchState.startFetchingQueries(~queries)
    | _ => ()
    }
    sourceManager->SourceManager.dispatch(
      ~fetchState,
      ~executeQuery,
      ~waitForNewBlock,
      ~onNewBlock,
      ~action,
      ~stateId,
    )
  }

  let mockFullPartition = (
    ~partitionIndex,
    ~latestFetchedBlockNumber,
    ~numContracts=2,
  ): FetchState.partition => {
    let addresses = []
    for i in 0 to numContracts - 1 {
      let address = Envio.TestHelpers.Addresses.mockAddresses[i]->Option.getOrThrow
      addresses->Array.push(address)
    }

    {
      id: partitionIndex->Int.toString,
      latestFetchedBlock: latestFetchedBlockNumber,
      selection: normalSelection,
      addresses: TestAddresses.setOf(addresses),
      mergeBlock: None,
      dynamicContract: None,
      mutPendingQueries: [],
      sourceRangeCapacity: 0,
      eventDensity: None,
      prevSourceRangeCapacity: 0,
      latestSourceRangeCapacityUpdateBlock: 0,
    }
  }

  let mockFetchState = (
    partitions: array<FetchState.partition>,
    ~endBlock=None,
    ~buffer=[],
    ~targetBufferSize=5000,
    ~knownHeight,
  ): FetchState.t => {
    let latestFullyFetchedBlock = ref((partitions->Utils.Array.firstUnsafe).latestFetchedBlock)

    partitions->Array.forEach(partition => {
      if latestFullyFetchedBlock.contents > partition.latestFetchedBlock {
        latestFullyFetchedBlock := partition.latestFetchedBlock
      }
    })

    let optimizedPartitions = FetchState.OptimizedPartitions.make(
      ~partitions,
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=partitions->Array.length,
      ~dynamicContracts=Utils.Set.make(),
      ~clientFilteredContracts=Utils.Set.make(),
    )

    {
      optimizedPartitions,
      startBlock: 0,
      endBlock,
      buffer,
      normalSelection,
      latestOnBlockBlockNumber: latestFullyFetchedBlock.contents,
      maxOnBlockBufferSize: targetBufferSize,
      chainId: 0->ChainId.fromInt,
      blockLag: 0,
      onBlockRegistrations: [],
      knownHeight,
      firstEventBlock: None,
      clientFilterAddressThreshold: None,
    }
  }

  let neverWaitForNewBlock = async (~knownHeight as _) =>
    JsError.throwWithMessage("The waitForNewBlock shouldn't be called for the test")

  let neverOnNewBlock = (~knownHeight as _) =>
    JsError.throwWithMessage("The onNewBlock shouldn't be called for the test")

  let neverExecutePartitionQuery = _ =>
    JsError.throwWithMessage("The executeQuery shouldn't be called for the test")

  let source: Source.t = MockSource.make([]).source

  it("getNextQuery caps a partition at 10 pending chunks", t => {
    let pendingChunk = (idx): FetchState.pendingQuery => {
      fromBlock: idx * 10 + 1,
      toBlock: Some(idx * 10 + 10),
      isChunk: true,
      itemsTarget: None,
      itemsEst: 5000,
      fetchedBlock: None,
    }
    // Chunking on (sourceRangeCapacity set) so the tail wants two chunks per round.
    let withPending = count => {
      let p = {
        ...mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=0),
        mutPendingQueries: Array.fromInitializer(~length=count, pendingChunk),
        sourceRangeCapacity: 10,
        eventDensity: None,
        prevSourceRangeCapacity: 10,
      }
      mockFetchState([p], ~knownHeight=1000)
    }
    let newQueryCount = nextQuery =>
      switch nextQuery {
      | FetchState.Ready(queries) => queries->Array.length
      | _ => 0
      }

    t.expect({
      // 10 already pending: the partition is capped, so the scheduler issues nothing.
      "atCap": withPending(10)->FetchState.getNextQuery(
        ~chainTargetBlock=1000,
        ~chainTargetItems=0.,
      ),
      // 9 pending (45_000 already reserved): plenty of fresh chainTargetItems
      // headroom above that, so the two-chunk tail is trimmed down to the one
      // remaining slot by the chunk cap, not by budget.
      "oneSlotLeft": withPending(9)
      ->FetchState.getNextQuery(~chainTargetBlock=1000, ~chainTargetItems=100_000.)
      ->newQueryCount,
    }).toEqual({"atCap": FetchState.NothingToQuery, "oneSlotLeft": 1})
  })

  Async.it(
    "Executes full partitions in any order when we didn't reach concurency limit",
    async t => {
      let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[source])

      let partition0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4)
      let partition1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)
      let partition2 = mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=1)

      let fetchState = mockFetchState([partition0, partition1, partition2], ~knownHeight=10)

      let executeQueryMock = executeQueryMock()

      let fetchNextPromise =
        sourceManager->fetchNext(
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
          itemsTarget: Some(16_667),
          itemsEst: 16_667,
          fromBlock: 2,
          toBlock: None,
          isChunk: false,
          selection: normalSelection,
          addresses: partition2.addresses,
        },
        {
          partitionId: "0",
          // Starts at block 5 vs partition "2"'s block 2, so it covers less of
          // the range to the target and gets a smaller probe.
          itemsTarget: Some(11_111),
          itemsEst: 11_111,
          fromBlock: 5,
          toBlock: None,
          isChunk: false,
          selection: normalSelection,
          addresses: partition0.addresses,
        },
        {
          partitionId: "1",
          // Starts furthest ahead (block 6), so it gets the smallest probe.
          itemsTarget: Some(9_259),
          itemsEst: 9_259,
          fromBlock: 6,
          toBlock: None,
          isChunk: false,
          selection: normalSelection,
          addresses: partition1.addresses,
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
    "Skips full partitions at the chain last block and the ones at the mergeBlock",
    async t => {
      let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[source])

      let p0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4)
      let p1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)
      let p2 = mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=1)
      let p3 = mockFullPartition(~partitionIndex=3, ~latestFetchedBlockNumber=4)

      let executeQueryMock = executeQueryMock()

      let fetchNextPromise =
        sourceManager->fetchNext(
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
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[source])

    let waitForNewBlockMock = waitForNewBlockMock()
    let onNewBlockMock = onNewBlockMock()

    let fetchNextPromise1 =
      sourceManager->fetchNext(
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
      sourceManager->fetchNext(
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
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[source])

    let waitForNewBlockMock = waitForNewBlockMock()
    let onNewBlockMock = onNewBlockMock()

    let fetchNextPromise1 =
      sourceManager->fetchNext(
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
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[source])

    let p0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=5)
    let p1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)

    let waitForNewBlockMock = waitForNewBlockMock()
    let onNewBlockMock = onNewBlockMock()

    let fetchNextPromise =
      sourceManager->fetchNext(
        ~fetchState=mockFetchState([p0, p1], ~knownHeight=5),
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=onNewBlockMock.fn,
        ~stateId=0,
      )

    t.expect(waitForNewBlockMock.calls).toEqual([5])

    // Should do nothing on the second call with the same data
    await sourceManager->fetchNext(
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
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[source])

    let p0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=5)

    let waitForNewBlockMock = waitForNewBlockMock()
    let onNewBlockMock = onNewBlockMock()

    let fetchNextPromise =
      sourceManager->fetchNext(
        ~fetchState=mockFetchState([p0], ~knownHeight=5),
        ~executeQuery=neverExecutePartitionQuery,
        ~waitForNewBlock=waitForNewBlockMock.fn,
        ~onNewBlock=neverOnNewBlock,
        ~stateId=0,
      )

    t.expect(waitForNewBlockMock.calls, ~message=`Should wait for new block`).toEqual([5])

    // Should do nothing on the second call with the same data
    await sourceManager->fetchNext(
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
      sourceManager->fetchNext(
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

  Async.it("Filters out partitions at the endBlock and at the head", async t => {
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[source])

    let executeQueryMock = executeQueryMock()

    let fetchNextPromise = sourceManager->fetchNext(
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

    // p0 is at the endBlock and p1 is at the head, so only the two behind
    // partitions are queried, furthest-behind first.
    t.expect(executeQueryMock.callIds).toEqual(["3", "2"])
  })
})

describe("SourceManager wait for new blocks", () => {
  Async.it(
    "Immediately resolves when the source height is higher than the current height",
    async t => {
      let {source, getHeightOrThrowCalls, resolveGetHeightOrThrow} = MockSource.make([
        #getHeightOrThrow,
      ])
      let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[source])

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=false,
          ~knownHeight=0,
          ~reducedPolling=false,
        )

      t.expect(getHeightOrThrowCalls->Array.length).toEqual(1)
      resolveGetHeightOrThrow(1)

      t.expect(await p).toEqual(1)
    },
  )

  Async.it(
    "Calls all sync sources in parallel. Resolves the first one with valid response",
    async t => {
      let mock0 = MockSource.make([#getHeightOrThrow])
      let mock1 = MockSource.make([#getHeightOrThrow])
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[mock0.source, mock1.source],
      )

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=false,
          ~knownHeight=0,
          ~reducedPolling=false,
        )

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

  Async.it("Excludes live source from height fetch when isRealtime is false", async t => {
    let syncMock = MockSource.make([#getHeightOrThrow])
    let liveMock = MockSource.make([#getHeightOrThrow], ~sourceFor=Realtime)
    let sourceManager = SourceManager.make(
      ~isRealtime=false,
      ~sources=[syncMock.source, liveMock.source],
    )

    let p =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=false,
        ~knownHeight=0,
        ~reducedPolling=false,
      )

    t.expect(
      syncMock.getHeightOrThrowCalls->Array.length,
      ~message="Should call sync source",
    ).toEqual(1)
    t.expect(
      liveMock.getHeightOrThrowCalls->Array.length,
      ~message="Should not call live source when isRealtime is false",
    ).toEqual(0)

    syncMock.resolveGetHeightOrThrow(1)
    t.expect(await p).toEqual(1)
    t.expect(
      sourceManager->SourceManager.getActiveSource,
      ~message="Should stay on sync source",
    ).toBe(syncMock.source)
  })

  Async.it("Includes live source in height fetch when isRealtime is true", async t => {
    let syncMock = MockSource.make([#getHeightOrThrow])
    let liveMock = MockSource.make([#getHeightOrThrow], ~sourceFor=Realtime)
    let sourceManager = SourceManager.make(
      ~isRealtime=false,
      ~sources=[syncMock.source, liveMock.source],
    )
    let p =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=0,
        ~reducedPolling=false,
      )

    // With new priority logic: Live is Primary, Sync is Secondary when Live is present
    t.expect(
      syncMock.getHeightOrThrowCalls->Array.length,
      ~message="Sync source should not be called yet (secondary when Live present)",
    ).toEqual(0)
    t.expect(
      liveMock.getHeightOrThrowCalls->Array.length,
      ~message="Should call live source as primary when isRealtime is true",
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
      let mock0 = MockSource.make([#getHeightOrThrow], ~pollingInterval=pollingInterval0)
      let mock1 = MockSource.make([#getHeightOrThrow], ~pollingInterval=pollingInterval1)
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[mock0.source, mock1.source],
      )

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=false,
          ~knownHeight=100,
          ~reducedPolling=false,
        )

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
      let mock0 = MockSource.make([#getHeightOrThrow], ~pollingInterval=pollingInterval0)
      let mock1 = MockSource.make([#getHeightOrThrow], ~pollingInterval=pollingInterval1)
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[mock0.source, mock1.source],
        ~getHeightRetryInterval=SourceManager.makeGetHeightRetryInterval(
          ~initialRetryInterval,
          ~backoffMultiplicative=2,
          ~maxRetryInterval=10,
        ),
      )

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=false,
          ~knownHeight=100,
          ~reducedPolling=false,
        )

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
      let sync = MockSource.make([#getHeightOrThrow], ~pollingInterval)
      let fallback = MockSource.make(~sourceFor=Fallback, [#getHeightOrThrow], ~pollingInterval)
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[sync.source, fallback.source],
        ~newBlockStallTimeout,
        ~stalledPollingInterval,
      )

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=false,
          ~knownHeight=100,
          ~reducedPolling=false,
        )

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

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=false,
          ~knownHeight=101,
          ~reducedPolling=false,
        )

      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="A poll is already in flight for sync, and it answers the new wait rather than being stacked on",
      ).toEqual(3)
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
      ).toEqual(3)
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
      let sync = MockSource.make([#getHeightOrThrow], ~pollingInterval)

      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[sync.source],
        ~newBlockStallTimeout,
        ~stalledPollingInterval,
      )

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=false,
          ~knownHeight=100,
          ~reducedPolling=false,
        )

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

  Async.itWithOptions(
    "Uses reducedPollingInterval instead of pollingInterval when reducedPolling is true",
    {retry: 3},
    async t => {
      let pollingInterval = 1
      let stalledPollingInterval = 1
      let reducedPollingInterval = 10
      let sync = MockSource.make([#getHeightOrThrow], ~pollingInterval)

      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[sync.source],
        ~stalledPollingInterval,
        ~reducedPollingInterval,
      )

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=false,
          ~knownHeight=100,
          ~reducedPolling=true,
        )

      t.expect(sync.getHeightOrThrowCalls->Array.length).toEqual(1)
      // Return same height — no new block, triggers polling loop
      sync.resolveGetHeightOrThrow(100)

      // After pollingInterval (1ms) but before reducedPollingInterval (10ms),
      // no new call should have been made
      await Utils.delay(pollingInterval + 1)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Should NOT poll at normal pollingInterval when reducedPolling is true",
      ).toEqual(1)

      // After reducedPollingInterval, a new call should appear
      await Utils.delay(reducedPollingInterval)
      t.expect(
        sync.getHeightOrThrowCalls->Array.length,
        ~message="Should poll after reducedPollingInterval",
      ).toEqual(2)

      sync.resolveGetHeightOrThrow(101)
      t.expect(await p).toEqual(101)
    },
  )
})
describe("SourceManager.executeQuery", () => {
  let selection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}
  let addresses = TestAddresses.setOf([])

  let mockQuery = (): FetchState.query => {
    partitionId: "0",
    itemsTarget: Some(5000),
    itemsEst: 5000,
    fromBlock: 0,
    toBlock: None,
    isChunk: false,
    selection,
    addresses,
  }

  Async.it("Successfully executes the query", async t => {
    let {source, getItemsOrThrowCalls, resolveGetItemsOrThrow} = MockSource.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[source])
    let p =
      sourceManager->SourceManager.executeQuery(
        ~query=mockQuery(),
        ~isRealtime=false,
        ~knownHeight=100,
      )
    t.expect(getItemsOrThrowCalls->Array.map(call => call.payload)).toEqual([
      {"fromBlock": 0, "toBlock": None, "retry": 0, "p": "0"},
    ])
    resolveGetItemsOrThrow([])
    t.expect((await p).parsedQueueItems).toEqual([])
  })

  Async.it("calls source.onReorg before retrying an inconsistent response", async t => {
    let sourceMock = MockSource.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[sourceMock.source])
    let p =
      sourceManager->SourceManager.executeQuery(
        ~query={...mockQuery(), fromBlock: 10},
        ~isRealtime=false,
        ~knownHeight=100,
      )

    t.expect(sourceMock.reorgCallCount()).toEqual(0)
    switch sourceMock.getItemsOrThrowCalls {
    | [call] =>
      // The response contains block 9 twice with different hashes: once as the
      // range's parent guard and once as the reported latest block.
      call.resolve([], ~latestFetchedBlockNumber=9, ~latestFetchedBlockHash="0x0a")
    | _ => JsError.throwWithMessage("Expected the first source call")
    }

    await Utils.delay(200)
    t.expect(sourceMock.reorgCallCount()).toEqual(1)
    switch sourceMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ => JsError.throwWithMessage("Expected the retry after cache invalidation")
    }
    t.expect((await p).parsedQueueItems).toEqual([])
  })

  Async.it("Retries a source that hasn't reached the queried block yet", async t => {
    let sourceMock = MockSource.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[sourceMock.source])
    let p =
      sourceManager->SourceManager.executeQuery(
        ~query={...mockQuery(), fromBlock: 10},
        ~isRealtime=false,
        ~knownHeight=100,
      )

    // Every ecosystem's source raises this instead of building its own backoff,
    // so the retry cadence lives in one place.
    (sourceMock.getItemsOrThrowCalls->Utils.Array.firstUnsafe).reject(
      Source.SourceBehindHead({blockNumber: 10, requestStats: []}),
    )
    await Utils.delay(200)

    switch sourceMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ => JsError.throwWithMessage("Expected a retry after the source reported being behind")
    }
    t.expect((await p).parsedQueueItems).toEqual([])
  })

  Async.it("counts the requests a failed getItems still made", async t => {
    let sourceMock = MockSource.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[sourceMock.source])
    let p =
      sourceManager->SourceManager.executeQuery(
        ~query={...mockQuery(), fromBlock: 10},
        ~isRealtime=false,
        ~knownHeight=100,
      )

    // The native client reports the timings of the requests it made before
    // giving up, so a source failing under load still shows up in its metrics.
    (sourceMock.getItemsOrThrowCalls->Utils.Array.firstUnsafe).reject(
      Source.SourceBehindHead({
        blockNumber: 10,
        requestStats: [{Source.method: "getLogs", seconds: 0.5}],
      }),
    )
    await Utils.delay(200)

    switch sourceMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ => JsError.throwWithMessage("Expected a retry after the source reported being behind")
    }
    let _ = await p

    t.expect(
      sourceManager
      ->SourceManager.getRequestStatSamples
      ->Array.map(({method, count, seconds}) => (method, count, seconds)),
    ).toEqual([("getLogs", 1, 0.5)])
  })

  Async.it("Rethrows unknown errors", async t => {
    let sourceMock = MockSource.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[sourceMock.source])
    let p =
      sourceManager->SourceManager.executeQuery(
        ~query=mockQuery(),
        ~isRealtime=false,
        ~knownHeight=100,
      )
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
    let sourceMock = MockSource.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(
      ~isRealtime=false,
      ~sources=[
        sourceMock.source,
        // Added second source without mock to the test,
        // to verify that we don't switch to it
        MockSource.make([]).source,
      ],
    )
    let p =
      sourceManager->SourceManager.executeQuery(
        ~query=mockQuery(),
        ~isRealtime=false,
        ~knownHeight=100,
      )
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
      let syncMock = MockSource.make([#getItemsOrThrow])
      let fallbackMock = MockSource.make([#getItemsOrThrow], ~sourceFor=Fallback)
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[syncMock.source, fallbackMock.source],
      )

      // getNextSources picks sync (primary, recovered) at the start
      let p =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isRealtime=false,
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
      for _idx in 0 to 2 {
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
        await Utils.delay(0)
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
      let syncMock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow])
      let fallbackMock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Fallback)
      let newBlockStallTimeout = 0
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~newBlockStallTimeout,
        ~sources=[syncMock.source, fallbackMock.source],
      )

      {
        // Switch active source to fallback via waitForNewBlock

        let p =
          sourceManager->SourceManager.waitForNewBlock(
            ~isRealtime=false,
            ~knownHeight=100,
            ~reducedPolling=false,
          )
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
            ~isRealtime=false,
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
      let syncMock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow])
      let fallbackMock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Fallback)
      let recoveryTimeout = 5.0
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~recoveryTimeout,
        ~sources=[syncMock.source, fallbackMock.source],
      )

      {
        // Fail sync with WithBackoff errors until it switches to fallback

        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isRealtime=false,
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
            ~isRealtime=false,
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
            ~isRealtime=false,
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
    let syncMock = MockSource.make([#getItemsOrThrow])
    let recoveryTimeout = 0.0
    let sourceManager = SourceManager.make(
      ~isRealtime=false,
      ~sources=[syncMock.source],
      ~recoveryTimeout,
    )

    // Run several queries on sync source — even with zero timeout, no recovery should happen
    for _ in 0 to 5 {
      let p =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isRealtime=false,
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
      let liveMock = MockSource.make([#getItemsOrThrow], ~sourceFor=Realtime)
      let recoveryTimeout = 0.0
      let sourceManager = SourceManager.make(
        ~isRealtime=true,
        ~sources=[liveMock.source],
        ~recoveryTimeout,
      )

      // Run several queries on live source — even with zero timeout, no switch should happen
      for _ in 0 to 5 {
        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isRealtime=true,
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
      let syncMock = MockSource.make([#getHeightOrThrow])
      let liveMock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Realtime)
      let fallbackMock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Fallback)
      let newBlockStallTimeoutRealtime = 0
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~newBlockStallTimeoutRealtime,
        ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
      )

      {
        // Switch activeSource to fallback via waitForNewBlock

        let p =
          sourceManager->SourceManager.waitForNewBlock(
            ~isRealtime=true,
            ~knownHeight=100,
            ~reducedPolling=false,
          )
        await Utils.delay(newBlockStallTimeoutRealtime)
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
            ~isRealtime=true,
            ~knownHeight=100,
          )
        // Query goes to live (primary when isRealtime=true), not fallback
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
      let syncMock = MockSource.make([#getItemsOrThrow])
      let fallbackMock = MockSource.make([#getItemsOrThrow], ~sourceFor=Fallback)
      let recoveryTimeout = 5.0
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~recoveryTimeout,
        ~sources=[syncMock.source, fallbackMock.source],
      )

      {
        // Fail sync with WithBackoff until it switches to fallback

        let p =
          sourceManager->SourceManager.executeQuery(
            ~query=mockQuery(),
            ~isRealtime=false,
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
            ~isRealtime=false,
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
            ~isRealtime=false,
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
            ~isRealtime=false,
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
    "Disabling one of two Live sources keeps hasRealtime true, disabling both clears it",
    async t => {
      let syncMock = MockSource.make([#getItemsOrThrow])
      let liveMock0 = MockSource.make([#getItemsOrThrow], ~sourceFor=Realtime)
      let liveMock1 = MockSource.make([#getItemsOrThrow], ~sourceFor=Realtime)
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[syncMock.source, liveMock0.source, liveMock1.source],
      )

      // In isRealtime=true mode with hasRealtime=true, Live sources are Primary.
      // getNextSources picks liveMock0 (first primary).
      // Disable liveMock0 via UnsupportedSelection.
      let p1 =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isRealtime=true,
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
          ~isRealtime=true,
          ~knownHeight=100,
        )
      liveMock1.getItemsOrThrowCalls->Array.forEach(
        call => call.reject(Source.GetItemsError(UnsupportedSelection({message: "test disable"}))),
      )
      // With both Live sources disabled, hasRealtime should be false.
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
    let syncMock0 = MockSource.make([#getHeightOrThrow, #getItemsOrThrow])
    let syncMock1 = MockSource.make([#getHeightOrThrow, #getItemsOrThrow])
    let newBlockStallTimeout = 0
    let sourceManager = SourceManager.make(
      ~isRealtime=false,
      ~newBlockStallTimeout,
      ~sources=[syncMock0.source, syncMock1.source],
    )

    {
      // Switch activeSource to syncMock1 via waitForNewBlock

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=false,
          ~knownHeight=100,
          ~reducedPolling=false,
        )
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
          ~isRealtime=false,
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
      let syncMock0 = MockSource.make([#getItemsOrThrow])
      let syncMock1 = MockSource.make([#getItemsOrThrow])
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[syncMock0.source, syncMock1.source],
      )

      let p =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isRealtime=false,
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
          ~isRealtime=false,
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
      let syncMock0 = MockSource.make([#getItemsOrThrow])
      let syncMock1 = MockSource.make([#getItemsOrThrow])
      let syncMock2 = MockSource.make([#getItemsOrThrow])
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[syncMock0.source, syncMock1.source, syncMock2.source],
      )

      let p =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isRealtime=false,
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

  // Retried: coordination relies on real timers around a 50ms recovery timeout,
  // which is occasionally too tight under CI load.
  Async.itWithOptions(
    "Tier fallback: when all primaries are in recovery, uses working secondary",
    {retry: 3},
    async t => {
      let syncMock = MockSource.make([#getItemsOrThrow])
      let fallbackMock = MockSource.make([#getItemsOrThrow], ~sourceFor=Fallback)
      let recoveryTimeout = 50.0
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[syncMock.source, fallbackMock.source],
        ~recoveryTimeout,
      )

      // Fail sync with WithBackoff enough times to trigger a switch (retries 0, 1, 2)
      let p1 =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isRealtime=false,
          ~knownHeight=100,
        )
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
            ~isRealtime=false,
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
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isRealtime=false,
          ~knownHeight=100,
        )
      switch syncMock.getItemsOrThrowCalls {
      | [call] => call.resolve([])
      | _ => JsError.throwWithMessage("Expected sync to recover after timeout")
      }
      let _ = await p3
      t.expect(
        sourceManager->SourceManager.getActiveSource,
        ~message="Should recover to sync after recovery timeout",
      ).toBe(syncMock.source)
    },
  )

  Async.it("ExcludedSources filtering causes tier fallback to secondary", async t => {
    let syncMock0 = MockSource.make([#getItemsOrThrow])
    let syncMock1 = MockSource.make([#getItemsOrThrow])
    let fallbackMock = MockSource.make([#getItemsOrThrow], ~sourceFor=Fallback)
    let sourceManager = SourceManager.make(
      ~isRealtime=false,
      ~sources=[syncMock0.source, syncMock1.source, fallbackMock.source],
    )

    let p =
      sourceManager->SourceManager.executeQuery(
        ~query=mockQuery(),
        ~isRealtime=false,
        ~knownHeight=100,
      )

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
    let syncMock = MockSource.make([#getItemsOrThrow])
    let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[syncMock.source])

    let p =
      sourceManager->SourceManager.executeQuery(
        ~query=mockQuery(),
        ~isRealtime=false,
        ~knownHeight=100,
      )
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
      let syncMock0 = MockSource.make([#getItemsOrThrow])
      let syncMock1 = MockSource.make([#getItemsOrThrow])
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[syncMock0.source, syncMock1.source],
      )

      // First query: succeed on syncMock0 (activeSource), then fail with ImpossibleForTheQuery on next query
      // to switch activeSource to syncMock1
      let p0 =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isRealtime=false,
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
          ~isRealtime=false,
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

  Async.it("Disabling a Sync source does not affect hasRealtime", async t => {
    let syncMock = MockSource.make([#getItemsOrThrow])
    let liveMock = MockSource.make([#getItemsOrThrow], ~sourceFor=Realtime)
    let fallbackMock = MockSource.make([#getItemsOrThrow], ~sourceFor=Fallback)
    let sourceManager = SourceManager.make(
      ~isRealtime=false,
      ~sources=[syncMock.source, liveMock.source, fallbackMock.source],
    )

    // In isRealtime=true mode, liveMock is Primary (hasRealtime=true).
    // Disable sync via UnsupportedSelection — should NOT affect hasRealtime.
    let p1 =
      sourceManager->SourceManager.executeQuery(
        ~query=mockQuery(),
        ~isRealtime=true,
        ~knownHeight=100,
      )
    // liveMock is primary in live mode, gets query first
    switch liveMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ => JsError.throwWithMessage("Expected liveMock to get the query in live mode")
    }
    let _ = await p1

    // Now disable sync via a backfill query where sync is primary
    let p2 =
      sourceManager->SourceManager.executeQuery(
        ~query=mockQuery(),
        ~isRealtime=false,
        ~knownHeight=100,
      )
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

    // In isRealtime=true mode again, liveMock should still be Primary (hasRealtime unaffected by sync disable)
    let p3 =
      sourceManager->SourceManager.executeQuery(
        ~query=mockQuery(),
        ~isRealtime=true,
        ~knownHeight=100,
      )
    switch liveMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ =>
      JsError.throwWithMessage(
        "Expected liveMock to be primary in live mode (hasRealtime still true)",
      )
    }
    let _ = await p3

    t.expect(
      sourceManager->SourceManager.getActiveSource,
      ~message="Live source should remain primary — disabling Sync doesn't affect hasRealtime",
    ).toBe(liveMock.source)
  })

  Async.itWithOptions(
    "Disabled source is not polled for height as a stall fallback",
    {retry: 3},
    async t => {
      let syncMock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow])
      let liveMock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow], ~sourceFor=Realtime)
      let newBlockStallTimeoutRealtime = 5
      let sourceManager = SourceManager.make(
        ~isRealtime=false,
        ~sources=[syncMock.source, liveMock.source],
        ~newBlockStallTimeoutRealtime,
      )

      // Disable live via UnsupportedSelection (live is primary in live mode)
      let p1 =
        sourceManager->SourceManager.executeQuery(
          ~query=mockQuery(),
          ~isRealtime=true,
          ~knownHeight=100,
        )
      switch liveMock.getItemsOrThrowCalls {
      | [call] => call.reject(Source.GetItemsError(UnsupportedSelection({message: "test disable"})))
      | _ => JsError.throwWithMessage("Expected one pending call to liveMock")
      }
      await Utils.delay(0)
      switch syncMock.getItemsOrThrowCalls {
      | [call] => call.resolve([])
      | _ => JsError.throwWithMessage("Expected syncMock to get the query after live disabled")
      }
      let _ = await p1

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=true,
          ~knownHeight=100,
          ~reducedPolling=false,
        )

      t.expect(
        syncMock.getHeightOrThrowCalls->Array.length,
        ~message="Sync is polled as primary",
      ).toEqual(1)

      await Utils.delay(newBlockStallTimeoutRealtime + 2)
      t.expect(
        liveMock.getHeightOrThrowCalls->Array.length,
        ~message="Disabled live source should not be polled as a stall fallback",
      ).toEqual(0)

      syncMock.resolveGetHeightOrThrow(101)
      t.expect(await p).toEqual(101)
      t.expect(sourceManager->SourceManager.getActiveSource).toBe(syncMock.source)
    },
  )
})

describe("SourceManager height subscription", () => {
  Async.it(
    "Creates subscription when getHeightOrThrow returns same height as knownHeight",
    async t => {
      let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
      let sourceManager = SourceManager.make(~isRealtime=true, ~sources=[mock.source])

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=true,
          ~knownHeight=100,
          ~reducedPolling=false,
        )

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
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(~isRealtime=true, ~sources=[mock.source])

    // First call - create subscription
    let p1 =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Live)
    mock.triggerHeightSubscription(105)
    t.expect(await p1).toEqual(105)

    // Second call - should use cached height immediately without calling getHeightOrThrow
    let p2 =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    t.expect(
      mock.getHeightOrThrowCalls->Array.length,
      ~message="Should only have the poll covering the stream until it connected, and the catch-up on connect",
    ).toEqual(2)
    t.expect(await p2, ~message="Should immediately return cached height").toEqual(105)
  })

  Async.it(
    "Waits for next height event when subscription exists but height <= knownHeight",
    async t => {
      let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
      let sourceManager = SourceManager.make(~isRealtime=true, ~sources=[mock.source])

      // First call - create subscription and set initial height
      let p1 =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=true,
          ~knownHeight=100,
          ~reducedPolling=false,
        )
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      mock.setHeightSubscriptionStatus(Live)
      mock.triggerHeightSubscription(101)
      t.expect(await p1).toEqual(101)

      // Second call with higher knownHeight - should wait for next subscription event
      let p2 =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=true,
          ~knownHeight=101,
          ~reducedPolling=false,
        )
      t.expect(
        mock.getHeightOrThrowCalls->Array.length,
        ~message="Should only have the poll covering the stream until it connected, and the catch-up on connect",
      ).toEqual(2)

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
      let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval)
      let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[mock.source])

      let p =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=false,
          ~knownHeight=100,
          ~reducedPolling=false,
        )

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
    "Falls back to REST polling when a live subscription stays quiet for the stall timeout",
    async t => {
      let stallTimeout = 20
      let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
      let sourceManager = SourceManager.make(
        ~isRealtime=true,
        ~sources=[mock.source],
        ~newBlockStallTimeoutRealtime=stallTimeout,
      )

      // First call - create subscription
      let p1 =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=true,
          ~knownHeight=100,
          ~reducedPolling=false,
        )
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      mock.setHeightSubscriptionStatus(Live)
      mock.triggerHeightSubscription(101)
      t.expect(await p1).toEqual(101)

      // Second call - subscription exists but won't deliver
      let p2 =
        sourceManager->SourceManager.waitForNewBlock(
          ~isRealtime=true,
          ~knownHeight=101,
          ~reducedPolling=false,
        )

      // First stall is unjittered: the operator is promised a warning at
      // exactly newBlockStallTimeoutRealtime. Repeats after that are jittered.
      await Utils.delay(stallTimeout + 30)

      t.expect(
        mock.getHeightOrThrowCalls->Array.length,
        ~message="Should have called getHeightOrThrow as polling fallback",
      ).toBeGreaterThanOrEqual(2)

      // Resolve the REST polling with a new height
      mock.resolveGetHeightOrThrow(102)

      t.expect(await p2, ~message="Should resolve via REST polling fallback").toEqual(102)
    },
  )

  Async.it("Spreads the first stall poke below the window it warns at", async t => {
    Vi.useFakeTimers()
    let stallTimeout = 20_000
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~sourceFor=Realtime,
      ~pollingInterval=10_000,
    )
    let fallback = MockSource.make(
      [#getHeightOrThrow],
      ~sourceFor=Fallback,
      ~pollingInterval=10_000,
    )
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source, fallback.source],
      ~newBlockStallTimeoutRealtime=stallTimeout,
    )

    let first =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    mock.resolveGetHeightOrThrow(100)
    await Vi.advanceTimersByTimeAsync(0)
    mock.setHeightSubscriptionStatus(Live)
    mock.triggerHeightSubscription(101)
    let firstHeight = await first
    await Vi.advanceTimersByTimeAsync(0)
    // The fake clock is process-wide and the catch-up this connect fired is still
    // outstanding; what the wait below arms is armed after this point.
    Vi.clearAllTimers()

    let polls = () => mock.getHeightOrThrowCalls->Array.length
    let recruits = () => fallback.getHeightOrThrowCalls->Array.length
    let (pollsBefore, recruitsBefore) = (polls(), recruits())

    // A live stream that has delivered carries the wait on its own, so every poll
    // this source makes below is one the stall poke asked for.
    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )

    // Earliest instant the spread allows, minus one.
    await Vi.advanceTimersByTimeAsync(stallTimeout / 2 - 1)
    let pokedBeforeWindow = polls() > pollsBefore

    // Latest instant it allows, still short of the window itself.
    await Vi.advanceTimersByTimeAsync(stallTimeout / 2)
    let pokedWithinWindow = polls() > pollsBefore
    let recruitedWithinWindow = recruits() > recruitsBefore

    // The window: the warning, and the fallbacks it names, stay punctual.
    await Vi.advanceTimersByTimeAsync(1)
    let recruitedAtWindow = recruits() > recruitsBefore

    fallback.resolveGetHeightOrThrow(102)
    let height = await waiting
    Vi.useRealTimers()

    t.expect((
      firstHeight,
      pokedBeforeWindow,
      pokedWithinWindow,
      recruitedWithinWindow,
      recruitedAtWindow,
      height,
    )).toStrictEqual((101, false, true, false, true, 102))
  })

  Async.it("Stale SSE heights do not multiply concurrent /height polls (#1270)", async t => {
    let stallTimeout = 200
    let pollingInterval = 100
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription], ~pollingInterval)
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=stallTimeout,
    )

    // Call 1: create the subscription and advance the source to height 101 so the
    // next call starts caught-up (initialHeight == knownHeight == 101).
    let p1 =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Live)
    mock.triggerHeightSubscription(101)
    t.expect(await p1).toEqual(101)

    let pollsBefore = mock.getHeightOrThrowCalls->Array.length

    // Call 2: caught up at the head. The SSE stream now delivers a burst of STALE
    // heights (== knownHeight), exactly what a flapping/reconnecting height stream
    // re-emits on each reconnect.
    let p2 =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    await Utils.delay(0)

    let staleEvents = 20
    for _i in 1 to staleEvents {
      mock.triggerHeightSubscription(101)
      await Utils.delay(0)
    }

    // Wait past the jittered fallback trigger so the single fallback poll has run.
    await Utils.delay(stallTimeout + 40)

    let pollsAfterBurst = mock.getHeightOrThrowCalls->Array.length - pollsBefore

    // Before #1270 each stale (non-increasing) SSE height woke the wait loop and
    // spawned another uncancelled pollingFallback, so N stale events produced ~N
    // concurrent /height poll loops. onHeight now drops non-increasing heights, so
    // stale re-emits don't wake the loop and the poll count stays bounded.
    t.expect(
      pollsAfterBurst,
      ~message="stale SSE heights should not multiply concurrent /height polls",
    ).toBeLessThanOrEqual(1)

    // Cleanup: release everything so the test ends without dangling timers.
    mock.resolveGetHeightOrThrow(999)
    mock.triggerHeightSubscription(999)
    let _ = await p2
  })

  Async.it("Polls a source whose subscription was closed by disabling it", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #getItemsOrThrow, #createHeightSubscription])
    let fallbackMock = MockSource.make([#getItemsOrThrow], ~sourceFor=Fallback)
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source, fallbackMock.source],
    )

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)
    // The catch-up the connect fired, answered at the height we already know so
    // the wait stays in flight.
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    let pollsBeforeDisable = mock.getHeightOrThrowCalls->Array.length

    // An unrecoverable selection error is what benches a source for good.
    let query = sourceManager->SourceManager.executeQuery(
      ~query={
        partitionId: "0",
        itemsTarget: Some(5000),
        itemsEst: 5000,
        fromBlock: 0,
        toBlock: None,
        isChunk: false,
        selection: {dependsOnAddresses: false, onEventRegistrations: []},
        addresses: TestAddresses.setOf([]),
      },
      ~isRealtime=true,
      ~knownHeight=100,
    )
    switch mock.getItemsOrThrowCalls {
    | [call] => call.reject(Source.GetItemsError(UnsupportedSelection({message: "test disable"})))
    | _ => JsError.throwWithMessage("Expected one pending call to the primary source")
    }
    await Utils.delay(0)
    switch fallbackMock.getItemsOrThrowCalls {
    | [call] => call.resolve([])
    | _ => JsError.throwWithMessage("Expected the fallback to take the query over")
    }
    let _ = await query
    await Utils.delay(0)

    // The wait was in flight when the source was benched. Left looking live it
    // would sit on the staleness backstop against a socket that is closed and
    // will never push again.
    t.expect((
      mock.heightSubscriptionCloseCalls->Array.length,
      mock.getHeightOrThrowCalls->Array.length > pollsBeforeDisable,
      sourceManager->SourceManager.getHeightStreamSamples,
    )).toEqual((
      1,
      true,
      // The connection was delivering until it was closed, so it has to be
      // counted as lost like any other — otherwise the source reads as one
      // still pushing heights for the rest of the process.
      [
        {
          SourceManager.sourceName: "MockSource",
          chainId: 1->ChainId.fromInt,
          connectCount: 1,
          disconnects: [("unsubscribed", 1)],
        },
      ],
    ))

    mock.resolveGetHeightOrThrow(101)
    t.expect(await waiting).toBe(101)
  })

  // Brings a source to the point where its height subscription exists and is
  // live, which is where every fallback scenario below starts.
  let subscribeAndGoLive = async (mock: MockSource.t, sourceManager, ~knownHeight) => {
    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight,
        ~reducedPolling=false,
      )
    mock.resolveGetHeightOrThrow(knownHeight)
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Live)
    mock.triggerHeightSubscription(knownHeight + 1)
    let _ = await waiting
  }

  Async.it("Subscribes once when two waits are in flight for the same source", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(~isRealtime=true, ~sources=[mock.source])

    // What a rollback leaves behind: dispatch starts a wait for the new stateId
    // without cancelling the one it superseded, so both run the poll that
    // precedes subscribing and both come back to find no subscription.
    let superseded =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    let current =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )

    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    let subscriptions = mock.heightSubscriptionCalls->Array.length

    mock.triggerHeightSubscription(101)

    // A second subscription would overwrite the first one's close function,
    // leaving a connection nothing can ever close.
    t.expect((subscriptions, await superseded, await current)).toStrictEqual((1, 101, 101))
  })

  Async.it("Polls immediately when the subscription reports it went down", async t => {
    let stallTimeout = 2_000
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=stallTimeout,
    )
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)

    let pollsBefore = mock.getHeightOrThrowCalls->Array.length
    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    await Utils.delay(0)
    let pollsWhileLive = mock.getHeightOrThrowCalls->Array.length - pollsBefore

    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)
    let pollsAfterDown = mock.getHeightOrThrowCalls->Array.length - pollsBefore

    mock.resolveGetHeightOrThrow(102)

    // Nothing polled while the stream was live, and the poll landed well inside
    // the stall timeout the wait would otherwise have sat on.
    t.expect((pollsWhileLive, pollsAfterDown, await waiting)).toStrictEqual((0, 1, 102))
  })

  Async.it("Polls at the source's interval while the subscription has never connected", async t => {
    let pollingInterval = 10
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription], ~pollingInterval)
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=2_000,
    )

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    // Subscribing is the first thing the wait does, so the poll beside it is
    // covering a stream that has not reported itself live yet.
    let subscriptions = mock.heightSubscriptionCalls->Array.length
    let immediatePolls = mock.getHeightOrThrowCalls->Array.length

    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(pollingInterval + 5)
    let pollsAfterInterval = mock.getHeightOrThrowCalls->Array.length
    mock.resolveGetHeightOrThrow(101)

    t.expect((subscriptions, immediatePolls, pollsAfterInterval, await waiting)).toStrictEqual((
      1,
      1,
      2,
      101,
    ))
  })

  Async.it("Runs a single poll loop no matter how often the stream reports down", async t => {
    let pollingInterval = 10_000
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription], ~pollingInterval)
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=2_000,
    )
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)

    let pollsBefore = mock.getHeightOrThrowCalls->Array.length
    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    await Utils.delay(0)
    for _retry in 1 to 5 {
      mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
      await Utils.delay(0)
    }

    // The polling interval is far longer than the test, so a second loop would
    // show up as a second in-flight call rather than a sequential retry.
    let inFlightPolls = mock.getHeightOrThrowCalls->Array.length - pollsBefore
    mock.resolveGetHeightOrThrow(102)

    t.expect((inFlightPolls, await waiting)).toStrictEqual((1, 102))
  })

  Async.it("Stops the fallback poll loop once the subscription reconnects", async t => {
    let pollingInterval = 10
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription], ~pollingInterval)
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=20_000,
    )
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)

    // Keep answering at an unchanged height so a loop that has not stopped
    // issues a fresh call every polling interval instead of blocking on one.
    mock.resolveGetHeightOrThrow(101)
    await Utils.delay(pollingInterval * 3)
    let pollsAfterReconnect = mock.getHeightOrThrowCalls->Array.length
    for _round in 1 to 4 {
      mock.resolveGetHeightOrThrow(101)
      await Utils.delay(pollingInterval)
    }

    // The stream is delivering again, so the fallback must stop rather than
    // keep hammering an endpoint that was struggling a moment ago.
    let pollsLater = mock.getHeightOrThrowCalls->Array.length
    mock.triggerHeightSubscription(102)

    t.expect((pollsLater - pollsAfterReconnect, await waiting)).toStrictEqual((0, 102))
  })

  Async.it("Backs the fallback off when the source keeps failing", async t => {
    let pollingInterval = 10
    let retryInterval = 300
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription], ~pollingInterval)
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=5_000,
      ~getHeightRetryInterval=(~retry as _) => retryInterval,
    )
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)
    let pollsBefore = mock.getHeightOrThrowCalls->Array.length

    // The endpoint whose stream just dropped fails these too. Asking again every
    // polling interval would issue one per round here; the retry interval is far
    // longer than the whole window.
    for _round in 1 to 5 {
      mock.rejectGetHeightOrThrow("height unavailable")
      await Utils.delay(pollingInterval)
    }
    let pollsDuringBackoff = mock.getHeightOrThrowCalls->Array.length - pollsBefore

    mock.triggerHeightSubscription(102)

    t.expect((pollsDuringBackoff, await waiting)).toStrictEqual((0, 102))
  })

  Async.it("Polls once on reconnect to pick up a height missed while down", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=2_000,
    )
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    await Utils.delay(0)

    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)

    // The chain moved to 102 while the stream was down. A WebSocket newHeads
    // subscription would only deliver 103, so without the catch-up poll the
    // wait would hang until the chain produced another block.
    mock.resolveGetHeightOrThrow(102)

    t.expect(await waiting).toEqual(102)
  })

  Async.it("Catches up on the subscription's first connect too", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(~isRealtime=true, ~sources=[mock.source])

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    let pollsBeforeLive = mock.getHeightOrThrowCalls->Array.length
    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)
    let pollsAfterLive = mock.getHeightOrThrowCalls->Array.length
    mock.resolveGetHeightOrThrow(101)

    // A block mined between the poll that created the subscription and the
    // node accepting it would otherwise stay invisible until the next one.
    t.expect((pollsAfterLive - pollsBeforeLive, await waiting)).toStrictEqual((1, 101))
  })

  Async.it("Falls back at the interval the source would use, not always its own", async t => {
    let reducedPollingInterval = 20
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      // Far longer than the test, so a fallback using it would poll only once.
      ~pollingInterval=5_000,
    )
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~reducedPollingInterval,
      ~newBlockStallTimeoutRealtime=2_000,
    )
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)

    let pollsBefore = mock.getHeightOrThrowCalls->Array.length
    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=true,
      )
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)
    let pollsAfterDown = mock.getHeightOrThrowCalls->Array.length - pollsBefore

    mock.resolveGetHeightOrThrow(101)
    await Utils.delay(reducedPollingInterval * 3)
    let pollsAfterReducedInterval = mock.getHeightOrThrowCalls->Array.length - pollsBefore
    mock.resolveGetHeightOrThrow(102)

    t.expect((
      pollsAfterDown,
      pollsAfterReducedInterval > pollsAfterDown,
      await waiting,
    )).toStrictEqual((1, true, 102))
  })

  Async.it("Catches up on reconnect even with nobody waiting", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=2_000,
    )
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)

    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)
    mock.resolveGetHeightOrThrow(105)
    await Utils.delay(0)

    // The catch-up ran with no waiter to hand the height to, so the next wait
    // should already know about it.
    let pollsBefore = mock.getHeightOrThrowCalls->Array.length
    let height = await sourceManager->SourceManager.waitForNewBlock(
      ~isRealtime=true,
      ~knownHeight=101,
      ~reducedPolling=false,
    )

    t.expect((height, mock.getHeightOrThrowCalls->Array.length - pollsBefore)).toStrictEqual((
      105,
      0,
    ))
  })

  Async.it("Keeps waiting when the reconnect catch-up brings no new height", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=2_000,
    )
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)
    mock.resolveGetHeightOrThrow(101)

    let resolved = ref(false)
    let _ = waiting->Promise.thenResolve(_ => resolved := true)
    await Utils.delay(0)
    let stillWaiting = !resolved.contents
    mock.triggerHeightSubscription(102)

    t.expect((stillWaiting, await waiting)).toStrictEqual((true, 102))
  })

  Async.it("Keeps the fallback polling when the reconnect catch-up fails", async t => {
    let pollingInterval = 20
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription], ~pollingInterval)
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=5_000,
      // Retry at the polling cadence, so this stays about whether the loop is
      // still running rather than about how far it backs off.
      ~getHeightRetryInterval=(~retry as _) => pollingInterval,
    )
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)

    let pollsAtReconnect = mock.getHeightOrThrowCalls->Array.length

    // Fails the fallback poll in flight and the catch-up meant to replace it,
    // repeatedly, so a loop that is still running keeps issuing calls. Nothing
    // took the fallback's job over, so it has to carry on rather than leave the
    // chain with no height source until the backstop.
    for _round in 1 to 4 {
      mock.rejectGetHeightOrThrow("catch-up failed")
      await Utils.delay(pollingInterval)
    }
    let pollsKeptComing = mock.getHeightOrThrowCalls->Array.length > pollsAtReconnect

    mock.triggerHeightSubscription(102)

    t.expect((pollsKeptComing, await waiting)).toStrictEqual((true, 102))
  })

  Async.it("Takes a head the catch-up recorded while the race was settling", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=5_000,
    )
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=104,
        ~reducedPolling=false,
      )
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)

    // The catch-up's continuation is queued first, then the push drains the
    // waiters and queues the race continuation behind it. The catch-up's 105
    // therefore lands in knownHeight with nobody left to hand it to, while the
    // race settles on the push's 103 — which isn't enough to end this wait.
    mock.resolveGetHeightOrThrow(105)
    mock.triggerHeightSubscription(103)

    t.expect(await waiting).toEqual(105)
  })

  Async.it("Runs one poll loop when a push settles a wait without advancing it", async t => {
    let pollingInterval = 20
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription], ~pollingInterval)
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=5_000,
    )
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)

    // Waiting for a height well above the head, so a poll that finds a higher
    // one keeps the wait going instead of ending it.
    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=110,
        ~reducedPolling=false,
      )
    await Utils.delay(0)

    // A reconnect ends the fallback loop, so the wait takes the polled 105 even
    // though the stream itself is still only caught up to 101.
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)
    mock.resolveGetHeightOrThrow(105)
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Live)
    // Long enough for the retired poll loop to wake and hand back the 105 it
    // reached, which the wait takes even though the stream is still at 101.
    await Utils.delay(pollingInterval * 2)

    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)
    // A load-balanced backend can report a head behind the one a poll saw. It
    // settles this wait without moving it forward, which must still retire the
    // poll loop the wait started.
    mock.triggerHeightSubscription(103)
    await Utils.delay(0)

    let pollsBefore = mock.getHeightOrThrowCalls->Array.length
    mock.resolveGetHeightOrThrow(104)
    await Utils.delay(pollingInterval * 2)
    let pollsAdded = mock.getHeightOrThrowCalls->Array.length - pollsBefore
    mock.triggerHeightSubscription(111)

    t.expect((pollsAdded, await waiting)).toStrictEqual((1, 111))
  })

  Async.it("Leaves no stall timer behind when recruiting a fallback answers the wait", async t => {
    Vi.useFakeTimers()
    let stallTimeout = 100
    let sync = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let fallback = MockSource.make(
      [#getHeightOrThrow],
      ~sourceFor=Fallback,
      ~pollingInterval=10_000,
    )
    let sourceManager = SourceManager.make(
      ~isRealtime=false,
      ~sources=[sync.source, fallback.source],
      ~newBlockStallTimeout=stallTimeout,
    )

    let first =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=false,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    await Vi.advanceTimersByTimeAsync(stallTimeout)
    fallback.resolveGetHeightOrThrow(105)
    let firstHeight = await first

    // The fake clock is process-wide, and the poll loops other tests in this file
    // start outlive the waits that made them. Clearing here scopes the count
    // below to the wait under test: everything it goes on to arm is armed after
    // this point.
    Vi.clearAllTimers()

    // The fallback already knows a height past this one, so recruiting it
    // answers the wait inside the stall callback that recruited it. Anything the
    // callback goes on to do belongs to a wait that is over — and a timer armed
    // after the cleanup has run is one nothing can ever clear.
    let second =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=false,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    await Vi.advanceTimersByTimeAsync(stallTimeout)
    let secondHeight = await second

    // Let the poll sync still had out come back, so its loop retires rather than
    // sitting on the answer. What is pending after that is only what the wait
    // itself armed.
    sync.resolveGetHeightOrThrow(100)
    await Vi.advanceTimersByTimeAsync(0)
    let timersLeftBehind = Vi.getTimerCount()
    Vi.useRealTimers()

    t.expect((firstHeight, secondHeight, timersLeftBehind)).toStrictEqual((105, 105, 0))
  })

  Async.it("Keeps covering a stream that goes quiet again after the stall", async t => {
    // On the fake clock throughout: pokes are spread across the window below the
    // stall timeout, so on a real one whether a poke lands before or after a
    // snapshot is a coin flip. Every step below either advances no time at all —
    // where no poke can slip in — or a whole window, which always contains one.
    Vi.useFakeTimers()
    let stallTimeout = 100
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=stallTimeout,
    )

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    mock.setHeightSubscriptionStatus(Live)
    await Vi.advanceTimersByTimeAsync(0)
    mock.resolveGetHeightOrThrow(100)
    await Vi.advanceTimersByTimeAsync(0)
    let pollsWhileProven = mock.getHeightOrThrowCalls->Array.length

    await Vi.advanceTimersByTimeAsync(stallTimeout)
    let pollsAfterFirstStall = mock.getHeightOrThrowCalls->Array.length
    // Answered, so the poke is taken back and the stream is quiet and proven
    // again — the state the first stall started from.
    mock.resolveGetHeightOrThrow(100)
    await Vi.advanceTimersByTimeAsync(0)

    // A reconnect part way through the wait, whose catch-up succeeds: that takes
    // the stream at its word again, and it goes quiet in exactly the same way.
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    mock.setHeightSubscriptionStatus(Live)
    await Vi.advanceTimersByTimeAsync(0)
    mock.resolveGetHeightOrThrow(100)
    await Vi.advanceTimersByTimeAsync(0)
    let pollsAfterReconnect = mock.getHeightOrThrowCalls->Array.length

    await Vi.advanceTimersByTimeAsync(stallTimeout)
    let pollsAfterSecondStall = mock.getHeightOrThrowCalls->Array.length
    mock.triggerHeightSubscription(101)
    let height = await waiting
    Vi.useRealTimers()

    t.expect((
      pollsAfterFirstStall > pollsWhileProven,
      pollsAfterSecondStall > pollsAfterReconnect,
      height,
    )).toStrictEqual((true, true, 101))
  })

  Async.it("Polls a recruited fallback whose own stream has gone quiet", async t => {
    // Long enough that the re-armed stall timer cannot fire again while the
    // first wait is being driven to its answer.
    let stallTimeout = 200
    let sync = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let fallback = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~sourceFor=Fallback,
      ~pollingInterval=10_000,
    )
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[sync.source, fallback.source],
      ~newBlockStallTimeoutRealtime=stallTimeout,
    )

    // A first wait stalls, recruits the fallback, and its stream connects and
    // proves itself — which is what leaves it holding a live stream next time.
    let first =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    await Utils.delay(stallTimeout + 20)
    fallback.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)
    fallback.resolveGetHeightOrThrow(100)
    await Utils.delay(10)
    fallback.triggerHeightSubscription(101)
    t.expect(await first).toEqual(101)
    let pollsAfterFirst = fallback.getHeightOrThrowCalls->Array.length

    // The next wait stalls too, and recruits it again. Its stream still claims
    // to be live, and a whole window has passed with nothing heard from it —
    // exactly the claim a primary's stall stops taking at face value.
    let second =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    let pollsBeforeStall = fallback.getHeightOrThrowCalls->Array.length
    await Utils.delay(stallTimeout + 20)
    let pollsAfterStall = fallback.getHeightOrThrowCalls->Array.length
    fallback.resolveGetHeightOrThrow(102)

    t.expect((
      pollsBeforeStall === pollsAfterFirst,
      pollsAfterStall > pollsBeforeStall,
      await second,
    )).toStrictEqual((true, true, 102))
  })

  Async.it("Reports height stream connects and disconnects as metrics", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=2_000,
    )
    // Reported from the start: the source can subscribe, and a stream that has
    // not come up yet is exactly what zero connects says.
    let samplesBeforeSubscribing = sourceManager->SourceManager.getHeightStreamSamples
    await subscribeAndGoLive(mock, sourceManager, ~knownHeight=100)
    let samplesWhileHealthy = sourceManager->SourceManager.getHeightStreamSamples

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    await Utils.delay(0)
    // One outage per connection lost, whatever the stream does while it is down:
    // the 401 and the second `closed` are retries that failed, not connections
    // that dropped.
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    mock.setHeightSubscriptionStatus(Down({reason: "401"}))
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Down({reason: "rotated"}))
    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)
    mock.resolveGetHeightOrThrow(102)
    let _ = await waiting

    t.expect((
      samplesBeforeSubscribing,
      samplesWhileHealthy,
      sourceManager->SourceManager.getHeightStreamSamples,
    )).toStrictEqual((
      [
        {
          SourceManager.sourceName: "MockSource",
          chainId: 1->ChainId.fromInt,
          connectCount: 0,
          disconnects: [],
        },
      ],
      [
        {
          SourceManager.sourceName: "MockSource",
          chainId: 1->ChainId.fromInt,
          connectCount: 1,
          disconnects: [],
        },
      ],
      [
        {
          SourceManager.sourceName: "MockSource",
          chainId: 1->ChainId.fromInt,
          // Three connects against two disconnects: the stream is up, which is
          // what the pair says without a gauge to say it.
          connectCount: 3,
          disconnects: [("closed", 1), ("rotated", 1)],
        },
      ],
    ))
  })

  Async.it("Reports a stream that has never connected as zero connects", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[mock.source],
      ~newBlockStallTimeoutRealtime=2_000,
    )

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)

    // A ws url pointing at a node that will never accept the subscription. The
    // retries are attempts at a connection that never existed, so there is
    // nothing to have disconnected, and the connect count is the only thing
    // that says the stream is down.
    mock.setHeightSubscriptionStatus(Down({reason: "connect-failed"}))
    mock.setHeightSubscriptionStatus(Down({reason: "connect-failed"}))
    await Utils.delay(0)
    let samplesWhileDown = sourceManager->SourceManager.getHeightStreamSamples

    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)
    mock.resolveGetHeightOrThrow(101)
    let _ = await waiting

    t.expect((
      samplesWhileDown,
      sourceManager->SourceManager.getHeightStreamSamples,
    )).toStrictEqual((
      [
        {
          SourceManager.sourceName: "MockSource",
          chainId: 1->ChainId.fromInt,
          connectCount: 0,
          disconnects: [],
        },
      ],
      [
        {
          SourceManager.sourceName: "MockSource",
          chainId: 1->ChainId.fromInt,
          connectCount: 1,
          disconnects: [],
        },
      ],
    ))
  })

  Async.it("Stops polling a source once the wait has been decided elsewhere", async t => {
    let pollingInterval = 10
    let stallTimeout = 2_000
    let stuckMock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval,
    )
    let fastMock = MockSource.make([#getHeightOrThrow], ~chainId=1, ~pollingInterval)
    let sourceManager = SourceManager.make(
      ~isRealtime=true,
      ~sources=[stuckMock.source, fastMock.source],
      ~newBlockStallTimeoutRealtime=stallTimeout,
    )
    await subscribeAndGoLive(stuckMock, sourceManager, ~knownHeight=100)

    let waiting =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=101,
        ~reducedPolling=false,
      )
    await Utils.delay(0)
    stuckMock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)

    // The other source decides the wait while the stuck one is mid-poll.
    fastMock.resolveGetHeightOrThrow(102)
    let _ = await waiting

    stuckMock.resolveGetHeightOrThrow(101)
    await Utils.delay(pollingInterval * 4)
    let pollsAfterResolution = stuckMock.getHeightOrThrowCalls->Array.length
    await Utils.delay(pollingInterval * 4)

    t.expect(
      stuckMock.getHeightOrThrowCalls->Array.length,
      ~message="the orphaned poll loop should have stopped, not kept polling forever",
    ).toEqual(pollsAfterResolution)
  })

  Async.it("Ignores subscription heights lower than or equal to knownHeight", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription])
    let sourceManager = SourceManager.make(~isRealtime=true, ~sources=[mock.source])

    // First call - create subscription
    let p1 =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=100,
        ~reducedPolling=false,
      )
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    mock.setHeightSubscriptionStatus(Live)
    mock.triggerHeightSubscription(101)
    t.expect(await p1).toEqual(101)

    // Second call with higher knownHeight
    let p2 =
      sourceManager->SourceManager.waitForNewBlock(
        ~isRealtime=true,
        ~knownHeight=105,
        ~reducedPolling=false,
      )

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
