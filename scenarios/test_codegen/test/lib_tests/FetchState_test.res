open Belt
open RescriptMocha
open Enums.ContractType

let getItem = (item: FetchState.queueItem) =>
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
let getBlockData = (~blockNumber): FetchState.blockNumberAndTimestamp => {
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

let makeMockFetchState = (registers, ~isFetchingAtHead=false): FetchState.t =>
  {
    registers,
    nextPartitionIndex: 1,
    latestFullyFetchedBlock: {
      blockNumber: 100,
      blockTimestamp: 0,
    },
    batchSize: 5000,
    fetchMode: FetchState.InitialFill,
    firstEventBlockNumber: None,
    maxAddrInPartition: 5000,
    queueSize: 0,
    isFetchingAtHead,
  }->FetchState.updateInternal

// describe("FetchState.fetchState", () => {
//   it("dynamic contract map", () => {
//     let makeDcId = (blockNumber, logIndex): FetchState.dynamicContractId => {
//       blockNumber,
//       logIndex,
//     }
//     let dcId1 = makeDcId(5, 0)
//     let dcId2 = makeDcId(5, 1)
//     let dcId3 = makeDcId(6, 0)
//     let dcId4 = makeDcId(7, 0)
//     let addAddr = FetchState.DynamicContractsMap.addAddress
//     let dcMap =
//       FetchState.DynamicContractsMap.empty
//       ->addAddr(dcId1, mockAddress1)
//       ->addAddr(dcId2, mockAddress2)
//       ->addAddr(dcId3, mockAddress3)
//       ->addAddr(dcId4, mockAddress4)

//     let (_updatedMap, removedAddresses) =
//       dcMap->FetchState.DynamicContractsMap.removeContractAddressesFromFirstChangeEvent(
//         ~firstChangeEvent={blockNumber: 6, logIndex: 0},
//       )

//     Assert.deepEqual(removedAddresses, [mockAddress3, mockAddress4])
//   })

//   it("dynamic contract registration", () => {
//     let root = FetchState.make(
//       ~startBlock=10_000,
//       ~staticContracts=[((Gravatar :> string), mockAddress1)],
//       ~dynamicContractRegistrations=[],
//       ~isFetchingAtHead=false,
//       ~maxAddrInPartition=5000,
//     )
//     let rootRegister = root.mostBehindRegister

//     let dc1 = makeDynContractRegistration(~contractAddress=mockAddress2, ~blockNumber=50)
//     let dcId1 = getDynContractId(dc1)

//     let root = root->FetchState.registerDynamicContract(
//       {
//         {
//           registeringEventBlockNumber: dc1.registeringEventBlockNumber,
//           registeringEventLogIndex: dc1.registeringEventLogIndex,
//           registeringEventChain: ChainMap.Chain.makeUnsafe(~chainId=dc1.chainId),
//           dynamicContracts: [dc1],
//         }
//       },
//       ~isFetchingAtHead=false,
//     )

//     let expected1: FetchState.register = {
//       latestFetchedBlock: {blockNumber: dcId1.blockNumber - 1, blockTimestamp: 0},
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (dc1.contractAddress, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.add(
//         dcId1,
//         [dc1.contractAddress],
//       ),
//       fetchedEventQueue: [],
//       id: FetchState.makeDynamicContractRegisterId(dcId1),
//     }

//     Assert.deepEqual(root.registers, [expected1, rootRegister], ~message="1st registration")

//     let dc2 = makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=55)
//     let dcId2 = getDynContractId(dc2)

//     let root = root->FetchState.registerDynamicContract(
//       {
//         {
//           registeringEventBlockNumber: dc2.registeringEventBlockNumber,
//           registeringEventLogIndex: dc2.registeringEventLogIndex,
//           registeringEventChain: ChainMap.Chain.makeUnsafe(~chainId=dc2.chainId),
//           dynamicContracts: [dc2],
//         }
//       },
//       ~isFetchingAtHead=false,
//     )

//     let expected2: FetchState.register = {
//       latestFetchedBlock: {blockNumber: dcId2.blockNumber - 1, blockTimestamp: 0},
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (dc2.contractAddress, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.add(
//         dcId2,
//         [dc2.contractAddress],
//       ),
//       fetchedEventQueue: [],
//       id: FetchState.makeDynamicContractRegisterId(dcId2),
//     }

//     Assert.deepEqual(
//       root.registers,
//       [expected1, expected2, rootRegister],
//       ~message="2nd registration",
//     )

//     let dc3 = makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=60)
//     let dcId3 = getDynContractId(dc3)

//     let root = root->FetchState.registerDynamicContract(
//       {
//         {
//           registeringEventBlockNumber: dc3.registeringEventBlockNumber,
//           registeringEventLogIndex: dc3.registeringEventLogIndex,
//           registeringEventChain: ChainMap.Chain.makeUnsafe(~chainId=dc3.chainId),
//           dynamicContracts: [dc3],
//         }
//       },
//       ~isFetchingAtHead=false,
//     )

//     let expected3: FetchState.register = {
//       latestFetchedBlock: {blockNumber: dcId3.blockNumber - 1, blockTimestamp: 0},
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (dc3.contractAddress, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.add(
//         dcId3,
//         [dc3.contractAddress],
//       ),
//       fetchedEventQueue: [],
//       id: FetchState.makeDynamicContractRegisterId(dcId3),
//     }

//     Assert.deepEqual(
//       root.registers,
//       [expected1, expected2, expected3, rootRegister],
//       ~message="3rd registration",
//     )
//   })

//   let mockEvent = (~blockNumber, ~logIndex=0, ~chainId=1): Internal.eventItem => {
//     timestamp: blockNumber * 15,
//     chain: ChainMap.Chain.makeUnsafe(~chainId),
//     blockNumber,
//     logIndex,
//     eventName: "MockEvent",
//     contractName: "MockContract",
//     handler: None,
//     loader: None,
//     contractRegister: None,
//     paramsRawEventSchema: Utils.magic("Mock event paramsRawEventSchema in fetchstate test"),
//     event: Utils.magic("Mock event in fetchstate test"),
//   }

//   it("merge next register", () => {
//     let dcId: FetchState.dynamicContractId = {blockNumber: 100, logIndex: 0}
//     let latestFetchedBlock = getBlockData(~blockNumber=500)

//     let register0: FetchState.register = {
//       latestFetchedBlock,
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty,
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=2),
//         mockEvent(~blockNumber=4),
//         mockEvent(~blockNumber=1, ~logIndex=1),
//       ],
//       id: FetchState.rootRegisterId,
//     }
//     let register1: FetchState.register = {
//       latestFetchedBlock,
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress2, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.add(
//         dcId,
//         [mockAddress2],
//       ),
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=1),
//         mockEvent(~blockNumber=5),
//         mockEvent(~blockNumber=1, ~logIndex=2),
//       ],
//       id: FetchState.makeDynamicContractRegisterId(dcId),
//     }

//     let fetchState: FetchState.t = {
//       partitionId: 0,
//       responseCount: 0,
//       registers: [register0, register1],
//       mostBehindRegister: register0,
//       nextMostBehindRegister: Some(register1),
//       pendingDynamicContracts: [],
//       isFetchingAtHead: false,
//     }

//     let expected: FetchState.register = {
//       latestFetchedBlock,
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress2, (Gravatar :> string)),
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.add(
//         dcId,
//         [mockAddress2],
//       ),
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=2),
//         mockEvent(~blockNumber=6, ~logIndex=1),
//         mockEvent(~blockNumber=5),
//         mockEvent(~blockNumber=4),
//         mockEvent(~blockNumber=1, ~logIndex=2),
//         mockEvent(~blockNumber=1, ~logIndex=1),
//       ],
//       id: FetchState.rootRegisterId,
//     }

//     Assert.deepEqual(
//       fetchState->FetchState.updateInternal,
//       {
//         partitionId: 0,
//         responseCount: 0,
//         registers: [expected],
//         mostBehindRegister: expected,
//         nextMostBehindRegister: None,
//         pendingDynamicContracts: [],
//         isFetchingAtHead: false,
//       },
//     )
//   })

//   it("Sets fetchState to fetching at head on setFetchedItems call", () => {
//     let currentEvents = [
//       mockEvent(~blockNumber=4),
//       mockEvent(~blockNumber=1, ~logIndex=2),
//       mockEvent(~blockNumber=1, ~logIndex=1),
//     ]
//     let register: FetchState.register = {
//       latestFetchedBlock: getBlockData(~blockNumber=500),
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: Some(1),
//       dynamicContracts: FetchState.DynamicContractsMap.empty,
//       fetchedEventQueue: currentEvents,
//       id: FetchState.rootRegisterId,
//     }

//     let fetchState = [register]->makeMockFetchState

//     let newItems = [
//       mockEvent(~blockNumber=5),
//       mockEvent(~blockNumber=6, ~logIndex=1),
//       mockEvent(~blockNumber=6, ~logIndex=2),
//     ]
//     let updatedFetchState =
//       fetchState
//       ->FetchState.setFetchedItems(
//         ~id=FetchState.rootRegisterId,
//         ~latestFetchedBlock=getBlockData(~blockNumber=600),
//         ~currentBlockHeight=600,
//         ~newItems,
//       )
//       ->Utils.unwrapResultExn

//     Assert.deepEqual(
//       updatedFetchState,
//       [
//         {
//           ...register,
//           latestFetchedBlock: getBlockData(~blockNumber=600),
//           fetchedEventQueue: Array.concat(newItems->Array.reverse, currentEvents),
//         },
//       ]->makeMockFetchState(~isFetchingAtHead=true, ~responseCount=1),
//     )
//   })

//   it("Doesn't set fetchState to fetching at head on setFetchedItems call", () => {
//     let dcId: FetchState.dynamicContractId = {blockNumber: 100, logIndex: 0}
//     let register: FetchState.register = {
//       latestFetchedBlock: getBlockData(~blockNumber=500),
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress2, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.add(
//         dcId,
//         [mockAddress2],
//       ),
//       fetchedEventQueue: [],
//       id: FetchState.makeDynamicContractRegisterId(dcId),
//     }

//     let fetchState = [register]->makeMockFetchState(~isFetchingAtHead=false)

//     let newItems = [
//       mockEvent(~blockNumber=5),
//       mockEvent(~blockNumber=6, ~logIndex=1),
//       mockEvent(~blockNumber=6, ~logIndex=2),
//     ]
//     let updatedFetchState =
//       fetchState
//       ->FetchState.setFetchedItems(
//         ~id=FetchState.makeDynamicContractRegisterId(dcId),
//         ~latestFetchedBlock=getBlockData(~blockNumber=500),
//         ~currentBlockHeight=600,
//         ~newItems,
//       )
//       ->Utils.unwrapResultExn

//     Assert.deepEqual(
//       updatedFetchState,
//       [
//         {
//           ...register,
//           fetchedEventQueue: newItems->Array.reverse,
//           firstEventBlockNumber: Some(5),
//         },
//       ]->makeMockFetchState(~isFetchingAtHead=false, ~responseCount=1),
//       ~message="Should not set fetchState to fetching at head",
//     )
//   })

//   it("getEarliest event", () => {
//     let dcId: FetchState.dynamicContractId = {blockNumber: 100, logIndex: 0}
//     let latestFetchedBlock = getBlockData(~blockNumber=500)

//     let register1: FetchState.register = {
//       latestFetchedBlock,
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty,
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=2),
//         mockEvent(~blockNumber=4),
//         mockEvent(~blockNumber=1, ~logIndex=1),
//       ],
//       id: FetchState.rootRegisterId,
//     }
//     let register2: FetchState.register = {
//       latestFetchedBlock,
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress2, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.add(
//         dcId,
//         [mockAddress2],
//       ),
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=1),
//         mockEvent(~blockNumber=5),
//         mockEvent(~blockNumber=1, ~logIndex=2),
//       ],
//       id: FetchState.makeDynamicContractRegisterId(dcId),
//     }

//     let fetchState = [register1, register2]->makeMockFetchState

//     let earliestQueueItem = fetchState->FetchState.getEarliestEvent->getItem->Option.getExn

//     Assert.deepEqual(earliestQueueItem, mockEvent(~blockNumber=1, ~logIndex=1))
//   })

//   it("getEarliestEvent accounts for pending dynamicContracts", () => {
//     let baseRegister: FetchState.register = {
//       latestFetchedBlock: {
//         blockNumber: 500,
//         blockTimestamp: 500 * 15,
//       },
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty,
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=106, ~logIndex=1),
//         mockEvent(~blockNumber=105),
//         mockEvent(~blockNumber=101, ~logIndex=2),
//       ],
//       id: FetchState.rootRegisterId,
//     }
//     let dynamicContractRegistration: FetchState.dynamicContractRegistration = {
//       registeringEventBlockNumber: 100,
//       registeringEventLogIndex: 0,
//       registeringEventChain: ChainMap.Chain.makeUnsafe(~chainId=1),
//       dynamicContracts: [],
//     }

//     let fetchState: FetchState.t = {
//       ...[baseRegister]->makeMockFetchState,
//       pendingDynamicContracts: [dynamicContractRegistration],
//     }
//     let earliestQueueItem = fetchState->FetchState.getEarliestEvent

//     Assert.deepEqual(
//       earliestQueueItem,
//       NoItem({
//         blockNumber: dynamicContractRegistration.registeringEventBlockNumber - 1,
//         blockTimestamp: 0,
//       }),
//       ~message="Should account for pending dynamicContracts earliest registering event",
//     )
//   })

//   it("isReadyForNextQuery standard", () => {
//     let baseRegister: FetchState.register = {
//       latestFetchedBlock: {
//         blockNumber: 500,
//         blockTimestamp: 500 * 15,
//       },
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty,
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=1),
//         mockEvent(~blockNumber=5),
//         mockEvent(~blockNumber=1, ~logIndex=2),
//       ],
//       id: FetchState.rootRegisterId,
//     }
//     let fetchState = [baseRegister]->makeMockFetchState

//     Assert.ok(
//       fetchState->FetchState.isReadyForNextQuery(~maxQueueSize=10),
//       ~message="Should be ready for next query when under max queue size",
//     )

//     Assert.ok(
//       !(fetchState->FetchState.isReadyForNextQuery(~maxQueueSize=3)),
//       ~message="Should not be ready for next query when at max queue size",
//     )
//   })

//   it(
//     "isReadyForNextQuery when cummulatively over max queue size but dynamic contract is under",
//     () => {
//       let register1: FetchState.register = {
//         latestFetchedBlock: {
//           blockNumber: 500,
//           blockTimestamp: 500 * 15,
//         },
//         contractAddressMapping: ContractAddressingMap.fromArray([
//           (mockAddress1, (Gravatar :> string)),
//         ]),
//         firstEventBlockNumber: None,
//         dynamicContracts: FetchState.DynamicContractsMap.empty,
//         fetchedEventQueue: [
//           mockEvent(~blockNumber=6, ~logIndex=1),
//           mockEvent(~blockNumber=5),
//           mockEvent(~blockNumber=4, ~logIndex=2),
//         ],
//         id: FetchState.rootRegisterId,
//       }
//       let register2: FetchState.register = {
//         id: FetchState.makeDynamicContractRegisterId({blockNumber: 100, logIndex: 0}),
//         latestFetchedBlock: {
//           blockNumber: 500,
//           blockTimestamp: 500 * 15,
//         },
//         contractAddressMapping: ContractAddressingMap.fromArray([
//           (mockAddress2, (Gravatar :> string)),
//         ]),
//         firstEventBlockNumber: None,
//         dynamicContracts: FetchState.DynamicContractsMap.empty,
//         fetchedEventQueue: [
//           mockEvent(~blockNumber=3, ~logIndex=2),
//           mockEvent(~blockNumber=2),
//           mockEvent(~blockNumber=1, ~logIndex=1),
//         ],
//       }

//       let fetchState = [register1, register2]->makeMockFetchState

//       Assert.equal(
//         fetchState->FetchState.queueSize,
//         6,
//         ~message="Should have 6 items total in queue",
//       )

//       Assert.ok(
//         fetchState->FetchState.isReadyForNextQuery(~maxQueueSize=5),
//         ~message="Should be ready for next query when base register is under max queue size",
//       )
//     },
//   )

//   it("isReadyForNextQuery when containing pending dynamic contracts", () => {
//     let baseRegister: FetchState.register = {
//       latestFetchedBlock: {
//         blockNumber: 500,
//         blockTimestamp: 500 * 15,
//       },
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty,
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=1),
//         mockEvent(~blockNumber=5),
//         mockEvent(~blockNumber=1, ~logIndex=2),
//       ],
//       id: FetchState.rootRegisterId,
//     }
//     let dynamicContractRegistration: FetchState.dynamicContractRegistration = {
//       registeringEventBlockNumber: 100,
//       registeringEventLogIndex: 0,
//       registeringEventChain: ChainMap.Chain.makeUnsafe(~chainId=1),
//       dynamicContracts: [],
//     }

//     let fetchStateWithoutPendingDynamicContracts = [baseRegister]->makeMockFetchState

//     Assert.ok(
//       !(fetchStateWithoutPendingDynamicContracts->FetchState.isReadyForNextQuery(~maxQueueSize=3)),
//       ~message="Should not be ready for next query when base register is at the max queue size",
//     )

//     let fetchStateWithPendingDynamicContracts = {
//       ...fetchStateWithoutPendingDynamicContracts,
//       pendingDynamicContracts: [dynamicContractRegistration],
//     }

//     Assert.ok(
//       fetchStateWithPendingDynamicContracts->FetchState.isReadyForNextQuery(~maxQueueSize=3),
//       ~message="Should be ready for next query when base register is at the max queue size but contains pending dynamic contracts",
//     )
//   })

//   it("getNextQuery", () => {
//     let latestFetchedBlock = getBlockData(~blockNumber=500)
//     let root: FetchState.register = {
//       latestFetchedBlock,
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty,
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=2),
//         mockEvent(~blockNumber=4),
//         mockEvent(~blockNumber=1, ~logIndex=1),
//       ],
//       id: FetchState.rootRegisterId,
//     }

//     let fetchState = [root]->makeMockFetchState

//     Assert.deepEqual(
//       fetchState->FetchState.getNextQuery(~endBlock=None),
//       Some(
//         PartitionQuery({
//           fetchStateRegisterId: FetchState.rootRegisterId,
//           idempotencyKey: 0,
//           partitionId: 0,
//           fromBlock: root.latestFetchedBlock.blockNumber + 1,
//           toBlock: None,
//           contractAddressMapping: root.contractAddressMapping,
//         }),
//       ),
//     )

//     let endblockCase = [
//       {
//         ...root,
//         latestFetchedBlock: {
//           blockNumber: 500,
//           blockTimestamp: 0,
//         },
//         fetchedEventQueue: [],
//         id: FetchState.rootRegisterId,
//       },
//     ]->makeMockFetchState

//     let nextQuery = endblockCase->FetchState.getNextQuery(~endBlock=Some(500))

//     Assert.deepEqual(nextQuery, None)
//   })

//   it("check contains contract address", () => {
//     let dcId: FetchState.dynamicContractId = {blockNumber: 100, logIndex: 0}
//     let latestFetchedBlock = getBlockData(~blockNumber=500)

//     let register1: FetchState.register = {
//       latestFetchedBlock,
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty,
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=2),
//         mockEvent(~blockNumber=4),
//         mockEvent(~blockNumber=1, ~logIndex=1),
//       ],
//       id: FetchState.rootRegisterId,
//     }
//     let register2: FetchState.register = {
//       latestFetchedBlock,
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress2, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.add(
//         dcId,
//         [mockAddress2],
//       ),
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=1),
//         mockEvent(~blockNumber=5),
//         mockEvent(~blockNumber=1, ~logIndex=2),
//       ],
//       id: FetchState.makeDynamicContractRegisterId(dcId),
//     }

