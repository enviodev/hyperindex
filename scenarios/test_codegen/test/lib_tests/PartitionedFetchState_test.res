open Belt
open RescriptMocha

describe("PartitionedFetchState", () => {
  let mockPartitionedFetchState = (~partitions, ~maxAddrInPartition=1): PartitionedFetchState.t => {
    {
      partitions,
      maxAddrInPartition,
      startBlock: 0,
      endBlock: None,
      logger: Logging.logger,
    }
  }

  it("Create PartitionedFetchState without predefined contracts", () => {
    let partitionedFetchState = PartitionedFetchState.make(
      ~maxAddrInPartition=2,
      ~dynamicContractRegistrations=[],
      ~startBlock=0,
      ~endBlock=None,
      ~staticContracts=[],
      ~hasWildcard=false,
      ~logger=Logging.logger,
    )

    Assert.deepEqual(
      partitionedFetchState,
      {
        partitions: [
          FetchState.make(
            ~partitionId=0,
            ~staticContracts=[],
            ~dynamicContractRegistrations=[],
            ~isFetchingAtHead=false,
            ~kind=Normal,
            ~logger=Logging.logger,
            ~startBlock=0,
          ),
        ],
        maxAddrInPartition: 2,
        startBlock: 0,
        endBlock: None,
        logger: Logging.logger,
      },
      ~message="Eventhough there are no predefined contract, must create a partition",
    )
  })

  it("Create PartitionedFetchState without predefined contracts and wildcard events", () => {
    let partitionedFetchState = PartitionedFetchState.make(
      ~maxAddrInPartition=2,
      ~dynamicContractRegistrations=[],
      ~startBlock=0,
      ~endBlock=None,
      ~staticContracts=[],
      ~hasWildcard=true,
      ~logger=Logging.logger,
    )

    // FIXME: Test next query
    Assert.deepEqual(
      partitionedFetchState,
      {
        partitions: [
          FetchState.make(
            ~partitionId=0,
            ~staticContracts=[],
            ~dynamicContractRegistrations=[],
            ~isFetchingAtHead=false,
            ~kind=Wildcard,
            ~logger=Logging.logger,
            ~startBlock=0,
          ),
          FetchState.make(
            ~partitionId=1,
            ~staticContracts=[],
            ~dynamicContractRegistrations=[],
            ~isFetchingAtHead=false,
            ~kind=Normal,
            ~logger=Logging.logger,
            ~startBlock=0,
          ),
        ],
        maxAddrInPartition: 2,
        startBlock: 0,
        endBlock: None,
        logger: Logging.logger,
      },
      ~message="Should still create a normal partition in case we are going to add dynamic contracts",
    )
  })

  it("Create PartitionedFetchState with multiple partitions", () => {
    let contractRegistration1: TablesStatic.DynamicContractRegistry.t = {
      id: "dcr1",
      chainId: 137,
      registeringEventBlockNumber: 10,
      registeringEventBlockTimestamp: 10 * 15,
      registeringEventLogIndex: 0,
      registeringEventContractName: "MockFactory",
      registeringEventName: "MockCreateGravatar",
      registeringEventSrcAddress: TestHelpers.Addresses.mockAddresses[0]->Option.getExn,
      contractAddress: TestHelpers.Addresses.mockAddresses[5]->Option.getExn,
      contractType: Enums.ContractType.Gravatar,
    }
    let contractRegistration2: TablesStatic.DynamicContractRegistry.t = {
      id: "dcr2",
      chainId: 137,
      registeringEventBlockNumber: 10,
      registeringEventBlockTimestamp: 10 * 15,
      registeringEventLogIndex: 0,
      registeringEventContractName: "MockFactory",
      registeringEventName: "MockCreateGravatar",
      registeringEventSrcAddress: TestHelpers.Addresses.mockAddresses[0]->Option.getExn,
      contractAddress: TestHelpers.Addresses.mockAddresses[5]->Option.getExn,
      contractType: Enums.ContractType.NftFactory,
    }

    let partitionedFetchState = PartitionedFetchState.make(
      ~maxAddrInPartition=2,
      ~dynamicContractRegistrations=[contractRegistration1, contractRegistration2],
      ~startBlock=0,
      ~endBlock=None,
      ~staticContracts=[
        ("Contract1", "0x1"->Address.unsafeFromString),
        ("Contract2", "0x2"->Address.unsafeFromString),
        ("Contract3", "0x3"->Address.unsafeFromString),
        ("Contract1", "0x4"->Address.unsafeFromString),
        ("Contract2", "0x5"->Address.unsafeFromString),
      ],
      ~hasWildcard=false,
      ~logger=Logging.logger,
    )

    Assert.deepEqual(
      partitionedFetchState,
      {
        partitions: [
          FetchState.make(
            ~partitionId=0,
            ~staticContracts=[
              ("Contract1", "0x1"->Address.unsafeFromString),
              ("Contract2", "0x2"->Address.unsafeFromString),
            ],
            ~dynamicContractRegistrations=[],
            ~isFetchingAtHead=false,
            ~kind=Normal,
            ~logger=Logging.logger,
            ~startBlock=0,
          ),
          FetchState.make(
            ~partitionId=1,
            ~staticContracts=[
              ("Contract3", "0x3"->Address.unsafeFromString),
              ("Contract1", "0x4"->Address.unsafeFromString),
            ],
            ~dynamicContractRegistrations=[],
            ~isFetchingAtHead=false,
            ~kind=Normal,
            ~logger=Logging.logger,
            ~startBlock=0,
          ),
          FetchState.make(
            ~partitionId=2,
            ~staticContracts=[("Contract2", "0x5"->Address.unsafeFromString)],
            ~dynamicContractRegistrations=[contractRegistration1],
            ~isFetchingAtHead=false,
            ~kind=Normal,
            ~logger=Logging.logger,
            ~startBlock=0,
          ),
          FetchState.make(
            ~partitionId=3,
            ~staticContracts=[],
            ~dynamicContractRegistrations=[contractRegistration2],
            ~isFetchingAtHead=false,
            ~kind=Normal,
            ~logger=Logging.logger,
            ~startBlock=0,
          ),
        ],
        maxAddrInPartition: 2,
        startBlock: 0,
        endBlock: None,
        logger: Logging.logger,
      },
      ~message="Create partitions for static contracts first, and then add dynamic contracts",
    )
  })

  it("Partition id never changes when adding new partitions", () => {
    let rootContractAddressMapping = ContractAddressingMap.make()

    for i in 0 to 3 {
      let address = TestHelpers.Addresses.mockAddresses[i]->Option.getExn
      rootContractAddressMapping->ContractAddressingMap.addAddress(~address, ~name="MockContract")
    }

    let rootRegister: FetchState.register = {
      registerType: RootRegister,
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

    let fetchState0: FetchState.t = {
      partitionId: 0,
      kind: Normal,
      baseRegister,
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
      fetchStateId: DynamicContract(dynamicContractId),
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

    Assert.deepEqual(
      updatedPartitionedFetchState.partitions->PartitionedFetchState.getReadyPartitions(
        ~maxPerChainQueueSize=1000,
        ~fetchingPartitions=Utils.Set.make(),
      ),
      [
        fetchState0,
        {
          partitionId: 1,
          kind: Normal,
          baseRegister: {
            registerType: RootRegister,
            latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
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
          },
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
