open Vitest

let normalSelection = FetchState.makeSelection(~dependsOnAddresses=false, ~onEventRegistrations=[])

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
    normalSelection,
    latestOnBlockBlockNumber: latestFullyFetchedBlock.contents,
    maxOnBlockBufferSize: targetBufferSize,
    chainId: 0->ChainId.fromInt,
    blockLag: 0,
    blockThrottle: 0,
    onBlockRegistrations: [],
    knownHeight,
    firstEventBlock: None,
    clientFilterPolicy: {addressThreshold: None, allDynamicContracts: false},
    largestPageItems: FetchState.initialPageItems,
  }->TestFetchState.pair(~eventStore=EventStore.make())
}

let nextQuery = (fetchState: FetchState.t) =>
  fetchState->FetchState.getNextQuery(
    ~chainTargetBlock=fetchState.knownHeight,
    ~chainTargetItems=50_000.,
  )

let partitionIds = (nextQuery: FetchState.nextQuery) =>
  switch nextQuery {
  | Ready(queries) => queries->Array.map(q => q.partitionId)
  | _ => []
  }

describe("FetchState.getNextQuery partition scheduling", () => {
  it("caps a partition at 12 in-flight chunks", t => {
    let pendingChunk = (idx): FetchState.pendingQuery => {
      fromBlock: idx * 10 + 1,
      toBlock: Some(idx * 10 + 10),
      isChunk: true,
      itemsEst: 5000,
      fetchedBlock: None,
    }
    // A known density and range capacity make the tail want more chunks than
    // the cap leaves room for, so every count below is the cap trimming it.
    let withPending = count => {
      let p = {
        ...mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=0),
        mutPendingQueries: Array.fromInitializer(~length=count, pendingChunk),
        sourceRangeCapacity: 10,
        eventDensity: Some(1.),
        prevSourceRangeCapacity: 10,
      }
      mockFetchState([p], ~knownHeight=1000)
    }
    let newQueryCount = nextQuery =>
      switch nextQuery {
      | FetchState.Ready(queries) => queries->Array.length
      | _ => 0
      }

    let count = pending =>
      withPending(pending)
      ->FetchState.getNextQuery(~chainTargetBlock=1000, ~chainTargetItems=1_000_000.)
      ->newQueryCount
    t.expect([count(8), count(9), count(10), count(11), count(12)]).toEqual([4, 3, 2, 1, 0])
  })

  it("queries every partition behind the head, furthest behind first", t => {
    // A known density, so each probe is sized by its range to the target.
    let probing = (~partitionIndex, ~latestFetchedBlockNumber) => {
      ...mockFullPartition(~partitionIndex, ~latestFetchedBlockNumber),
      eventDensity: Some(0.),
    }
    let partition0 = probing(~partitionIndex=0, ~latestFetchedBlockNumber=4)
    let partition1 = probing(~partitionIndex=1, ~latestFetchedBlockNumber=5)
    let partition2 = probing(~partitionIndex=2, ~latestFetchedBlockNumber=1)

    t.expect(
      mockFetchState([partition0, partition1, partition2], ~knownHeight=10)->nextQuery,
    ).toEqual(
      Ready([
        {
          partitionId: "2",
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
          itemsEst: 9_259,
          fromBlock: 6,
          toBlock: None,
          isChunk: false,
          selection: normalSelection,
          addresses: partition1.addresses,
        },
      ]),
    )
  })

  it("skips partitions already at the chain's last block", t => {
    let p0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4)
    let p1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)
    let p2 = mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=1)
    let p3 = mockFullPartition(~partitionIndex=3, ~latestFetchedBlockNumber=4)

    t.expect(
      mockFetchState([p0, p1, p2, p3], ~endBlock=Some(5), ~knownHeight=4)
      ->nextQuery
      ->partitionIds,
    ).toEqual(["2"])
  })

  it("skips partitions at the end block and at the head", t => {
    t.expect(
      mockFetchState(
        [
          mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=11),
          mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=10),
          mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=6),
          mockFullPartition(~partitionIndex=3, ~latestFetchedBlockNumber=4),
        ],
        ~endBlock=Some(11),
        ~knownHeight=10,
      )
      ->nextQuery
      ->partitionIds,
    ).toEqual(["3", "2"])
  })

  it("waits for a new block when no height is known, even with every partition done", t => {
    t.expect(
      mockFetchState(
        [mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=5)],
        ~endBlock=Some(5),
        ~knownHeight=0,
      )->nextQuery,
    ).toEqual(WaitingForNewBlock)
  })

  // A probe sends no row limit, so a partition whose density is unknown may
  // answer with a full page however small its share of the budget: each one
  // reserves a page, and the budget admits as many as it holds pages.
  it("admits as many cold probes as the budget holds pages", t => {
    let itemsEstimates = nextQuery =>
      switch nextQuery {
      | FetchState.Ready(queries) => queries->Array.map(q => q.itemsEst)
      | _ => []
      }
    t.expect(
      mockFetchState(
        Array.fromInitializer(
          ~length=10,
          partitionIndex => mockFullPartition(~partitionIndex, ~latestFetchedBlockNumber=0),
        ),
        ~knownHeight=1000,
      )
      ->FetchState.getNextQuery(~chainTargetBlock=1000, ~chainTargetItems=20_000.)
      ->itemsEstimates,
    ).toEqual([5000, 5000, 5000, 5000])
  })

  // A page is the most items one response on the chain has carried, so once a
  // response outgrows the seed, cold probes reserve that much instead.
  it("reserves the largest response seen as the page for later cold probes", t => {
    let fetchState = mockFetchState(
      [
        mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=0),
        mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=0),
      ],
      ~knownHeight=1000,
    )
    let firstQuery = switch fetchState->FetchState.getNextQuery(
      ~chainTargetBlock=1000,
      ~chainTargetItems=5000.,
    ) {
    | Ready([query]) => query
    | _ => JsError.throwWithMessage("expected one probe within a one-page budget")
    }
    fetchState->FetchState.startFetchingQueries(~queries=[firstQuery])
    let largestPageItems = FetchState.initialPageItems + 1000
    let afterLargePage = fetchState->TestFetchState.handleQueryResult(
      ~query=firstQuery,
      ~latestFetchedBlock=10,
      ~page=TestEventStore.pageOf(
        Array.fromInitializer(
          ~length=largestPageItems,
          logIndex => Internal.Event({
            chainId: 0->ChainId.fromInt,
            blockNumber: 5,
            onEventRegistration: {"index": 0}->(
              Utils.magic: {"index": int} => Internal.onEventRegistration
            ),
            logIndex,
            transactionIndex: 0,
            payload: "Mock event"->(Utils.magic: string => Internal.eventPayload),
          }),
        ),
      ),
    )
    let coldProbes = switch afterLargePage->FetchState.getNextQuery(
      ~chainTargetBlock=1000,
      ~chainTargetItems=100_000.,
    ) {
    | Ready(queries) =>
      queries
      ->Array.filter(q => q.partitionId === "1")
      ->Array.map(q => q.itemsEst)
    | _ => []
    }
    t.expect(coldProbes).toEqual([largestPageItems])
  })

  it("waits for a new block when every partition is at the known height", t => {
    t.expect(
      mockFetchState(
        [
          mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=5),
          mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5),
        ],
        ~knownHeight=5,
      )->nextQuery,
    ).toEqual(WaitingForNewBlock)
  })
})