//     let fetchState = [register1, register2]->makeMockFetchState

//     Assert.equal(
//       fetchState->FetchState.checkContainsRegisteredContractAddress(
//         ~contractAddress=mockAddress1,
//         ~contractName=(Gravatar :> string),
//         ~chainId=1,
//       ),
//       true,
//     )
//   })

//   it("isActively indexing", () => {
//     let case1: FetchState.register = {
//       latestFetchedBlock: getBlockData(~blockNumber=150),
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty,
//       fetchedEventQueue: [mockEvent(~blockNumber=140), mockEvent(~blockNumber=99)],
//       id: FetchState.rootRegisterId,
//     }

//     [case1]
//     ->makeMockFetchState
//     ->FetchState.isActivelyIndexing(~endBlock=Some(150))
//     ->Assert.equal(true, ~message="Should be actively indexing with fetchedEventQueue")

//     let registerWithoutQueue = {
//       ...case1,
//       fetchedEventQueue: [],
//     }

//     [registerWithoutQueue]
//     ->makeMockFetchState
//     ->FetchState.isActivelyIndexing(~endBlock=Some(150))
//     ->Assert.equal(false, ~message="When there's an endBlock and no queue, it should return false")

//     let case3 = [
//       registerWithoutQueue,
//       {
//         ...registerWithoutQueue,
//         id: FetchState.makeDynamicContractRegisterId({blockNumber: 100, logIndex: 0}),
//       },
//     ]

