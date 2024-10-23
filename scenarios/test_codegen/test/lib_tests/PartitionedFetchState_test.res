open Belt
open RescriptMocha

describe("PartitionedFetchState getMostBehindPartitions", () => {
  let mockFetchState = (~latestFetchedBlockNumber, ~fetchedEventQueue=[]): FetchState.t => {
    baseRegister: {
      registerType: RootRegister({endBlock: None}),
      latestFetchedBlock: {
        blockNumber: latestFetchedBlockNumber,
        blockTimestamp: latestFetchedBlockNumber * 15,
      },
      contractAddressMapping: ContractAddressingMap.make(),
      fetchedEventQueue,
      dynamicContracts: FetchState.DynamicContractsMap.empty,
      firstEventBlockNumber: None,
    },
    isFetchingAtHead: false,
    pendingDynamicContracts: [],
  }

  let mockPartitionedFetchState = (~partitions: list<_>): PartitionedFetchState.t => {
    let partitions = partitions->List.mapWithIndex((i, p) => (i->Int.toString, p))->Js.Dict.fromList
    let newestPartitionIndex =
      partitions->Js.Dict.keys->Array.keepMap(Int.fromString)->Js.Math.maxMany_int
    {
      newestPartitionIndex,
      partitions,
      maxAddrInPartition: 0,
      startBlock: 0,
      endBlock: None,
      logger: Logging.logger,
    }
  }
  let partitions = list{
    mockFetchState(~latestFetchedBlockNumber=4),
    mockFetchState(~latestFetchedBlockNumber=5),
    mockFetchState(~latestFetchedBlockNumber=1),
    mockFetchState(~latestFetchedBlockNumber=2),
    mockFetchState(~latestFetchedBlockNumber=3),
  }
  let partitionedFetchState = mockPartitionedFetchState(~partitions)
  it(
    "With multiple partitions always returns the most behind partitions up to the max concurrency level",
    () => {
      let maxNumQueries = 3
      let partitionsCurrentlyFetching = Set.Int.empty

      let mostBehindPartitions =
        partitionedFetchState->PartitionedFetchState.getMostBehindPartitions(
          ~maxNumQueries,
          ~maxPerChainQueueSize=10,
          ~partitionsCurrentlyFetching,
        )

      Assert.equal(mostBehindPartitions->Array.length, maxNumQueries)

      let partitionIds = mostBehindPartitions->Array.map(p => p.partitionId)
      Assert.deepEqual(
        partitionIds,
        [2, 3, 4],
        ~message="Should have returned the partitions with the lowest latestFetchedBlock",
      )
    },
  )

  it("Will not return partitions that are currently fetching", () => {
    let maxNumQueries = 3
    let partitionsCurrentlyFetching = Set.Int.fromArray([2, 3])

    let mostBehindPartitions =
      partitionedFetchState->PartitionedFetchState.getMostBehindPartitions(
        ~maxNumQueries,
        ~maxPerChainQueueSize=10,
        ~partitionsCurrentlyFetching,
      )

    Assert.equal(
      mostBehindPartitions->Array.length,
      maxNumQueries - partitionsCurrentlyFetching->Set.Int.size,
    )

    let partitionIds = mostBehindPartitions->Array.map(p => p.partitionId)
    Assert.deepEqual(
      partitionIds,
      [4],
      ~message="Should have returned the partitions with the lowest latestFetchedBlock that are not currently fetching",
    )
  })

  it("Should not return partition that is at max partition size", () => {
    let maxNumQueries = 3
    let partitions = list{
      mockFetchState(~latestFetchedBlockNumber=4),
      mockFetchState(~latestFetchedBlockNumber=5),
      mockFetchState(
        ~latestFetchedBlockNumber=1,
        ~fetchedEventQueue=["mockEvent1", "mockEvent2", "mockEvent3"]->Utils.magic,
      ),
      mockFetchState(
        ~latestFetchedBlockNumber=2,
        ~fetchedEventQueue=["mockEvent4", "mockEvent5"]->Utils.magic,
      ),
      mockFetchState(~latestFetchedBlockNumber=3),
    }
    let partitionedFetchState = mockPartitionedFetchState(~partitions)

    let mostBehindPartitions =
      partitionedFetchState->PartitionedFetchState.getMostBehindPartitions(
        ~maxNumQueries,
        ~maxPerChainQueueSize=10, //each partition should therefore have a max of 2 events
        ~partitionsCurrentlyFetching=Set.Int.empty,
      )

    let partitionIds = mostBehindPartitions->Array.map(p => p.partitionId)
    Assert.deepEqual(
      partitionIds,
      [4, 0, 1],
      ~message="Should have skipped partitions that are at max queue size",
    )
  })

  it("if need be should return less than maxNum queries if all partitions at their max", () => {
    let maxNumQueries = 3
    let partitions = list{
      mockFetchState(~latestFetchedBlockNumber=4),
      mockFetchState(~latestFetchedBlockNumber=5),
      mockFetchState(
        ~latestFetchedBlockNumber=1,
        ~fetchedEventQueue=["mockEvent1", "mockEvent2", "mockEvent3"]->Utils.magic,
      ),
      mockFetchState(
        ~latestFetchedBlockNumber=2,
        ~fetchedEventQueue=["mockEvent4", "mockEvent5"]->Utils.magic,
      ),
      mockFetchState(
        ~latestFetchedBlockNumber=3,
        ~fetchedEventQueue=["mockEvent6", "mockEvent7"]->Utils.magic,
      ),
    }
    let partitionedFetchState = mockPartitionedFetchState(~partitions)

    let mostBehindPartitions =
      partitionedFetchState->PartitionedFetchState.getMostBehindPartitions(
        ~maxNumQueries,
        ~maxPerChainQueueSize=10, //each partition should therefore have a max of 2 events
        ~partitionsCurrentlyFetching=Set.Int.empty,
      )

    let partitionIds = mostBehindPartitions->Array.map(p => p.partitionId)
    Assert.deepEqual(
      partitionIds,
      [0, 1],
      ~message="Should have skipped partitions that are at max queue size and returned less than maxNumQueries",
    )
  })
})
