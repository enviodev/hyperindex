open Belt
open RescriptMocha
open FetchState
open Enums.ContractType

let getItem = item =>
  switch item {
  | Item({item}) => item->Some
  | NoItem(_) => None
  }

let mockAddress1 = TestHelpers.Addresses.mockAddresses[0]->Option.getExn
let mockAddress2 = TestHelpers.Addresses.mockAddresses[1]->Option.getExn
let mockAddress3 = TestHelpers.Addresses.mockAddresses[2]->Option.getExn
let mockAddress4 = TestHelpers.Addresses.mockAddresses[3]->Option.getExn
let mockFactoryAddress = TestHelpers.Addresses.mockAddresses[4]->Option.getExn

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
  ~registeringEventContractName="MockGravatarFactory",
  ~registeringEventName="MockCreateGravatar",
  ~registeringEventSrcAddress=mockFactoryAddress,
): TablesStatic.DynamicContractRegistry.t => {
  {
    id: ContextEnv.makeDynamicContractId(~chainId, ~contractAddress),
    chainId,
    registeringEventBlockNumber: blockNumber,
    registeringEventLogIndex: logIndex,
    registeringEventName,
    registeringEventSrcAddress,
    registeringEventBlockTimestamp: getTimestamp(~blockNumber),
    contractAddress,
    contractType,
    registeringEventContractName,
  }
}

let getDynContractId = (
  {registeringEventBlockNumber, registeringEventLogIndex}: TablesStatic.DynamicContractRegistry.t,
): FetchState.dynamicContractId => {
  blockNumber: registeringEventBlockNumber,
  logIndex: registeringEventLogIndex,
}