//     case3
//     ->makeMockFetchState
//     ->FetchState.isActivelyIndexing(~endBlock=Some(150))
//     ->Assert.equal(
//       false,
//       ~message="It doesn't matter if there are multiple not merged registers, if they don't have a queue and caught up to the endBlock, treat them as not active",
//     )

//     case3
//     ->makeMockFetchState(
//       ~pendingDynamicContracts=[
//         {
//           registeringEventBlockNumber: 200,
//           registeringEventLogIndex: 0,
//           registeringEventChain: ChainMap.Chain.makeUnsafe(~chainId=1),
//           dynamicContracts: [],
//         },
//       ],
//     )
//     ->FetchState.isActivelyIndexing(~endBlock=Some(150))
//     ->Assert.equal(
//       true,
//       ~message="But should be true with a pending dynamic contract, even if the registeringEventBlockNumber more than the endBlock (no reason for this, just snapshot the current logic)",
//     )

//     [registerWithoutQueue]
//     ->makeMockFetchState
//     ->FetchState.isActivelyIndexing(~endBlock=Some(151))
//     ->Assert.equal(true)

//     [registerWithoutQueue]
//     ->makeMockFetchState
//     ->FetchState.isActivelyIndexing(~endBlock=None)
//     ->Assert.equal(true)
//   })

