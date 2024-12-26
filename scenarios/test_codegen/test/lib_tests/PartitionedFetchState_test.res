open Belt
open RescriptMocha

describe("PartitionedFetchState getMostBehindPartitions", () => {
  let mockPartitionedFetchState = (~partitions, ~maxAddrInPartition=1): PartitionedFetchState.t => {
    {
      partitions,
      maxAddrInPartition,
      startBlock: 0,
      endBlock: None,
      logger: Logging.logger,
    }
  }

  it("Partition id never changes when adding new partitions", () => {
    let rootContractAddressMapping = ContractAddressingMap.make()

    for i in 0 to 3 {
      let address = TestHelpers.Addresses.mockAddresses[i]->Option.getExn
      rootContractAddressMapping->ContractAddressingMap.addAddress(~address, ~name="MockContract")
    }

    let rootRegister: FetchState.register = {
      id: FetchState.rootRegisterId,
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

    let dcRegister: FetchState.register = {
      id: FetchState.makeDynamicContractRegisterId(dynamicContractId),
      latestFetchedBlock: {
        blockNumber: dynamicContractId.blockNumber,
        blockTimestamp: dynamicContractId.blockNumber * 15,
      },
      contractAddressMapping: ContractAddressingMap.make(),
      fetchedEventQueue: [],
      dynamicContracts: FetchState.DynamicContractsMap.empty,
      firstEventBlockNumber: None,
    }

    let fetchState0: FetchState.t = {
      partitionId: 0,
      responseCount: 0,
      registers: [rootRegister, dcRegister],
      mostBehindRegister: rootRegister,
      nextMostBehindRegister: Some(dcRegister),
      isFetchingAtHead: false,
      pendingDynamicContracts: [],
    }

    let maxAddrInPartition = 4

    let partitionedFetchState = mockPartitionedFetchState(
      ~partitions=[fetchState0],
      ~maxAddrInPartition,
    )
    let id = {
      PartitionedFetchState.partitionId: 0,
      fetchStateId: dcRegister.id,
    }

    //Check the expected query if requsted in this state
    Assert.deepEqual(
      partitionedFetchState.partitions->PartitionedFetchState.getReadyPartitions(
        ~maxPerChainQueueSize=10,
        ~fetchingPartitions=Utils.Set.make(),
      ),
      [fetchState0],
      ~message="Should have only one partition with id 0",
    )

    let chain = ChainMap.Chain.makeUnsafe(~chainId=1)
    let updatedPartitionedFetchState =
      partitionedFetchState->PartitionedFetchState.registerDynamicContracts(
        {
          registeringEventChain: chain,
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

    let newRootRegister: FetchState.register = {
      id: FetchState.rootRegisterId,
      latestFetchedBlock: {blockNumber: 9, blockTimestamp: 0},
      contractAddressMapping: ContractAddressingMap.fromArray([
        (TestHelpers.Addresses.mockAddresses[5]->Option.getExn, "Gravatar"),
      ]),
      fetchedEventQueue: [],
      dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.addAddress(
        {
          blockNumber: 10,
          logIndex: 0,
        },
        TestHelpers.Addresses.mockAddresses[5]->Option.getExn,
      ),
      firstEventBlockNumber: None,
    }

    Assert.deepEqual(
      updatedPartitionedFetchState.partitions->PartitionedFetchState.getReadyPartitions(
        ~maxPerChainQueueSize=1000,
        ~fetchingPartitions=Utils.Set.make(),
      ),
      [
        fetchState0,
        {
          partitionId: 1,
          responseCount: 0,
          registers: [newRootRegister],
          mostBehindRegister: newRootRegister,
          nextMostBehindRegister: None,
          pendingDynamicContracts: [],
          isFetchingAtHead: false,
        },
      ],
      ~message="Should have a new partition with id 1",
    )

    //Check that the original partition is available at it's id
    //and the new partition has not overwritten it
    switch updatedPartitionedFetchState->PartitionedFetchState.update(
      ~id,
      ~currentBlockHeight=200,
      ~latestFetchedBlock={blockNumber: 20, blockTimestamp: 20 * 15},
      ~newItems=[],
      ~chain,
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
