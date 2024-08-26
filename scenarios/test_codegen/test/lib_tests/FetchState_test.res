open Belt
open RescriptMocha
open FetchState
open Enums.ContractType

let mockAddress1 = TestHelpers.Addresses.mockAddresses[0]->Option.getExn
let mockAddress2 = TestHelpers.Addresses.mockAddresses[1]->Option.getExn
let mockAddress3 = TestHelpers.Addresses.mockAddresses[2]->Option.getExn
let mockAddress4 = TestHelpers.Addresses.mockAddresses[3]->Option.getExn

let getTimestamp = (~blockNumber) => blockNumber * 15
let getBlockData = (~blockNumber) => {
  blockNumber,
  blockTimestamp: getTimestamp(~blockNumber),
}

let makeDynContractRegistration = (
  ~contractAddress,
  ~blockNumber,
  ~logIndex=0,
  ~chainId=1,
  ~contractType=Gravatar,
): TablesStatic.DynamicContractRegistry.t => {
  {
    chainId,
    eventId: EventUtils.packEventIndex(~blockNumber, ~logIndex),
    blockTimestamp: getTimestamp(~blockNumber),
    contractAddress,
    contractType,
  }
}

let getDynContractId = (
  d: TablesStatic.DynamicContractRegistry.t,
): FetchState.dynamicContractId => {
  EventUtils.unpackEventIndex(d.eventId)
}