//   it("rolls back", () => {
//     let dcId1: FetchState.dynamicContractId = {blockNumber: 100, logIndex: 0}
//     let dcId2: FetchState.dynamicContractId = {blockNumber: 101, logIndex: 0}

//     let register1: FetchState.register = {
//       latestFetchedBlock: getBlockData(~blockNumber=150),
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty,
//       fetchedEventQueue: [mockEvent(~blockNumber=140), mockEvent(~blockNumber=99)],
//       id: FetchState.rootRegisterId,
//     }

//     let register2: FetchState.register = {
//       latestFetchedBlock: getBlockData(~blockNumber=120),
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress3, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.add(
//         dcId2,
//         [mockAddress3],
//       ),
//       fetchedEventQueue: [mockEvent(~blockNumber=110)],
//       id: FetchState.makeDynamicContractRegisterId(dcId2),
//     }

//     let register3: FetchState.register = {
//       latestFetchedBlock: getBlockData(~blockNumber=99),
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress2, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.add(
//         dcId1,
//         [mockAddress2],
//       ),
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=1),
//         mockEvent(~blockNumber=5),
//         mockEvent(~blockNumber=1, ~logIndex=2),
//       ],
//       id: FetchState.makeDynamicContractRegisterId(dcId1),
//     }

//     let fetchState = [register3, register2, register1]->makeMockFetchState

//     let updated =
//       fetchState->FetchState.rollback(
//         ~lastScannedBlock=getBlockData(~blockNumber=100),
//         ~firstChangeEvent={blockNumber: 101, logIndex: 0},
//       )

//     Assert.deepEqual(
//       updated,
//       [
//         register3,
//         {
//           ...register1,
//           latestFetchedBlock: getBlockData(~blockNumber=100),
//           fetchedEventQueue: [mockEvent(~blockNumber=99)],
//         },
//       ]->makeMockFetchState,
//       ~message="should have removed the second register and rolled back the others",
//     )
//   })

//   it("counts number of contracts correctly", () => {
//     let dcId: FetchState.dynamicContractId = {blockNumber: 100, logIndex: 0}
//     let latestFetchedBlock = getBlockData(~blockNumber=500)

//     let register1: FetchState.register = {
//       latestFetchedBlock,
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress1, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty,
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=2),
//         mockEvent(~blockNumber=4),
//         mockEvent(~blockNumber=1, ~logIndex=1),
//       ],
//       id: FetchState.rootRegisterId,
//     }
//     let register2: FetchState.register = {
//       latestFetchedBlock,
//       contractAddressMapping: ContractAddressingMap.fromArray([
//         (mockAddress2, (Gravatar :> string)),
//       ]),
//       firstEventBlockNumber: None,
//       dynamicContracts: FetchState.DynamicContractsMap.empty->FetchState.DynamicContractsMap.add(
//         dcId,
//         [mockAddress2],
//       ),
//       fetchedEventQueue: [
//         mockEvent(~blockNumber=6, ~logIndex=1),
//         mockEvent(~blockNumber=5),
//         mockEvent(~blockNumber=1, ~logIndex=2),
//       ],
//       id: FetchState.makeDynamicContractRegisterId(dcId),
//     }