let makeMockFetchState = (baseRegister, ~isFetchingAtHead=false) => {
  partitionId: 0,
  baseRegister,
  pendingDynamicContracts: [],
  isFetchingAtHead,
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
      dcMap->DynamicContractsMap.removeContractAddressesFromFirstChangeEvent(
        ~firstChangeEvent={blockNumber: 6, logIndex: 0},
      )

    Assert.deepEqual(removedAddresses, [mockAddress3, mockAddress4])
  })

  it("dynamic contract registration", () => {
    let root = make(
      ~partitionId=0,
      ~startBlock=10_000,
      ~staticContracts=[((Gravatar :> string), mockAddress1)],
      ~dynamicContractRegistrations=[],
      ~isFetchingAtHead=false,
      ~logger=Logging.logger,
    )

    let dc1 = makeDynContractRegistration(~contractAddress=mockAddress2, ~blockNumber=50)
    let dcId1 = getDynContractId(dc1)

    let updatedState1 =
      root.baseRegister->addDynamicContractRegister(
        ~registeringEventBlockNumber=dcId1.blockNumber,
        ~registeringEventLogIndex=dcId1.logIndex,
        ~dynamicContractRegistrations=[dc1],
      )

    let expected1 = {
      latestFetchedBlock: {blockNumber: dcId1.blockNumber - 1, blockTimestamp: 0},
      contractAddressMapping: ContractAddressingMap.fromArray([
        (dc1.contractAddress, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(
        dcId1,
        [dc1.contractAddress],
      ),
      fetchedEventQueue: [],
      registerType: DynamicContractRegister({id: dcId1, nextRegister: root.baseRegister}),
    }

    Assert.deepEqual(updatedState1, expected1, ~message="1st registration")

    let dc2 = makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=55)
    let dcId2 = getDynContractId(dc2)

    let updatedState2 =
      updatedState1->addDynamicContractRegister(
        ~registeringEventBlockNumber=dcId2.blockNumber,
        ~registeringEventLogIndex=dcId2.logIndex,
        ~dynamicContractRegistrations=[dc2],
      )

    let expected2ChildRegister = {
      latestFetchedBlock: {blockNumber: dcId2.blockNumber - 1, blockTimestamp: 0},
      contractAddressMapping: ContractAddressingMap.fromArray([
        (dc2.contractAddress, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(
        dcId2,
        [dc2.contractAddress],
      ),
      fetchedEventQueue: [],
      registerType: DynamicContractRegister({id: dcId2, nextRegister: root.baseRegister}),
    }

    let expected2 = {
      ...expected1,
      registerType: DynamicContractRegister({id: dcId1, nextRegister: expected2ChildRegister}),
    }

    Assert.deepEqual(updatedState2, expected2, ~message="2nd registration")

    let dc3 = makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=60)
    let dcId3 = getDynContractId(dc3)

    let updatedState3 =
      updatedState2->addDynamicContractRegister(
        ~registeringEventBlockNumber=dcId3.blockNumber,
        ~registeringEventLogIndex=dcId3.logIndex,
        ~dynamicContractRegistrations=[dc3],
      )

    let expected3 = {
      ...expected2,
      registerType: DynamicContractRegister({
        id: dcId1,
        nextRegister: {
          ...expected2ChildRegister,
          registerType: DynamicContractRegister({
            id: dcId2,
            nextRegister: {
              latestFetchedBlock: {blockNumber: dcId3.blockNumber - 1, blockTimestamp: 0},
              contractAddressMapping: ContractAddressingMap.fromArray([
                (dc3.contractAddress, (Gravatar :> string)),
              ]),
              firstEventBlockNumber: None,
              dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(
                dcId3,
                [dc3.contractAddress],
              ),
              fetchedEventQueue: [],
              registerType: DynamicContractRegister({id: dcId3, nextRegister: root.baseRegister}),
            },
          }),
        },
      }),
    }

    Assert.deepEqual(updatedState3, expected3, ~message="3rd registration")
  })

  let mockEvent = (~blockNumber, ~logIndex=0, ~chainId=1): Internal.eventItem => {
    timestamp: blockNumber * 15,
    chain: ChainMap.Chain.makeUnsafe(~chainId),
    blockNumber,
    logIndex,
    eventName: "MockEvent",
    contractName: "MockContract",
    handler: None,
    loader: None,
    contractRegister: None,
    paramsRawEventSchema: Utils.magic("Mock event paramsRawEventSchema in fetchstate test"),
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
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=6, ~logIndex=1),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=1, ~logIndex=2),
      ],
      registerType: DynamicContractRegister({
        id: dcId,
        nextRegister: {
          latestFetchedBlock,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress1, (Gravatar :> string)),
          ]),
          firstEventBlockNumber: None,
          dynamicContracts: DynamicContractsMap.empty,
          fetchedEventQueue: [
            mockEvent(~blockNumber=6, ~logIndex=2),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=1, ~logIndex=1),
          ],
          registerType: RootRegister,
        },
      }),
    }

    let expected = {
      latestFetchedBlock,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
        (mockAddress1, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=6, ~logIndex=2),
        mockEvent(~blockNumber=6, ~logIndex=1),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=4),
        mockEvent(~blockNumber=1, ~logIndex=2),
        mockEvent(~blockNumber=1, ~logIndex=1),
      ],
      registerType: RootRegister,
    }

    Assert.deepEqual(fetchState->mergeIntoNextRegistered, expected)
  })

  it("update register", () => {
    let currentEvents = [
      mockEvent(~blockNumber=4),
      mockEvent(~blockNumber=1, ~logIndex=2),
      mockEvent(~blockNumber=1, ~logIndex=1),
    ]
    let root = {
      latestFetchedBlock: getBlockData(~blockNumber=500),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress1, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: Some(1),
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: currentEvents,
      registerType: RootRegister,
    }

    let fetchState = makeMockFetchState(root)

    let newItems = [
      mockEvent(~blockNumber=5),
      mockEvent(~blockNumber=6, ~logIndex=1),
      mockEvent(~blockNumber=6, ~logIndex=2),
    ]
    let updated1 =
      fetchState
      ->update(
        ~id=Root,
        ~latestFetchedBlock=getBlockData(~blockNumber=600),
        ~currentBlockHeight=600,
        ~newItems,
      )
      ->Utils.unwrapResultExn

    let expectedRegister1 = {
      ...root,
      latestFetchedBlock: getBlockData(~blockNumber=600),
      fetchedEventQueue: Array.concat(newItems->Array.reverse, currentEvents),
    }

    let expected1 = expectedRegister1->makeMockFetchState(~isFetchingAtHead=true)

    Assert.deepEqual(expected1, updated1, ~message="1st register, should be fetching at head")

    let dcId1: dynamicContractId = {blockNumber: 100, logIndex: 0}
    let register1 = {
      latestFetchedBlock: getBlockData(~blockNumber=500),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId1, [mockAddress2]),
      fetchedEventQueue: [],
      registerType: DynamicContractRegister({id: dcId1, nextRegister: root}),
    }

    let fetchState1 = register1->makeMockFetchState

    let updated2 =
      fetchState1
      ->update(
        ~id=DynamicContract(dcId1),
        ~latestFetchedBlock=getBlockData(~blockNumber=500),
        ~currentBlockHeight=600,
        ~newItems,
      )
      ->Utils.unwrapResultExn

    let register2 = {
      ...expectedRegister1,
      latestFetchedBlock: getBlockData(~blockNumber=500),
      dynamicContracts: register1.dynamicContracts,
      contractAddressMapping: register1.contractAddressMapping->ContractAddressingMap.combine(
        root.contractAddressMapping,
      ),
    }

    let expected2 = register2->makeMockFetchState(~isFetchingAtHead=false)

    Assert.deepEqual(expected2, updated2, ~message="2nd register not fetching at head")

    let dcId2: dynamicContractId = {blockNumber: 99, logIndex: 0}
    let register2 = {
      latestFetchedBlock: getBlockData(~blockNumber=300),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress3, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId2, [mockAddress3]),
      fetchedEventQueue: [],
      registerType: DynamicContractRegister({id: dcId2, nextRegister: fetchState1.baseRegister}),
    }

    let fetchState2 = register2->makeMockFetchState

    let updated3 =
      fetchState2
      ->update(
        ~id=DynamicContract(dcId1),
        ~latestFetchedBlock=getBlockData(~blockNumber=500),
        ~currentBlockHeight=600,
        ~newItems,
      )
      ->Utils.unwrapResultExn

    let expectedRegister3 = {
      ...register2,
      registerType: DynamicContractRegister({
        id: dcId2,
        nextRegister: {
          ...register1,
          fetchedEventQueue: Array.concat(newItems->Array.reverse, register1.fetchedEventQueue),
          firstEventBlockNumber: Some(5),
          registerType: DynamicContractRegister({id: dcId1, nextRegister: root}),
        },
      }),
    }
    let expected3 = expectedRegister3->makeMockFetchState(~isFetchingAtHead=false)

    Assert.deepEqual(expected3, updated3, ~message="3rd register not fetching at head")
  })

  it("getEarliest event", () => {
    let dcId: dynamicContractId = {blockNumber: 100, logIndex: 0}
    let latestFetchedBlock = getBlockData(~blockNumber=500)

    let baseRegister = {
      latestFetchedBlock,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=6, ~logIndex=1),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=1, ~logIndex=2),
      ],
      registerType: DynamicContractRegister({
        id: dcId,
        nextRegister: {
          latestFetchedBlock,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress1, (Gravatar :> string)),
          ]),
          firstEventBlockNumber: None,
          dynamicContracts: DynamicContractsMap.empty,
          fetchedEventQueue: [
            mockEvent(~blockNumber=6, ~logIndex=2),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=1, ~logIndex=1),
          ],
          registerType: RootRegister,
        },
      }),
    }

    let fetchState = baseRegister->makeMockFetchState

    let earliestQueueItem = fetchState->getEarliestEvent->getItem->Option.getExn

    Assert.deepEqual(earliestQueueItem, mockEvent(~blockNumber=1, ~logIndex=1))
  })

  it("getEarliestEvent accounts for pending dynamicContracts", () => {
    let baseRegister = {
      latestFetchedBlock: {
        blockNumber: 500,
        blockTimestamp: 500 * 15,
      },
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress1, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: [
        mockEvent(~blockNumber=106, ~logIndex=1),
        mockEvent(~blockNumber=105),
        mockEvent(~blockNumber=101, ~logIndex=2),
      ],
      registerType: RootRegister,
    }
    let dynamicContractRegistration = {
      registeringEventBlockNumber: 100,
      registeringEventLogIndex: 0,
      registeringEventChain: ChainMap.Chain.makeUnsafe(~chainId=1),
      dynamicContracts: [],
    }

    let fetchState = {
      ...baseRegister->makeMockFetchState,
      pendingDynamicContracts: [dynamicContractRegistration],
    }
    let earliestQueueItem = fetchState->getEarliestEvent

    Assert.deepEqual(
      earliestQueueItem,
      NoItem({
        blockNumber: dynamicContractRegistration.registeringEventBlockNumber - 1,
        blockTimestamp: 0,
      }),
      ~message="Should account for pending dynamicContracts earliest registering event",
    )
  })

  it("isReadyForNextQuery standard", () => {
    let baseRegister = {
      latestFetchedBlock: {
        blockNumber: 500,
        blockTimestamp: 500 * 15,
      },
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress1, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: [
        mockEvent(~blockNumber=6, ~logIndex=1),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=1, ~logIndex=2),
      ],
      registerType: RootRegister,
    }
    let fetchState = baseRegister->makeMockFetchState

    Assert.ok(
      fetchState->isReadyForNextQuery(~maxQueueSize=10),
      ~message="Should be ready for next query when under max queue size",
    )

    Assert.ok(
      !(fetchState->isReadyForNextQuery(~maxQueueSize=3)),
      ~message="Should not be ready for next query when at max queue size",
    )
  })

  it(
    "isReadyForNextQuery when cummulatively over max queue size but dynamic contract is under",
    () => {
      let rootRegister = {
        latestFetchedBlock: {
          blockNumber: 500,
          blockTimestamp: 500 * 15,
        },
        contractAddressMapping: ContractAddressingMap.fromArray([
          (mockAddress1, (Gravatar :> string)),
        ]),
        firstEventBlockNumber: None,
        dynamicContracts: DynamicContractsMap.empty,
        fetchedEventQueue: [
          mockEvent(~blockNumber=6, ~logIndex=1),
          mockEvent(~blockNumber=5),
          mockEvent(~blockNumber=4, ~logIndex=2),
        ],
        registerType: RootRegister,
      }

      let baseRegister = {
        registerType: DynamicContractRegister({
          id: {blockNumber: 100, logIndex: 0},
          nextRegister: rootRegister,
        }),
        latestFetchedBlock: {
          blockNumber: 500,
          blockTimestamp: 500 * 15,
        },
        contractAddressMapping: ContractAddressingMap.fromArray([
          (mockAddress2, (Gravatar :> string)),
        ]),
        firstEventBlockNumber: None,
        dynamicContracts: DynamicContractsMap.empty,
        fetchedEventQueue: [
          mockEvent(~blockNumber=3, ~logIndex=2),
          mockEvent(~blockNumber=2),
          mockEvent(~blockNumber=1, ~logIndex=1),
        ],
      }

      let fetchState = baseRegister->makeMockFetchState

      Assert.equal(fetchState->queueSize, 6, ~message="Should have 6 items total in queue")

      Assert.ok(
        fetchState->isReadyForNextQuery(~maxQueueSize=5),
        ~message="Should be ready for next query when base register is under max queue size",
      )
    },
  )

  it("isReadyForNextQuery when containing pending dynamic contracts", () => {
    let baseRegister = {
      latestFetchedBlock: {
        blockNumber: 500,
        blockTimestamp: 500 * 15,
      },
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress1, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: [
        mockEvent(~blockNumber=6, ~logIndex=1),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=1, ~logIndex=2),
      ],
      registerType: RootRegister,
    }
    let dynamicContractRegistration = {
      registeringEventBlockNumber: 100,
      registeringEventLogIndex: 0,
      registeringEventChain: ChainMap.Chain.makeUnsafe(~chainId=1),
      dynamicContracts: [],
    }

    let fetchStateWithoutPendingDynamicContracts = baseRegister->makeMockFetchState

    Assert.ok(
      !(fetchStateWithoutPendingDynamicContracts->isReadyForNextQuery(~maxQueueSize=3)),
      ~message="Should not be ready for next query when base register is at the max queue size",
    )

    let fetchStateWithPendingDynamicContracts = {
      ...fetchStateWithoutPendingDynamicContracts,
      pendingDynamicContracts: [dynamicContractRegistration],
    }

    Assert.ok(
      fetchStateWithPendingDynamicContracts->isReadyForNextQuery(~maxQueueSize=3),
      ~message="Should be ready for next query when base register is at the max queue size but contains pending dynamic contracts",
    )
  })

  it("getNextQuery", () => {
    let latestFetchedBlock = getBlockData(~blockNumber=500)
    let root = {
      latestFetchedBlock,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress1, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: [
        mockEvent(~blockNumber=6, ~logIndex=2),
        mockEvent(~blockNumber=4),
        mockEvent(~blockNumber=1, ~logIndex=1),
      ],
      registerType: RootRegister,
    }

    let fetchState = {
      partitionId: 0,
      baseRegister: root,
      pendingDynamicContracts: [],
      isFetchingAtHead: false,
    }

    Assert.deepEqual(
      fetchState->getNextQuery(~endBlock=None),
      NextQuery({
        fetchStateRegisterId: Root,
        partitionId: 0,
        fromBlock: root.latestFetchedBlock.blockNumber + 1,
        toBlock: None,
        contractAddressMapping: root.contractAddressMapping,
      }),
    )

    let endblockCase = {
      ...fetchState,
      baseRegister: {
        ...root,
        latestFetchedBlock: {
          blockNumber: 500,
          blockTimestamp: 0,
        },
        fetchedEventQueue: [],
        registerType: RootRegister,
      },
    }

    let nextQuery = endblockCase->getNextQuery(~endBlock=Some(500))

    Assert.deepEqual(Done, nextQuery)
  })

  it("check contains contract address", () => {
    let dcId: dynamicContractId = {blockNumber: 100, logIndex: 0}
    let latestFetchedBlock = getBlockData(~blockNumber=500)

    let baseRegister = {
      latestFetchedBlock,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=6, ~logIndex=1),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=1, ~logIndex=2),
      ],
      registerType: DynamicContractRegister({
        id: dcId,
        nextRegister: {
          latestFetchedBlock,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress1, (Gravatar :> string)),
          ]),
          firstEventBlockNumber: None,
          dynamicContracts: DynamicContractsMap.empty,
          fetchedEventQueue: [
            mockEvent(~blockNumber=6, ~logIndex=2),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=1, ~logIndex=1),
          ],
          registerType: RootRegister,
        },
      }),
    }

    let fetchState = {
      partitionId: 0,
      baseRegister,
      pendingDynamicContracts: [],
      isFetchingAtHead: false,
    }

    Assert.equal(
      fetchState->checkContainsRegisteredContractAddress(
        ~contractAddress=mockAddress1,
        ~contractName=(Gravatar :> string),
        ~chainId=1,
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
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: [mockEvent(~blockNumber=140), mockEvent(~blockNumber=99)],
      registerType: RootRegister,
    }

    case1->makeMockFetchState->isActivelyIndexing(~endBlock=Some(150))->Assert.equal(true)

    let case2 = {
      ...case1,
      fetchedEventQueue: [],
    }

    case2->makeMockFetchState->isActivelyIndexing(~endBlock=Some(150))->Assert.equal(false)

    let case3 = {
      ...case2,
      registerType: DynamicContractRegister({
        id: {blockNumber: 100, logIndex: 0},
        nextRegister: case2,
      }),
    }

    case3->makeMockFetchState->isActivelyIndexing(~endBlock=Some(150))->Assert.equal(true)

    let case4 = {
      ...case1,
      registerType: RootRegister,
    }

    case4->makeMockFetchState->isActivelyIndexing(~endBlock=Some(151))->Assert.equal(true)

    let case5 = {
      ...case1,
      registerType: RootRegister,
    }

    case5->makeMockFetchState->isActivelyIndexing(~endBlock=None)->Assert.equal(true)
  })

  it("rolls back", () => {
    let dcId1: dynamicContractId = {blockNumber: 100, logIndex: 0}
    let dcId2: dynamicContractId = {blockNumber: 101, logIndex: 0}

    let root = {
      latestFetchedBlock: getBlockData(~blockNumber=150),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress1, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty,
      fetchedEventQueue: [mockEvent(~blockNumber=140), mockEvent(~blockNumber=99)],
      registerType: RootRegister,
    }

    let register2 = {
      latestFetchedBlock: getBlockData(~blockNumber=120),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress3, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId2, [mockAddress3]),
      fetchedEventQueue: [mockEvent(~blockNumber=110)],
      registerType: DynamicContractRegister({id: dcId2, nextRegister: root}),
    }

    let register3 = {
      latestFetchedBlock: getBlockData(~blockNumber=99),
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId1, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=6, ~logIndex=1),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=1, ~logIndex=2),
      ],
      registerType: DynamicContractRegister({id: dcId1, nextRegister: register2}),
    }

    let fetchState = register3->makeMockFetchState

    let updated =
      fetchState->rollback(
        ~lastScannedBlock=getBlockData(~blockNumber=100),
        ~firstChangeEvent={blockNumber: 101, logIndex: 0},
      )

    let expected = {
      ...register3,
      registerType: DynamicContractRegister({
        id: dcId1,
        nextRegister: {
          ...root,
          latestFetchedBlock: getBlockData(~blockNumber=100),
          fetchedEventQueue: [mockEvent(~blockNumber=99)],
        },
      }),
    }->makeMockFetchState

    Assert.deepEqual(
      expected,
      updated,
      ~message="should have removed the second register and rolled back the others",
    )
  })

  it("counts number of contracts correctly", () => {
    let dcId: dynamicContractId = {blockNumber: 100, logIndex: 0}
    let latestFetchedBlock = getBlockData(~blockNumber=500)

    let baseRegister = {
      latestFetchedBlock,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, (Gravatar :> string)),
      ]),
      firstEventBlockNumber: None,
      dynamicContracts: DynamicContractsMap.empty->DynamicContractsMap.add(dcId, [mockAddress2]),
      fetchedEventQueue: [
        mockEvent(~blockNumber=6, ~logIndex=1),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=1, ~logIndex=2),
      ],
      registerType: DynamicContractRegister({
        id: dcId,
        nextRegister: {
          latestFetchedBlock,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress1, (Gravatar :> string)),
          ]),
          firstEventBlockNumber: None,
          dynamicContracts: DynamicContractsMap.empty,
          fetchedEventQueue: [
            mockEvent(~blockNumber=6, ~logIndex=2),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=1, ~logIndex=1),
          ],
          registerType: RootRegister,
        },
      }),
    }

    baseRegister->makeMockFetchState->getNumContracts->Assert.equal(2)
  })

  it(
    "Adding dynamic between two registers while query is mid flight does no result in early merged registers",
    () => {
      let currentBlockHeight = 600
      let chainId = 1
      let chain = ChainMap.Chain.makeUnsafe(~chainId)

      let rootRegister = {
        latestFetchedBlock: getBlockData(~blockNumber=500),
        contractAddressMapping: ContractAddressingMap.fromArray([
          (mockAddress1, (Gravatar :> string)),
        ]),
        firstEventBlockNumber: None,
        dynamicContracts: DynamicContractsMap.empty,
        fetchedEventQueue: [
          mockEvent(~blockNumber=6, ~logIndex=2),
          mockEvent(~blockNumber=4),
          mockEvent(~blockNumber=1, ~logIndex=1),
        ],
        registerType: RootRegister,
      }

      let mockFetchState = rootRegister->makeMockFetchState

      //Dynamic contract  A registered at block 100
      let withRegisteredDynamicContractA = mockFetchState->registerDynamicContract(
        {
          registeringEventChain: chain,
          registeringEventBlockNumber: 100,
          registeringEventLogIndex: 0,
          dynamicContracts: ["MockDynamicContractA"->Utils.magic],
        },
        ~isFetchingAtHead=false,
      )

      let withAddedDynamicContractRegisterA =
        withRegisteredDynamicContractA->mergeRegistersBeforeNextQuery
      //Received query
      let queryA = switch withAddedDynamicContractRegisterA->getNextQuery(~endBlock=None) {
      | NextQuery(queryA) =>
        switch queryA {
        | {
            fetchStateRegisterId: DynamicContract({blockNumber: 100, logIndex: 0}),
            fromBlock: 100,
            toBlock: Some(500),
          } => queryA
        | query =>
          Js.log2("unexpected queryA", query)
          Assert.fail(
            "Should have returned a query from new contract register from the registering block number to the next register latest block",
          )
        }
      | nextQuery =>
        Js.log2("nextQueryA res", nextQuery)
        Js.Exn.raiseError(
          "Should have returned a query with updated fetch state applying dynamic contracts",
        )
      }

      //Next registration happens at block 200, between the first register and the upperbound of it's query
      let withRegisteredDynamicContractB =
        withAddedDynamicContractRegisterA->registerDynamicContract(
          {
            registeringEventChain: chain,
            registeringEventBlockNumber: 200,
            registeringEventLogIndex: 0,
            dynamicContracts: ["MockDynamicContractB"->Utils.magic],
          },
          ~isFetchingAtHead=false,
        )

      //Response with updated fetch state
      let updatesWithResponseFromQueryA =
        withRegisteredDynamicContractB
        ->update(
          ~id=queryA.fetchStateRegisterId,
          ~latestFetchedBlock=getBlockData(~blockNumber=400),
          ~currentBlockHeight,
          ~newItems=[],
        )
        ->Utils.unwrapResultExn

      switch updatesWithResponseFromQueryA->getNextQuery(~endBlock=None) {
      | NextQuery({
          fetchStateRegisterId: DynamicContract({blockNumber: 200, logIndex: 0}),
          fromBlock: 200,
          toBlock: Some(400),
        }) => ()
      | nextQuery =>
        Js.log2("nextQueryB res", nextQuery)
        Assert.fail(
          "Should have returned query using registered contract B, from it's registering block to the last block fetched in query A",
        )
      }
    },
  )
})