describe("FetchState.fetchState", () => {
  it("dynamic contract map", () => {
    let makeDcId = (blockNumber, logIndex): dynamicContractId => {
      blockNumber,
      logIndex,
    }
    let dcId1 = makeDcId(5, 0)
    let dcId2 = makeDcId(5, 1)
    let dcId3 = makeDcId(6, 0)
    let dcId4 = makeDcId(7, 0)
    let addAddr = DynamicContractsMap.addAddress
    let dcMap =
      DynamicContractsMap.empty
      ->addAddr(dcId1, mockAddress1)
      ->addAddr(dcId2, mockAddress2)
      ->addAddr(dcId3, mockAddress3)
      ->addAddr(dcId4, mockAddress4)

    let (_updatedMap, removedAddresses) =
      dcMap->DynamicContractsMap.removeContractAddressesPastValidBlock(
        ~lastKnownValidBlock={blockNumber: 5, blockTimestamp: 5 * 15},
      )

    Assert.deepEqual(removedAddresses, [mockAddress3, mockAddress4])
  })

  it("dynamic contract registration", () => {
    let root = {
      registerType: RootRegister({endBlock: None}),
      latestFetchedBlock: getBlockData(~blockNumber=10_000),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress1, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: [],
    }

    let dc1 = makeDynContractRegistration(~contractAddress=mockAddress2, ~blockNumber=50)
    let dcId1 = getDynContractId(dc1)

    let updatedState1 =
      root->registerDynamicContract(
        ~registeringEventBlockNumber=dcId1.blockNumber,
        ~registeringEventLogIndex=dcId1.logIndex,
        ~dynamicContractRegistrations=[dc1],
      )

    let expected1 = {
      latestFetchedBlock: {blockNumber: dcId1.blockNumber - 1, blockTimestamp: 0},
      contractAddressMapping: ContractAddressingMap.fromArray([
        (dc1.contractAddress, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(
        dcId1,
        [dc1.contractAddress],
      ),
      fetchedEventQueue: [],
      registerType: DynamicContractRegister(dcId1, root),
    }

    Assert.deepEqual(updatedState1, expected1, ~message="1st registration")

    let dc2 = makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=55)
    let dcId2 = getDynContractId(dc2)

    let updatedState2 =
      updatedState1->registerDynamicContract(
        ~registeringEventBlockNumber=dcId2.blockNumber,
        ~registeringEventLogIndex=dcId2.logIndex,
        ~dynamicContractRegistrations=[dc2],
      )

    let expected2ChildRegister = {
      latestFetchedBlock: {blockNumber: dcId2.blockNumber - 1, blockTimestamp: 0},
      contractAddressMapping: ContractAddressingMap.fromArray([
        (dc2.contractAddress, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(
        dcId2,
        [dc2.contractAddress],
      ),
      fetchedEventQueue: [],
      registerType: DynamicContractRegister(dcId2, root),
    }

    let expected2 = {
      ...expected1,
      registerType: DynamicContractRegister(dcId1, expected2ChildRegister),
    }

    Assert.deepEqual(updatedState2, expected2, ~message="2nd registration")

    let dc3 = makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=60)
    let dcId3 = getDynContractId(dc3)

    let updatedState3 =
      updatedState2->registerDynamicContract(
        ~registeringEventBlockNumber=dcId3.blockNumber,
        ~registeringEventLogIndex=dcId3.logIndex,
        ~dynamicContractRegistrations=[dc3],
      )

    let expected3 = {
      ...expected2,
      registerType: DynamicContractRegister(
        dcId1,
        {
          ...expected2ChildRegister,
          registerType: DynamicContractRegister(
            dcId2,
            {
              latestFetchedBlock: {blockNumber: dcId3.blockNumber - 1, blockTimestamp: 0},
              contractAddressMapping: ContractAddressingMap.fromArray([
                (dc3.contractAddress, (Gravatar :> string)),
              ]),
              isFetchingAtHead: false,
              firstEventBlockNumber: None,
              dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(
                dcId3,
                [dc3.contractAddress],
              ),
              fetchedEventQueue: [],
              registerType: DynamicContractRegister(dcId3, root),
            },
          ),
        },
      ),
    }

    Assert.deepEqual(updatedState3, expected3, ~message="3rd registration")
  })

  let mockEvent = (~blockNumber, ~logIndex=0, ~chainId=1): Types.eventBatchQueueItem => {
    timestamp: blockNumber * 15,
    chain: ChainMap.Chain.makeUnsafe(~chainId),
    blockNumber,
    logIndex,
    eventMod: Utils.magic("Mock event mod in fetchstate test"),
    event: Utils.magic("Mock event in fetchstate test"),
  }

  it("merge next register", () => {
    let dcId: dynamicContractId = {blockNumber: 100, logIndex: 0}
    let latestFetchedBlock = getBlockData(~blockNumber=500)

    let fetchState = {
      latestFetchedBlock,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=1, ~logIndex=2),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=6, ~logIndex=1),
      ],
      registerType: DynamicContractRegister(
        dcId,
        {
          latestFetchedBlock,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress1, (Gravatar :> string)),
          ]),
          isFetchingAtHead: false,
          firstEventBlockNumber: None,
          dynamicContracts: DynamicContractsMap.empty,
          fetchedEventQueue: [
            mockEvent(~blockNumber=1, ~logIndex=1),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=6, ~logIndex=2),
          ],
          registerType: RootRegister({endBlock: None}),
        },
      ),
    }

    let expected = {
      latestFetchedBlock,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
        (mockAddress1, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=1, ~logIndex=1),
        mockEvent(~blockNumber=1, ~logIndex=2),
        mockEvent(~blockNumber=4),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=6, ~logIndex=1),
        mockEvent(~blockNumber=6, ~logIndex=2),
      ],
      registerType: RootRegister({endBlock: None}),
    }

    Assert.deepEqual(fetchState->mergeIntoNextRegistered, expected)
  })

  it("update register", () => {
    let currentEvents = [
      mockEvent(~blockNumber=1, ~logIndex=1),
      mockEvent(~blockNumber=1, ~logIndex=2),
      mockEvent(~blockNumber=4),
    ]
    let fetchState = {
      latestFetchedBlock: getBlockData(~blockNumber=500),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress1, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: Some(1),
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: currentEvents,
      registerType: RootRegister({endBlock: None}),
    }

    let newEvents = [
      mockEvent(~blockNumber=5),
      mockEvent(~blockNumber=6, ~logIndex=1),
      mockEvent(~blockNumber=6, ~logIndex=2),
    ]
    let updated =
      fetchState
      ->update(
        ~id=Root,
        ~latestFetchedBlock=getBlockData(~blockNumber=600),
        ~currentBlockHeight=600,
        ~fetchedEvents=newEvents,
      )
      ->Utils.unwrapResultExn

    let expected = {
      ...fetchState,
      latestFetchedBlock: getBlockData(~blockNumber=600),
      isFetchingAtHead: true,
      fetchedEventQueue: Array.concat(currentEvents, newEvents),
    }

    Assert.deepEqual(updated, expected)
  })

  it("getEarliest event", () => {
    let dcId: dynamicContractId = {blockNumber: 100, logIndex: 0}
    let latestFetchedBlock = getBlockData(~blockNumber=500)

    let fetchState = {
      latestFetchedBlock,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=1, ~logIndex=2),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=6, ~logIndex=1),
      ],
      registerType: DynamicContractRegister(
        dcId,
        {
          latestFetchedBlock,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress1, (Gravatar :> string)),
          ]),
          isFetchingAtHead: false,
          firstEventBlockNumber: None,
          dynamicContracts: DynamicContractsMap.empty,
          fetchedEventQueue: [
            mockEvent(~blockNumber=1, ~logIndex=1),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=6, ~logIndex=2),
          ],
          registerType: RootRegister({endBlock: None}),
        },
      ),
    }

    let {earliestQueueItem} = fetchState->getEarliestEvent

    Assert.deepEqual(earliestQueueItem, Item(mockEvent(~blockNumber=1, ~logIndex=1)))
  })

  it("getNextQuery", () => {
    let latestFetchedBlock = getBlockData(~blockNumber=500)
    let root = {
      latestFetchedBlock,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress1, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: [
        mockEvent(~blockNumber=1, ~logIndex=1),
        mockEvent(~blockNumber=4),
        mockEvent(~blockNumber=6, ~logIndex=2),
      ],
      registerType: RootRegister({endBlock: None}),
    }

    let partitionId = 0
    let currentBlockHeight = 600
    let (nextQuery, _optUpdatedRoot) =
      root->getNextQuery(~partitionId, ~currentBlockHeight)->Utils.unwrapResultExn

    Assert.deepEqual(
      nextQuery,
      NextQuery({
        fetchStateRegisterId: Root,
        partitionId,
        fromBlock: root.latestFetchedBlock.blockNumber + 1,
        toBlock: currentBlockHeight,
        contractAddressMapping: root.contractAddressMapping,
        eventFilters: Utils.magic(%raw(`undefined`)), //assertions fail if this is not explicitly set to undefined
      }),
    )
  })

  it("check contains contract address", () => {
    let dcId: dynamicContractId = {blockNumber: 100, logIndex: 0}
    let latestFetchedBlock = getBlockData(~blockNumber=500)

    let fetchState = {
      latestFetchedBlock,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=1, ~logIndex=2),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=6, ~logIndex=1),
      ],
      registerType: DynamicContractRegister(
        dcId,
        {
          latestFetchedBlock,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress1, (Gravatar :> string)),
          ]),
          isFetchingAtHead: false,
          firstEventBlockNumber: None,
          dynamicContracts: DynamicContractsMap.empty,
          fetchedEventQueue: [
            mockEvent(~blockNumber=1, ~logIndex=1),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=6, ~logIndex=2),
          ],
          registerType: RootRegister({endBlock: None}),
        },
      ),
    }

    Assert.equal(
      fetchState->checkContainsRegisteredContractAddress(
        ~contractAddress=mockAddress1,
        ~contractName=(Gravatar :> string),
      ),
      true,
    )
  })

  it("isActively indexing", () => {
    let case1 = {
      latestFetchedBlock: getBlockData(~blockNumber=150),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress1, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: [mockEvent(~blockNumber=99), mockEvent(~blockNumber=140)],
      registerType: RootRegister({endBlock: Some(150)}),
    }

    case1->isActivelyIndexing->Assert.equal(true)

    let case2 = {
      ...case1,
      fetchedEventQueue: [],
    }

    case2->isActivelyIndexing->Assert.equal(false)

    let case3 = {
      ...case2,
      registerType: DynamicContractRegister({blockNumber: 100, logIndex: 0}, case2),
    }

    case3->isActivelyIndexing->Assert.equal(true)

    let case4 = {
      ...case1,
      registerType: RootRegister({endBlock: Some(151)}),
    }

    case4->isActivelyIndexing->Assert.equal(true)

    let case5 = {
      ...case1,
      registerType: RootRegister({endBlock: None}),
    }

    case5->isActivelyIndexing->Assert.equal(true)
  })

  it("rolls back", () => {
    let dcId1: dynamicContractId = {blockNumber: 100, logIndex: 0}
    let dcId2: dynamicContractId = {blockNumber: 101, logIndex: 0}

    let root = {
      latestFetchedBlock: getBlockData(~blockNumber=150),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress1, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: [mockEvent(~blockNumber=99), mockEvent(~blockNumber=140)],
      registerType: RootRegister({endBlock: None}),
    }

    let register2 = {
      latestFetchedBlock: getBlockData(~blockNumber=120),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress3, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId2, [mockAddress3]),
      fetchedEventQueue: [mockEvent(~blockNumber=110)],
      registerType: DynamicContractRegister(dcId2, root),
    }

    let fetchState = {
      latestFetchedBlock: getBlockData(~blockNumber=99),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId1, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=1, ~logIndex=2),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=6, ~logIndex=1),
      ],
      registerType: DynamicContractRegister(dcId1, register2),
    }

    let updated = fetchState->rollback(~lastKnownValidBlock=getBlockData(~blockNumber=100))

    let expected = {
      ...fetchState,
      registerType: DynamicContractRegister(
        dcId1,
        {
          ...root,
          latestFetchedBlock: getBlockData(~blockNumber=100),
          fetchedEventQueue: [mockEvent(~blockNumber=99)],
        },
      ),
    }
    Assert.deepEqual(
      expected,
      updated,
      ~message="should have removed the second register and rolled back the others",
    )
  })

  it("counts number of contracts correctly", () => {
    let dcId: dynamicContractId = {blockNumber: 100, logIndex: 0}
    let latestFetchedBlock = getBlockData(~blockNumber=500)

    let fetchState = {
      latestFetchedBlock,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
      ]),
      isFetchingAtHead: false,
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=1, ~logIndex=2),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=6, ~logIndex=1),
      ],
      registerType: DynamicContractRegister(
        dcId,
        {
          latestFetchedBlock,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress1, (Gravatar :> string)),
          ]),
          isFetchingAtHead: false,
          firstEventBlockNumber: None,
          dynamicContracts: DynamicContractsMap.empty,
          fetchedEventQueue: [
            mockEvent(~blockNumber=1, ~logIndex=1),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=6, ~logIndex=2),
          ],
          registerType: RootRegister({endBlock: None}),
        },
      ),
    }

    fetchState->getNumContracts->Assert.equal(2)
  })
})
