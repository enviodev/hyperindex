open Vitest

let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}

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
    buffer: [],
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
  it("caps a partition at 10 pending chunks", t => {
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

  it("queries every partition behind the head, furthest behind first", t => {
    let partition0 = mockFullPartition(~partitionIndex=0, ~latestFetchedBlockNumber=4)
    let partition1 = mockFullPartition(~partitionIndex=1, ~latestFetchedBlockNumber=5)
    let partition2 = mockFullPartition(~partitionIndex=2, ~latestFetchedBlockNumber=1)

    t.expect(
      mockFetchState([partition0, partition1, partition2], ~knownHeight=10)->nextQuery,
    ).toEqual(
      Ready([
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