//     [register1, register2]->makeMockFetchState->FetchState.getNumContracts->Assert.equal(2)
//   })

//   it(
//     "Adding dynamic between two registers while query is mid flight does no result in early merged registers",
//     () => {
//       let currentBlockHeight = 600
//       let chainId = 1
//       let chain = ChainMap.Chain.makeUnsafe(~chainId)

//       let rootRegister: FetchState.register = {
//         latestFetchedBlock: getBlockData(~blockNumber=500),
//         contractAddressMapping: ContractAddressingMap.fromArray([
//           (mockAddress1, (Gravatar :> string)),
//         ]),
//         firstEventBlockNumber: None,
//         dynamicContracts: FetchState.DynamicContractsMap.empty,
//         fetchedEventQueue: [
//           mockEvent(~blockNumber=6, ~logIndex=2),
//           mockEvent(~blockNumber=4),
//           mockEvent(~blockNumber=1, ~logIndex=1),
//         ],
//         id: FetchState.rootRegisterId,
//       }

//       let mockFetchState = [rootRegister]->makeMockFetchState

//       //Dynamic contract  A registered at block 100
//       let withRegisteredDynamicContractA = mockFetchState->FetchState.registerDynamicContract(
//         {
//           registeringEventChain: chain,
//           registeringEventBlockNumber: 100,
//           registeringEventLogIndex: 0,
//           dynamicContracts: ["MockDynamicContractA"->Utils.magic],
//         },
//         ~isFetchingAtHead=false,
//       )

