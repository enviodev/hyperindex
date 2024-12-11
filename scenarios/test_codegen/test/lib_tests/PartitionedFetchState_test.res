open Belt
open RescriptMocha

describe("PartitionedFetchState getMostBehindPartitions", () => {
  let mockFetchState = (
    ~latestFetchedBlockNumber,
    ~fetchedEventQueue=[],
    ~numContracts=1,
  ): FetchState.t => {
    let contractAddressMapping = ContractAddressingMap.make()

    for i in 0 to numContracts - 1 {
      let address = TestHelpers.Addresses.mockAddresses[i]->Option.getExn
      contractAddressMapping->ContractAddressingMap.addAddress(~address, ~name="MockContract")
    }

    {
      baseRegister: {
        registerType: RootRegister({endBlock: None}),
        latestFetchedBlock: {
          blockNumber: latestFetchedBlockNumber,
          blockTimestamp: latestFetchedBlockNumber * 15,
        },
        contractAddressMapping,
        fetchedEventQueue,
        dynamicContracts: FetchState.DynamicContractsMap.empty,
        firstEventBlockNumber: None,
      },
      isFetchingAtHead: false,
      pendingDynamicContracts: [],
    }
  }

  let mockPartitionedFetchState = (
    ~partitions: list<_>,
    ~maxAddrInPartition=1,
  ): PartitionedFetchState.t => {
    let partitions = partitions->List.toArray
    {
      partitions,
      maxAddrInPartition,
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
  it("With multiple partitions always returns the most behind partitions first", () => {
    let partitionsCurrentlyFetching = Set.Int.empty

    let mostBehindPartitions =
      partitionedFetchState->PartitionedFetchState.getMostBehindPartitions(
        ~maxPerChainQueueSize=10,
        ~partitionsCurrentlyFetching,
      )

    let partitionIds = mostBehindPartitions->Array.map(p => p.partitionId)
    Assert.deepEqual(
      partitionIds,
      [2, 3, 4, 0, 1],
      ~message="Should have returned the partitions with the lowest latestFetchedBlock first",
    )
  })

  it("Will not return partitions that are currently fetching", () => {
    let partitionsCurrentlyFetching = Set.Int.fromArray([2, 3])

    let mostBehindPartitions =
      partitionedFetchState->PartitionedFetchState.getMostBehindPartitions(
        ~maxPerChainQueueSize=10,
        ~partitionsCurrentlyFetching,
      )

    Assert.equal(
      mostBehindPartitions->Array.length,
      partitionedFetchState.partitions->Js.Array2.length -
        partitionsCurrentlyFetching->Set.Int.size,
    )

    let partitionIds = mostBehindPartitions->Array.map(p => p.partitionId)
    Assert.deepEqual(
      partitionIds,
      [4, 0, 1],
      ~message="Should have returned the partitions with the lowest latestFetchedBlock that are not currently fetching",
    )
  })

  it("Should not return partition that is at max queue size", () => {
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

  it("Partition id never changes when adding new partitions", () => {
    let rootContractAddressMapping = ContractAddressingMap.make()

    for i in 0 to 3 {
      let address = TestHelpers.Addresses.mockAddresses[i]->Option.getExn
      rootContractAddressMapping->ContractAddressingMap.addAddress(~address, ~name="MockContract")
    }

    let rootRegister: FetchState.register = {
      registerType: RootRegister({endBlock: None}),
      latestFetchedBlock: {
        blockNumber: 100,
        blockTimestamp: 100 * 15,
      },
      contractAddressMapping: rootContractAddressMapping,
      fetchedEventQueue: [],
      dynamicContracts: FetchState.DynamicContractsMap.empty,
      firstEventBlockNumber: None,
    }

    let dynamicContractId: FetchState.dynamicContractId = {
      blockNumber: 10,
      logIndex: 0,
    }

    let baseRegister: FetchState.register = {
      registerType: DynamicContractRegister({
        id: dynamicContractId,
        nextRegister: rootRegister,
      }),
      latestFetchedBlock: {
        blockNumber: dynamicContractId.blockNumber,
        blockTimestamp: dynamicContractId.blockNumber * 15,
      },
      contractAddressMapping: ContractAddressingMap.make(),
      fetchedEventQueue: [],
      dynamicContracts: FetchState.DynamicContractsMap.empty,
      firstEventBlockNumber: None,
    }

    let partition0: FetchState.t = {
      baseRegister,
      isFetchingAtHead: false,
      pendingDynamicContracts: [],
    }

    let maxAddrInPartition = 4
    let partitions = list{partition0}

    let partitionedFetchState = mockPartitionedFetchState(~partitions, ~maxAddrInPartition)
    let id = {
      PartitionedFetchState.partitionId: 0,
      fetchStateId: DynamicContract(dynamicContractId),
    }

    //Check the expected query if requsted in this state
    switch partitionedFetchState->PartitionedFetchState.getNextQueries(
      ~maxPerChainQueueSize=10,
      ~partitionsCurrentlyFetching=Set.Int.empty,
    ) {
    | ([query], _) =>
      Assert.deepEqual(
        query.fetchStateRegisterId,
        id.fetchStateId,
        ~message="Should have returned dynamic contract query",
      )
      Assert.equal(query.partitionId, id.partitionId, ~message="Should use first partition")
    | _ => Assert.fail("Expected a single query from partitioned fetch state")
    }

    Assert.equal(
      partitionedFetchState.partitions->Array.length,
      1,
      ~message="Should have only one partition",
    )

    let updatedPartitionedFetchState =
      partitionedFetchState->PartitionedFetchState.registerDynamicContracts(
        {
          registeringEventChain: ChainMap.Chain.makeUnsafe(~chainId=1),
          registeringEventBlockNumber: 10,
          registeringEventLogIndex: 0,
          dynamicContracts: [
            {
              id: ContextEnv.makeDynamicContractId(
                ~chainId=1,
                ~contractAddress=TestHelpers.Addresses.mockAddresses[5]->Option.getExn,
              ),
              chainId: 1,
              registeringEventBlockTimestamp: 10 * 15,
              registeringEventBlockNumber: 10,
              registeringEventLogIndex: 0,
              registeringEventContractName: "MockFactory",
              registeringEventName: "MockCreateGravatar",
              registeringEventSrcAddress: TestHelpers.Addresses.mockAddresses[0]->Option.getExn,
              contractAddress: TestHelpers.Addresses.mockAddresses[5]->Option.getExn,
              contractType: Enums.ContractType.Gravatar,
            },
          ],
        },
        ~isFetchingAtHead=false,
      )

    Assert.equal(
      updatedPartitionedFetchState.partitions->Array.length,
      2,
      ~message="Should have added a new partition since it's over the maxAddrInPartition threshold",
    )

    //Check that the original partition is available at it's id
    //and the new partition has not overwritten it
    switch updatedPartitionedFetchState->PartitionedFetchState.update(
      ~id,
      ~currentBlockHeight=200,
      ~latestFetchedBlock={blockNumber: 20, blockTimestamp: 20 * 15},
      ~newItems=[],
    ) {
    | Ok(_) => ()
    | Error(PartitionedFetchState.UnexpectedPartitionDoesNotExist(_)) =>
      Assert.fail("Partition should exist")
    | Error(FetchState.UnexpectedRegisterDoesNotExist(_)) =>
      Assert.fail("Dynamic contract register should exist")
    | _ => Assert.fail("Unexpected error")
    }
  })
})
