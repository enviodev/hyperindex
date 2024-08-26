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
})