//       let withAddedDynamicContractRegisterA = withRegisteredDynamicContractA
//       //Received query
//       let queryA = switch withAddedDynamicContractRegisterA->FetchState.getNextQuery(
//         ~endBlock=None,
//       ) {
//       | Some(PartitionQuery(queryA)) =>
//         switch queryA {
//         | {fetchStateRegisterId, fromBlock: 100, toBlock: Some(500)}
//           if fetchStateRegisterId ===
//             FetchState.makeDynamicContractRegisterId({blockNumber: 100, logIndex: 0}) => queryA
//         | query =>
//           Js.log2("unexpected queryA", query)
//           Assert.fail(
//             "Should have returned a query from new contract register from the registering block number to the next register latest block",
//           )
//         }
//       | nextQuery =>
//         Js.log2("nextQueryA res", nextQuery)
//         Js.Exn.raiseError(
//           "Should have returned a query with updated fetch state applying dynamic contracts",
//         )
//       }

//       //Next registration happens at block 200, between the first register and the upperbound of it's query
//       let withRegisteredDynamicContractB =
//         withAddedDynamicContractRegisterA->FetchState.registerDynamicContract(
//           {
//             registeringEventChain: chain,
//             registeringEventBlockNumber: 200,
//             registeringEventLogIndex: 0,
//             dynamicContracts: ["MockDynamicContractB"->Utils.magic],
//           },
//           ~isFetchingAtHead=false,
//         )

//       //Response with updated fetch state
//       let updatesWithResponseFromQueryA =
//         withRegisteredDynamicContractB
//         ->FetchState.setFetchedItems(
//           ~id=queryA.fetchStateRegisterId,
//           ~latestFetchedBlock=getBlockData(~blockNumber=400),
//           ~currentBlockHeight,
//           ~newItems=[],
//         )
//         ->Utils.unwrapResultExn

//       switch updatesWithResponseFromQueryA->FetchState.getNextQuery(~endBlock=None) {
//       | Some(PartitionQuery({fetchStateRegisterId, fromBlock: 200, toBlock: Some(400)}))
//         if fetchStateRegisterId ===
//           FetchState.makeDynamicContractRegisterId({blockNumber: 200, logIndex: 0}) => ()
//       | nextQuery =>
//         Js.log2("nextQueryB res", nextQuery)
//         Assert.fail(
//           "Should have returned query using registered contract B, from it's registering block to the last block fetched in query A",
//         )
//       }
//     },
//   )
// })
