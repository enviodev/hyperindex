open Belt
open RescriptMocha
open Enums.ContractType

let getItem = (item: FetchState.queueItem) =>
  switch item {
  | Item({item}) => item->Some
  | NoItem(_) => None
  }

let mockAddress0 = TestHelpers.Addresses.mockAddresses[0]->Option.getExn
let mockAddress1 = TestHelpers.Addresses.mockAddresses[1]->Option.getExn
let mockAddress2 = TestHelpers.Addresses.mockAddresses[2]->Option.getExn
let mockAddress3 = TestHelpers.Addresses.mockAddresses[3]->Option.getExn
let mockAddress4 = TestHelpers.Addresses.mockAddresses[4]->Option.getExn
let mockAddress5 = TestHelpers.Addresses.mockAddresses[5]->Option.getExn
let mockFactoryAddress = TestHelpers.Addresses.mockAddresses[6]->Option.getExn

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
    isPreRegistered: false,
  }
}

let getDynContractId = (
  {registeringEventBlockNumber, registeringEventLogIndex}: TablesStatic.DynamicContractRegistry.t,
): FetchState.dynamicContractId => {
  blockNumber: registeringEventBlockNumber,
  logIndex: registeringEventLogIndex,
}

let mockEvent = (~blockNumber, ~logIndex=0, ~chainId=1): Internal.eventItem => {
  timestamp: blockNumber * 15,
  chain: ChainMap.Chain.makeUnsafe(~chainId),
  blockNumber,
  eventConfig: Utils.magic("Mock eventConfig in fetchstate test"),
  logIndex,
  event: Utils.magic("Mock event in fetchstate test"),
}

let makeInitial = (~startBlock=0) => {
  FetchState.make(
    ~eventConfigs=[
      {
        contractName: "Gravatar",
        eventId: "0",
        isWildcard: false,
      },
    ],
    ~staticContracts=Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
    ~dynamicContracts=[],
    ~startBlock,
    ~endBlock=None,
    ~maxAddrInPartition=3,
  )
}

describe("FetchState.make", () => {
  it("Creates FetchState with a single static address", () => {
    let fetchState = makeInitial()

    Assert.deepEqual(
      fetchState,
      {
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 0,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress0, "Gravatar")]),
            dynamicContracts: [],
            fetchedEventQueue: [],
          },
        ],
        endBlock: None,
        nextPartitionIndex: 1,
        isFetchingAtHead: false,
        maxAddrInPartition: 3,
        latestFullyFetchedBlock: {
          blockNumber: 0,
          blockTimestamp: 0,
        },
        queueSize: 0,
        firstEventBlockNumber: None,
        normalSelection: fetchState.normalSelection,
      },
    )
  })

  it("Panics with nothing to fetch", () => {
    Assert.throws(
      () => {
        FetchState.make(
          ~eventConfigs=[
            {
              contractName: "Gravatar",
              eventId: "0",
              isWildcard: false,
            },
          ],
          ~staticContracts=Js.Dict.empty(),
          ~dynamicContracts=[],
          ~startBlock=0,
          ~endBlock=None,
          ~maxAddrInPartition=2,
        )
      },
      ~error={
        "message": "Invalid configuration: Nothing to fetch. Make sure that you provided at least one contract address to index, or have events with Wildcard mode enabled.",
      },
      ~message=`Should panic if there's nothing to fetch`,
    )
  })

  it(
    "Creates FetchState with static and dc addresses reaching the maxAddrInPartition limit",
    () => {
      let dc = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress2)
      let fetchState = FetchState.make(
        ~eventConfigs=[
          {
            contractName: "Gravatar",
            eventId: "0",
            isWildcard: false,
          },
        ],
        ~staticContracts=Js.Dict.fromArray([("Gravatar", [mockAddress1])]),
        ~dynamicContracts=[dc],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=2,
      )

      Assert.deepEqual(
        fetchState,
        {
          partitions: [
            {
              id: "0",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress1, "Gravatar"),
                (mockAddress2, "Gravatar"),
              ]),
              dynamicContracts: [dc],
              fetchedEventQueue: [],
            },
          ],
          nextPartitionIndex: 1,
          isFetchingAtHead: false,
          maxAddrInPartition: 2,
          latestFullyFetchedBlock: {
            blockNumber: 0,
            blockTimestamp: 0,
          },
          queueSize: 0,
          endBlock: None,
          firstEventBlockNumber: None,
          normalSelection: fetchState.normalSelection,
        },
        ~message=`Should create only one partition`,
      )
    },
  )

  it(
    "Creates FetchState with static addresses and dc addresses exceeding the maxAddrInPartition limit",
    () => {
      let dc = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress2)
      let fetchState = FetchState.make(
        ~eventConfigs=[
          {
            contractName: "ContractA",
            eventId: "0",
            isWildcard: false,
          },
          {
            contractName: "Gravatar",
            eventId: "0",
            isWildcard: false,
          },
        ],
        ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress1])]),
        ~dynamicContracts=[dc],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=1,
      )

      Assert.deepEqual(
        fetchState,
        {
          partitions: [
            {
              id: "0",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress1, "ContractA"),
              ]),
              dynamicContracts: [],
              fetchedEventQueue: [],
            },
            {
              id: "1",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress2, "Gravatar")]),
              dynamicContracts: [dc],
              fetchedEventQueue: [],
            },
          ],
          nextPartitionIndex: 2,
          isFetchingAtHead: false,
          maxAddrInPartition: 1,
          latestFullyFetchedBlock: {
            blockNumber: 0,
            blockTimestamp: 0,
          },
          queueSize: 0,
          endBlock: None,
          firstEventBlockNumber: None,
          normalSelection: fetchState.normalSelection,
        },
      )

      Assert.equal(
        (fetchState.partitions->Js.Array2.unsafe_get(0)).selection,
        (fetchState.partitions->Js.Array2.unsafe_get(1)).selection,
        ~message=`Selection should be the same instance for all partitions,
        so the WeakMap cache works correctly.`,
      )
    },
  )

  it(
    "Creates FetchState with static and dc addresses exceeding the maxAddrInPartition limit",
    () => {
      let dc1 = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress3)
      let dc2 = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress4)
      let fetchState = FetchState.make(
        ~eventConfigs=[
          {
            contractName: "ContractA",
            eventId: "0",
            isWildcard: false,
          },
          {
            contractName: "Gravatar",
            eventId: "0",
            isWildcard: false,
          },
        ],
        ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress1, mockAddress2])]),
        ~dynamicContracts=[dc1, dc2],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=1,
      )

      Assert.deepEqual(
        fetchState,
        {
          partitions: [
            {
              id: "0",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress1, "ContractA"),
              ]),
              dynamicContracts: [],
              fetchedEventQueue: [],
            },
            {
              id: "1",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress2, "ContractA"),
              ]),
              dynamicContracts: [],
              fetchedEventQueue: [],
            },
            {
              id: "2",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress3, "Gravatar")]),
              dynamicContracts: [dc1],
              fetchedEventQueue: [],
            },
            {
              id: "3",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress4, "Gravatar")]),
              dynamicContracts: [dc2],
              fetchedEventQueue: [],
            },
          ],
          nextPartitionIndex: 4,
          isFetchingAtHead: false,
          maxAddrInPartition: 1,
          latestFullyFetchedBlock: {
            blockNumber: 0,
            blockTimestamp: 0,
          },
          queueSize: 0,
          firstEventBlockNumber: None,
          endBlock: None,
          normalSelection: fetchState.normalSelection,
        },
      )
    },
  )
})

describe("FetchState.registerDynamicContracts", () => {
  // It shouldn't happen, but just in case
  it("Nothing breaks when provided an empty array", () => {
    let fetchState = makeInitial()

    Assert.deepEqual(
      fetchState->FetchState.registerDynamicContracts([], ~currentBlockHeight=0),
      {
        ...fetchState,
        // Should only update isFetchingAtHead
        isFetchingAtHead: true,
      },
    )
  })

  it(
    "Dcs with the same start block are grouped in a single partition. But don't merged with an existing one",
    () => {
      let fetchState = makeInitial()

      let dc1 = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress1)
      let dc2 = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress2)
      let dc3 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress3)

      Assert.deepEqual(
        // Order of dcs doesn't matter
        fetchState->FetchState.registerDynamicContracts([dc1, dc3, dc2], ~currentBlockHeight=10),
        {
          ...fetchState,
          nextPartitionIndex: 3,
          partitions: fetchState.partitions->Array.concat([
            {
              id: "1",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress1, "Gravatar"),
                (mockAddress2, "Gravatar"),
              ]),
              dynamicContracts: [dc1, dc2],
              fetchedEventQueue: [],
            },
            {
              id: "2",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 1,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress3, "Gravatar")]),
              dynamicContracts: [dc3],
              fetchedEventQueue: [],
            },
          ]),
        },
      )
    },
  )

  it(
    "Creates FetchState with wildcard and normal events. Addresses not belonging to event configs should be skipped (pre-registration case)",
    () => {
      let fetchState = FetchState.make(
        ~eventConfigs=[
          {
            eventId: "wildcard1",
            contractName: "Gravatar",
            isWildcard: true,
          },
          {
            eventId: "wildcard2",
            contractName: "Gravatar",
            isWildcard: true,
          },
          {
            eventId: "normal1",
            contractName: "NftFactory",
            isWildcard: false,
          },
        ],
        ~staticContracts=Js.Dict.fromArray([
          ("NftFactory", [mockAddress0, mockAddress1]),
          ("Gravatar", [mockAddress2, mockAddress3]),
        ]),
        ~dynamicContracts=[
          makeDynContractRegistration(
            ~contractType=Gravatar,
            ~blockNumber=0,
            ~contractAddress=mockAddress4,
          ),
          makeDynContractRegistration(
            ~contractType=NftFactory,
            ~blockNumber=0,
            ~contractAddress=mockAddress5,
          ),
        ],
        ~endBlock=None,
        ~startBlock=0,
        ~maxAddrInPartition=1000,
      )

      Assert.deepEqual(
        fetchState,
        {
          partitions: [
            {
              id: "0",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              selection: {
                isWildcard: true,
                eventConfigs: [
                  {
                    eventId: "wildcard1",
                    contractName: "Gravatar",
                    isWildcard: true,
                  },
                  {
                    eventId: "wildcard2",
                    contractName: "Gravatar",
                    isWildcard: true,
                  },
                ],
              },
              contractAddressMapping: ContractAddressingMap.make(),
              dynamicContracts: [],
              fetchedEventQueue: [],
            },
            {
              id: "1",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress0, "NftFactory"),
                (mockAddress1, "NftFactory"),
                (mockAddress5, "NftFactory"),
              ]),
              dynamicContracts: [
                makeDynContractRegistration(
                  ~contractType=NftFactory,
                  ~blockNumber=0,
                  ~contractAddress=mockAddress5,
                ),
              ],
              fetchedEventQueue: [],
            },
          ],
          endBlock: None,
          nextPartitionIndex: 2,
          isFetchingAtHead: false,
          maxAddrInPartition: 1000,
          latestFullyFetchedBlock: {
            blockNumber: 0,
            blockTimestamp: 0,
          },
          queueSize: 0,
          firstEventBlockNumber: None,
          normalSelection: fetchState.normalSelection,
        },
        ~message=`The static addresses for the Gravatar contract should be skipped, since they don't have non-wildcard event configs`,
      )
    },
  )
})

describe("FetchState.getNextQuery & integration", () => {
  let dc1 = makeDynContractRegistration(~blockNumber=1, ~contractAddress=mockAddress1)
  let dc2 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)
  let dc3 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress3)

  let makeAfterFirstStaticAddressesQuery = (): FetchState.t => {
    let normalSelection: FetchState.selection = {
      isWildcard: false,
      eventConfigs: [
        {
          contractName: "Gravatar",
          eventId: "0",
          isWildcard: false,
        },
      ],
    }
    {
      partitions: [
        {
          id: "0",
          status: {fetchingStateId: None},
          latestFetchedBlock: {
            blockNumber: 10,
            blockTimestamp: 10,
          },
          selection: normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress0, "Gravatar")]),
          dynamicContracts: [],
          fetchedEventQueue: [mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
        },
      ],
      nextPartitionIndex: 1,
      isFetchingAtHead: true,
      maxAddrInPartition: 3,
      latestFullyFetchedBlock: {
        blockNumber: 10,
        blockTimestamp: 10,
      },
      queueSize: 2,
      firstEventBlockNumber: Some(1),
      endBlock: None,
      normalSelection,
    }
  }

  let makeIntermidiateDcMerge = (): FetchState.t => {
    let normalSelection: FetchState.selection = {
      isWildcard: false,
      eventConfigs: [
        {
          contractName: "Gravatar",
          eventId: "0",
          isWildcard: false,
        },
      ],
    }
    {
      partitions: [
        {
          id: "0",
          status: {fetchingStateId: None},
          latestFetchedBlock: {
            blockNumber: 10,
            blockTimestamp: 10,
          },
          selection: normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress0, "Gravatar")]),
          dynamicContracts: [],
          fetchedEventQueue: [mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
        },
        {
          id: "2",
          status: {fetchingStateId: None},
          latestFetchedBlock: {
            blockNumber: 1,
            blockTimestamp: 0,
          },
          selection: normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress2, "Gravatar"),
            (mockAddress3, "Gravatar"),
            (mockAddress1, "Gravatar"),
          ]),
          dynamicContracts: [dc2, dc3, dc1],
          fetchedEventQueue: [],
        },
      ],
      nextPartitionIndex: 3,
      isFetchingAtHead: false,
      maxAddrInPartition: 3,
      latestFullyFetchedBlock: {
        blockNumber: 1,
        blockTimestamp: 0,
      },
      queueSize: 2,
      firstEventBlockNumber: Some(1),
      endBlock: None,
      normalSelection,
    }
  }

  it("Emulate first indexer queris with a static event", () => {
    // The default configuration with ability to overwrite some values
    let getNextQuery = (
      fs,
      ~endBlock=None,
      ~currentBlockHeight=10,
      ~maxQueueSize=10,
      ~concurrencyLimit=10,
    ) =>
      switch endBlock {
      | Some(_) => {...fs, endBlock}
      | None => fs
      }->FetchState.getNextQuery(~currentBlockHeight, ~concurrencyLimit, ~maxQueueSize, ~stateId=0)

    let fetchState = makeInitial()

    Assert.deepEqual(fetchState->getNextQuery(~currentBlockHeight=0), WaitingForNewBlock)

    let nextQuery = fetchState->getNextQuery

    Assert.deepEqual(
      nextQuery,
      Ready([
        {
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress0, "Gravatar")]),
          fromBlock: 0,
        },
      ]),
    )

    let query = switch nextQuery {
    | Ready([q]) => q
    | _ => Assert.fail("Failed to extract query")
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query], ~stateId=0)

    Assert.deepEqual(
      fetchState,
      {
        ...fetchState,
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: Some(0)},
            latestFetchedBlock: {
              blockNumber: 0,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress0, "Gravatar")]),
            dynamicContracts: [],
            fetchedEventQueue: [],
          },
        ],
      },
      ~message="The startFetchingQueries should mutate the isFetching state",
    )

    let repeatedNextQuery = fetchState->getNextQuery

    Assert.deepEqual(
      repeatedNextQuery,
      NothingToQuery,
      ~message="Shouldn't double fetch the same partition",
    )

    let updatedFetchState =
      fetchState
      ->FetchState.setQueryResponse(
        ~query,
        ~latestFetchedBlock={
          blockNumber: 10,
          blockTimestamp: 10,
        },
        ~newItems=[mockEvent(~blockNumber=1), mockEvent(~blockNumber=2)],
        ~currentBlockHeight=10,
      )
      ->Result.getExn

    Assert.deepEqual(updatedFetchState, makeAfterFirstStaticAddressesQuery())

    Assert.deepEqual(updatedFetchState->getNextQuery, WaitingForNewBlock)
    Assert.deepEqual(updatedFetchState->getNextQuery(~concurrencyLimit=0), ReachedMaxConcurrency)
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~endBlock=Some(11)),
      WaitingForNewBlock,
      ~message=`Should wait for new block
      when block height didn't reach the end block`,
    )
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~endBlock=Some(10)),
      NothingToQuery,
      ~message=`Shouldn't wait for new block
      when block height reached the end block`,
    )
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~endBlock=Some(9)),
      NothingToQuery,
      ~message=`Shouldn't wait for new block
      when block height exceeded the end block`,
    )
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~maxQueueSize=2),
      WaitingForNewBlock,
      ~message=`Should wait for new block even if partitions have nothing to query`,
    )
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~maxQueueSize=2, ~currentBlockHeight=11),
      NothingToQuery,
      ~message=`Should do nothing if the case above is not waiting for new block`,
    )

    updatedFetchState->FetchState.startFetchingQueries(~queries=[query], ~stateId=0)
    Assert.deepEqual(
      updatedFetchState->getNextQuery,
      NothingToQuery,
      ~message=`Test that even if all partitions reached the current block height,
      we won't wait for new block while even one partition is fetching.
      It might return an updated currentBlockHeight in response and we won't need to poll for new block`,
    )
  })

  it("Emulate dynamic contract registration", () => {
    // The default configuration with ability to overwrite some values
    let getNextQuery = (
      fs,
      ~endBlock=None,
      ~currentBlockHeight=11,
      ~maxQueueSize=10,
      ~concurrencyLimit=10,
    ) =>
      switch endBlock {
      | Some(_) => {...fs, endBlock}
      | None => fs
      }->FetchState.getNextQuery(~currentBlockHeight, ~concurrencyLimit, ~maxQueueSize, ~stateId=0)

    // Continue with the state from previous test
    let fetchState = makeAfterFirstStaticAddressesQuery()

    let fetchStateWithDcs =
      fetchState->FetchState.registerDynamicContracts([dc2, dc1, dc3], ~currentBlockHeight=11)

    Assert.deepEqual(
      fetchStateWithDcs,
      {
        ...fetchState,
        isFetchingAtHead: false,
        nextPartitionIndex: 3,
        latestFullyFetchedBlock: {
          blockNumber: 0,
          blockTimestamp: 0,
        },
        partitions: fetchState.partitions->Array.concat([
          {
            id: "1",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 0,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "Gravatar")]),
            dynamicContracts: [dc1],
            fetchedEventQueue: [],
          },
          {
            id: "2",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 1,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([
              (mockAddress2, "Gravatar"),
              (mockAddress3, "Gravatar"),
            ]),
            dynamicContracts: [dc2, dc3],
            fetchedEventQueue: [],
          },
        ]),
      },
    )

    Assert.deepEqual(
      fetchStateWithDcs->getNextQuery,
      Ready([
        {
          partitionId: "1",
          target: Merge({
            intoPartitionId: "2",
            toBlock: 1,
          }),
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "Gravatar")]),
          // Should be fromBlock 0, but we have a bug
          fromBlock: 0,
        },
      ]),
    )

    let query = switch fetchStateWithDcs->getNextQuery {
    | Ready([q]) => q
    | _ => Assert.fail("Failed to extract query. The getNextQuery should be idempotent")
    }

    fetchStateWithDcs->FetchState.startFetchingQueries(~queries=[query], ~stateId=0)
    Assert.deepEqual(
      fetchStateWithDcs->getNextQuery,
      NothingToQuery,
      ~message="Locks all partitions, which didn't reach max addr count",
    )

    let updatedFetchState =
      fetchStateWithDcs
      ->FetchState.setQueryResponse(
        ~query,
        ~latestFetchedBlock={
          blockNumber: 1,
          blockTimestamp: 1,
        },
        ~newItems=[],
        ~currentBlockHeight=11,
      )
      ->Result.getExn

    Assert.deepEqual(
      updatedFetchState,
      makeIntermidiateDcMerge(),
      ~message="Should be equal to intermidiate state",
    )

    let expectedPartition2Query: FetchState.query = {
      partitionId: "2",
      fromBlock: 2,
      target: Head,
      selection: fetchState.normalSelection,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, "Gravatar"),
        (mockAddress3, "Gravatar"),
        (mockAddress1, "Gravatar"),
      ]),
    }
    let expectedPartition1Query: FetchState.query = {
      partitionId: "0",
      target: Head,
      selection: fetchState.normalSelection,
      contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress0, "Gravatar")]),
      fromBlock: 11,
    }

    Assert.deepEqual(
      updatedFetchState->getNextQuery(~maxQueueSize=6),
      Ready([expectedPartition2Query, expectedPartition1Query]),
      ~message=`Since the partition "2" reached the maxAddrNumber,
      there's no point to continue merging partitions,
      so we have two queries concurrently`,
    )
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~maxQueueSize=5),
      Ready([expectedPartition2Query]),
      ~message=`Partition queue size is adjusted according to
      the number of fully fetched partitions + 1. In the case it should be 5 / 2 = 2,
      so the partition "0" is skipped`,
    )
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~concurrencyLimit=1),
      Ready([expectedPartition2Query]),
      ~message=`Should be the query with smaller fromBlock`,
    )
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~currentBlockHeight=10),
      Ready([expectedPartition2Query]),
      ~message=`Even if a single partition reached block height,
      we finish fetching other partitions until waiting for the new block first`,
    )

    updatedFetchState->FetchState.startFetchingQueries(
      ~queries=[expectedPartition2Query],
      ~stateId=0,
    )
    Assert.deepEqual(
      updatedFetchState->getNextQuery,
      Ready([expectedPartition1Query]),
      ~message=`Should skip fetching queries`,
    )
  })

  it("Emulate partition merging cases", () => {
    // The default configuration with ability to overwrite some values
    let getNextQuery = (
      fs,
      ~endBlock=None,
      ~currentBlockHeight=11,
      ~maxQueueSize=10,
      ~concurrencyLimit=10,
    ) =>
      switch endBlock {
      | Some(_) => {...fs, endBlock}
      | None => fs
      }->FetchState.getNextQuery(~currentBlockHeight, ~concurrencyLimit, ~maxQueueSize, ~stateId=0)

    // Continue with the state from previous test
    // But increase the maxAddrInPartition up to 4
    let fetchState = {
      ...makeIntermidiateDcMerge(),
      maxAddrInPartition: 4,
    }

    Assert.deepEqual(
      fetchState->getNextQuery,
      Ready([
        {
          partitionId: "2",
          target: Merge({
            intoPartitionId: "0",
            toBlock: 10,
          }),
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress2, "Gravatar"),
            (mockAddress3, "Gravatar"),
            (mockAddress1, "Gravatar"),
          ]),
          fromBlock: 2,
        },
      ]),
    )

    let query = switch fetchState->getNextQuery {
    | Ready([q]) => q
    | _ => Assert.fail("Failed to extract query. The getNextQuery should be idempotent")
    }

    // When it didn't finish fetching to the target partition block
    let fetchStateWithResponse1 =
      fetchState
      ->FetchState.setQueryResponse(
        ~query,
        ~latestFetchedBlock={
          blockNumber: 9,
          blockTimestamp: 9,
        },
        ~newItems=[mockEvent(~blockNumber=4, ~logIndex=2), mockEvent(~blockNumber=4, ~logIndex=6)],
        ~currentBlockHeight=11,
      )
      ->Result.getExn

    Assert.deepEqual(
      fetchStateWithResponse1,
      {
        ...fetchState,
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 10,
              blockTimestamp: 10,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress0, "Gravatar")]),
            dynamicContracts: [],
            fetchedEventQueue: [mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
          },
          {
            id: "2",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 9,
              blockTimestamp: 9,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([
              (mockAddress2, "Gravatar"),
              (mockAddress3, "Gravatar"),
              (mockAddress1, "Gravatar"),
            ]),
            dynamicContracts: [dc2, dc3, dc1],
            fetchedEventQueue: [
              mockEvent(~blockNumber=4, ~logIndex=6),
              mockEvent(~blockNumber=4, ~logIndex=2),
            ],
          },
        ],
        latestFullyFetchedBlock: {
          blockNumber: 9,
          blockTimestamp: 9,
        },
        queueSize: 4,
      },
    )

    Assert.deepEqual(
      fetchStateWithResponse1->getNextQuery(~maxQueueSize=0),
      Ready([
        {
          partitionId: "2",
          target: Merge({
            intoPartitionId: "0",
            toBlock: 10,
          }),
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress2, "Gravatar"),
            (mockAddress3, "Gravatar"),
            (mockAddress1, "Gravatar"),
          ]),
          fromBlock: 10,
        },
      ]),
      ~message="MergeQuery should ignore the maxQueueSize limit",
    )

    let query = switch fetchState->getNextQuery(~maxQueueSize=0) {
    | Ready([q]) => q
    | _ => Assert.fail("Failed to extract query. The getNextQuery should be idempotent")
    }

    let fetchStateWithResponse2 =
      fetchStateWithResponse1
      ->FetchState.setQueryResponse(
        ~query,
        ~latestFetchedBlock={
          blockNumber: 10,
          blockTimestamp: 10,
        },
        ~newItems=[],
        ~currentBlockHeight=11,
      )
      ->Result.getExn
    Assert.deepEqual(
      fetchStateWithResponse2,
      {
        ...fetchStateWithResponse1,
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 10,
              blockTimestamp: 10,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([
              (mockAddress0, "Gravatar"),
              (mockAddress2, "Gravatar"),
              (mockAddress3, "Gravatar"),
              (mockAddress1, "Gravatar"),
            ]),
            dynamicContracts: [dc2, dc3, dc1],
            fetchedEventQueue: [
              mockEvent(~blockNumber=4, ~logIndex=6),
              mockEvent(~blockNumber=4, ~logIndex=2),
              mockEvent(~blockNumber=2),
              mockEvent(~blockNumber=1),
            ],
          },
        ],
        latestFullyFetchedBlock: {
          blockNumber: 10,
          blockTimestamp: 10,
        },
      },
    )

    let fetchStateWithMergeSplit =
      {
        ...fetchStateWithResponse1,
        // Emulate the case when the merging partition
        // should split on merge
        maxAddrInPartition: 2,
      }
      ->FetchState.setQueryResponse(
        ~query,
        ~latestFetchedBlock={
          blockNumber: 10,
          blockTimestamp: 10,
        },
        ~newItems=[],
        ~currentBlockHeight=11,
      )
      ->Result.getExn
    Assert.deepEqual(
      fetchStateWithMergeSplit,
      {
        ...fetchStateWithResponse1,
        maxAddrInPartition: 2,
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 10,
              blockTimestamp: 10,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([
              (mockAddress0, "Gravatar"),
              (mockAddress1, "Gravatar"),
            ]),
            dynamicContracts: [dc1],
            fetchedEventQueue: [
              mockEvent(~blockNumber=4, ~logIndex=6),
              mockEvent(~blockNumber=4, ~logIndex=2),
              mockEvent(~blockNumber=2),
              mockEvent(~blockNumber=1),
            ],
          },
          {
            id: "2",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 10,
              blockTimestamp: 10,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([
              (mockAddress2, "Gravatar"),
              (mockAddress3, "Gravatar"),
            ]),
            dynamicContracts: [dc2, dc3],
            fetchedEventQueue: [],
          },
        ],
        latestFullyFetchedBlock: {
          blockNumber: 10,
          blockTimestamp: 10,
        },
      },
      ~message=`If on merge the target partition exceeds maxAddrsInPartition,
      then it should keep the rest addresses in the merging partition`,
    )
  })

  it("Wildcard partition never merges to another one", () => {
    let fetchState = FetchState.make(
      ~eventConfigs=[
        {
          contractName: "ContractA",
          eventId: "0",
          isWildcard: false,
        },
        {
          contractName: "ContractA",
          eventId: "wildcard",
          isWildcard: true,
        },
      ],
      ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress1])]),
      ~dynamicContracts=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=2,
    )->FetchState.registerDynamicContracts(
      [makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)],
      ~currentBlockHeight=10,
    )

    Assert.deepEqual(fetchState.partitions->Array.length, 3)

    let nextQuery =
      fetchState->FetchState.getNextQuery(
        ~currentBlockHeight=10,
        ~concurrencyLimit=10,
        ~maxQueueSize=10,
        ~stateId=0,
      )

    Assert.deepEqual(
      nextQuery,
      Ready([
        {
          partitionId: "0",
          target: Head,
          selection: {
            isWildcard: true,
            eventConfigs: [
              {
                contractName: "ContractA",
                eventId: "wildcard",
                isWildcard: true,
              },
            ],
          },
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 0,
        },
        {
          partitionId: "1",
          target: Merge({
            intoPartitionId: "2",
            toBlock: 1,
          }),
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "ContractA")]),
          fromBlock: 0,
        },
      ]),
      ~message=`Locks the partition "2" to merge "1", but still performs Wildcard partition "0" in parallel`,
    )
  })

  it("Correctly rollbacks fetch state", () => {
    let fetchState = makeIntermidiateDcMerge()

    let fetchStateAfterRollback1 =
      fetchState->FetchState.rollback(~firstChangeEvent={blockNumber: 2, logIndex: 0})

    Assert.deepEqual(
      fetchStateAfterRollback1,
      {
        ...fetchState,
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 1,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress0, "Gravatar")]),
            dynamicContracts: [],
            // Removed an item here, but kept the partition.
            fetchedEventQueue: [mockEvent(~blockNumber=1)],
          },
          {
            id: "2",
            status: {fetchingStateId: None},
            // Should keep it's own latestFetchedBlock
            latestFetchedBlock: {
              blockNumber: 1,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "Gravatar")]),
            dynamicContracts: [dc1],
            fetchedEventQueue: [],
            // Removed dc2, even though the latestFetchedBlock is not exceeding the lastScannedBlock
          },
        ],
        queueSize: 1,
      },
      ~message=`Should rollback the partition state, but keep them`,
    )

    // Rollback even more to see the removal of partition "2"
    let fetchStateAfterRollback2 =
      fetchStateAfterRollback1->FetchState.rollback(~firstChangeEvent={blockNumber: 0, logIndex: 0})

    Assert.deepEqual(
      fetchStateAfterRollback2,
      {
        ...fetchStateAfterRollback1,
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 0,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress0, "Gravatar")]),
            dynamicContracts: [],
            fetchedEventQueue: [],
          },
        ],
        latestFullyFetchedBlock: {
          blockNumber: 0,
          blockTimestamp: 0,
        },
        queueSize: 0,
      },
      ~message=`Partition "2" should be removed, but the partition "0" should be kept`,
    )
  })

  it("Keeps wildcard partition on rollback", () => {
    let wildcardEventConfigs = [
      {
        FetchState.contractName: "ContractA",
        eventId: "wildcard",
        isWildcard: true,
      },
    ]
    let eventConfigs = [
      ...wildcardEventConfigs,
      {
        FetchState.contractName: "Greeter",
        eventId: "0",
        isWildcard: false,
      },
    ]
    let fetchState =
      FetchState.make(
        ~eventConfigs,
        ~staticContracts=Js.Dict.empty(),
        ~dynamicContracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=3,
      )->FetchState.registerDynamicContracts(
        [makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)],
        ~currentBlockHeight=10,
      )

    // Additionally test that state being reset
    fetchState->FetchState.startFetchingQueries(
      ~queries=[
        {
          partitionId: "0",
          target: Head,
          selection: {
            isWildcard: true,
            eventConfigs: wildcardEventConfigs,
          },
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 0,
        },
      ],
      ~stateId=0,
    )

    Assert.deepEqual(
      fetchState.partitions->Array.length,
      2,
      ~message=`Should have 2 partitions before rollback`,
    )

    let fetchStateAfterRollback =
      fetchState->FetchState.rollback(~firstChangeEvent={blockNumber: 2, logIndex: 0})

    Assert.deepEqual(
      fetchStateAfterRollback,
      {
        ...fetchState,
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 0,
              blockTimestamp: 0,
            },
            selection: {
              isWildcard: true,
              eventConfigs: wildcardEventConfigs,
            },
            contractAddressMapping: ContractAddressingMap.make(),
            dynamicContracts: [],
            fetchedEventQueue: [],
          },
        ],
        queueSize: 0,
      },
      ~message=`Should keep Wildcard partition even if it's empty`,
    )
  })
})

describe("FetchState unit tests for specific cases", () => {
  it("Should merge events in correct order on merging", () => {
    let normalSelection: FetchState.selection = {
      isWildcard: false,
      eventConfigs: [],
    }
    let fetchState: FetchState.t = {
      partitions: [
        {
          id: "0",
          status: {fetchingStateId: None},
          latestFetchedBlock: {
            blockNumber: 10,
            blockTimestamp: 10,
          },
          selection: normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
          dynamicContracts: [],
          fetchedEventQueue: [
            mockEvent(~blockNumber=4, ~logIndex=2),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=2),
          ],
        },
        {
          id: "1",
          status: {fetchingStateId: None},
          latestFetchedBlock: {
            blockNumber: 1,
            blockTimestamp: 0,
          },
          selection: normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
          dynamicContracts: [],
          fetchedEventQueue: [mockEvent(~blockNumber=3), mockEvent(~blockNumber=1)],
        },
      ],
      nextPartitionIndex: 2,
      isFetchingAtHead: false,
      maxAddrInPartition: 2,
      latestFullyFetchedBlock: {
        blockNumber: 1,
        blockTimestamp: 0,
      },
      queueSize: 5,
      firstEventBlockNumber: Some(1),
      endBlock: None,
      normalSelection,
    }

    let updatedFetchState =
      fetchState
      ->FetchState.setQueryResponse(
        ~query={
          partitionId: "1",
          target: Merge({
            intoPartitionId: "0",
            toBlock: 10,
          }),
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 1,
        },
        ~latestFetchedBlock={
          blockNumber: 10,
          blockTimestamp: 10,
        },
        ~currentBlockHeight=11,
        ~newItems=[mockEvent(~blockNumber=4, ~logIndex=1), mockEvent(~blockNumber=4, ~logIndex=1)],
      )
      ->Result.getExn

    Assert.deepEqual(
      updatedFetchState,
      {
        ...fetchState,
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 10,
              blockTimestamp: 10,
            },
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.make(),
            dynamicContracts: [],
            fetchedEventQueue: [
              mockEvent(~blockNumber=4, ~logIndex=2),
              mockEvent(~blockNumber=4, ~logIndex=1),
              mockEvent(~blockNumber=4, ~logIndex=1),
              mockEvent(~blockNumber=4),
              mockEvent(~blockNumber=3),
              mockEvent(~blockNumber=2),
              mockEvent(~blockNumber=1),
            ],
          },
        ],
        latestFullyFetchedBlock: {
          blockNumber: 10,
          blockTimestamp: 10,
        },
        queueSize: 7,
      },
      ~message="Should merge events in correct order",
    )
  })

  it("Shouldn't wait for new block until all partitions reached the head", () => {
    // FetchState with 2 partitions,
    // one of them reached the head
    // another reached max queue size
    let fetchState = FetchState.make(
      ~eventConfigs=[
        {
          contractName: "ContractA",
          eventId: "0",
          isWildcard: false,
        },
        {
          contractName: "ContractA",
          eventId: "wildcard",
          isWildcard: true,
        },
      ],
      ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress0])]),
      ~dynamicContracts=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=2,
    )
    let fetchState =
      fetchState
      ->FetchState.setQueryResponse(
        ~query={
          partitionId: "0",
          target: Head,
          selection: {
            isWildcard: true,
            eventConfigs: [
              {
                contractName: "ContractA",
                eventId: "wildcard",
                isWildcard: true,
              },
            ],
          },
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 0,
        },
        ~latestFetchedBlock=getBlockData(~blockNumber=1),
        ~newItems=[mockEvent(~blockNumber=0), mockEvent(~blockNumber=1)],
        ~currentBlockHeight=2,
      )
      ->Result.getExn
      ->FetchState.setQueryResponse(
        ~query={
          partitionId: "1",
          target: Head,
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 0,
        },
        ~latestFetchedBlock=getBlockData(~blockNumber=2),
        ~newItems=[],
        ~currentBlockHeight=2,
      )
      ->Result.getExn

    Assert.deepEqual(
      fetchState->FetchState.getNextQuery(
        ~concurrencyLimit=10,
        ~currentBlockHeight=2,
        ~maxQueueSize=10,
        ~stateId=0,
      ),
      Ready([
        {
          partitionId: "0",
          target: Head,
          selection: {
            isWildcard: true,
            eventConfigs: [
              {
                contractName: "ContractA",
                eventId: "wildcard",
                isWildcard: true,
              },
            ],
          },
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 2,
        },
      ]),
      ~message=`Should be possible to query wildcard partition,
      if it didn't reach max queue size limit`,
    )
    Assert.deepEqual(
      fetchState->FetchState.getNextQuery(
        ~concurrencyLimit=10,
        ~currentBlockHeight=2,
        ~maxQueueSize=4,
        ~stateId=0,
      ),
      NothingToQuery,
      ~message=`Should wait until queue is processed, to continue fetching.
      Don't wait for new block, until all partitions reached the head`,
    )
  })

  it("Shouldn't query full partitions at the head until all partitions entered sync range", () => {
    let currentBlockHeight = 1_000_000
    let syncRange = 1_000 // Should be 1/1000 of block height

    // FetchState with 2 full partitions,
    // one of them reached the head
    // For the test we have 1 address per partition,
    // but in real life it's going to be 5000.
    // And we don't want to query 5000 addresses every new block,
    // until all partitions reached the head
    let fetchState = FetchState.make(
      ~eventConfigs=[
        {
          contractName: "ContractA",
          eventId: "0",
          isWildcard: false,
        },
      ],
      ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress0, mockAddress1])]),
      ~dynamicContracts=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=1,
    )
    let fetchState =
      fetchState
      ->FetchState.setQueryResponse(
        ~query={
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 0,
        },
        ~latestFetchedBlock=getBlockData(~blockNumber=currentBlockHeight - syncRange),
        ~newItems=[],
        ~currentBlockHeight,
      )
      ->Result.getExn

    Assert.deepEqual(
      fetchState->FetchState.getNextQuery(
        ~concurrencyLimit=10,
        ~currentBlockHeight,
        ~maxQueueSize=10,
        ~stateId=0,
      ),
      Ready([
        {
          partitionId: "1",
          target: Head,
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "ContractA")]),
          fromBlock: 0,
        },
      ]),
      ~message=`Should only query partition "1", since partition "0" already entered the sync range
        and it need to wait until all partitions reach it`,
    )

    Assert.deepEqual(
      fetchState->FetchState.getNextQuery(
        ~concurrencyLimit=10,
        ~currentBlockHeight=currentBlockHeight + 1,
        ~maxQueueSize=10,
        ~stateId=0,
      ),
      Ready([
        {
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress0, "ContractA")]),
          fromBlock: 999001,
        },
        {
          partitionId: "1",
          target: Head,
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "ContractA")]),
          fromBlock: 0,
        },
      ]),
      ~message=`After partition exists from the sync range, it should be included to the query again.
        Not a perfect solution, but as a quick fix it's good to query every 1000+ blocks than every block`,
    )

    let fetchStateWithBothInSyncRange =
      fetchState
      ->FetchState.setQueryResponse(
        ~query={
          partitionId: "1",
          target: Head,
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 0,
        },
        ~latestFetchedBlock=getBlockData(~blockNumber=currentBlockHeight - syncRange),
        ~newItems=[],
        ~currentBlockHeight,
      )
      ->Result.getExn

    Assert.deepEqual(
      fetchStateWithBothInSyncRange->FetchState.getNextQuery(
        ~concurrencyLimit=10,
        ~currentBlockHeight,
        ~maxQueueSize=10,
        ~stateId=0,
      ),
      Ready([
        {
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress0, "ContractA")]),
          fromBlock: 999001,
        },
        {
          partitionId: "1",
          target: Head,
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "ContractA")]),
          fromBlock: 999001,
        },
      ]),
      ~message=`Should query both partitions when both are in the sync range`,
    )
  })

  it("Allows to get event one block earlier than the dc registring event", () => {
    let fetchState = makeInitial()

    Assert.deepEqual(
      fetchState->FetchState.getEarliestEvent,
      NoItem({
        latestFetchedBlock: {
          blockNumber: 0,
          blockTimestamp: 0,
        },
      }),
    )

    let registeringBlockNumber = 3

    let fetchStateWithEvents =
      fetchState
      ->FetchState.setQueryResponse(
        ~query={
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 0,
        },
        ~newItems=[
          mockEvent(~blockNumber=registeringBlockNumber - 1, ~logIndex=1),
          mockEvent(~blockNumber=registeringBlockNumber),
          mockEvent(~blockNumber=6, ~logIndex=2),
        ],
        ~currentBlockHeight=10,
        ~latestFetchedBlock=getBlockData(~blockNumber=10),
      )
      ->Result.getExn

    Assert.deepEqual(
      fetchStateWithEvents->FetchState.getEarliestEvent->getItem,
      Some(mockEvent(~blockNumber=2, ~logIndex=1)),
    )

    let fetchStateWithDc =
      fetchStateWithEvents->FetchState.registerDynamicContracts(
        [
          makeDynContractRegistration(
            ~contractAddress=mockAddress1,
            ~blockNumber=registeringBlockNumber,
          ),
        ],
        ~currentBlockHeight=10,
      )

    Assert.deepEqual(
      fetchStateWithDc->FetchState.getEarliestEvent->getItem,
      Some(mockEvent(~blockNumber=2, ~logIndex=1)),
      ~message=`Should allow to get event before the dc registration`,
    )
  })

  it("Returns NoItem when there is an empty partition at block 0", () => {
    let fetchState = FetchState.make(
      ~eventConfigs=[
        {
          contractName: "ContractA",
          eventId: "0",
          isWildcard: false,
        },
      ],
      ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress1, mockAddress2])]),
      ~dynamicContracts=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=1,
    )

    Assert.deepEqual(
      fetchState->FetchState.getEarliestEvent,
      NoItem({
        latestFetchedBlock: {
          blockNumber: 0,
          blockTimestamp: 0,
        },
      }),
    )

    let updatedFetchState =
      fetchState
      ->FetchState.setQueryResponse(
        ~query={
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 0,
        },
        ~newItems=[mockEvent(~blockNumber=0, ~logIndex=1)],
        ~currentBlockHeight=10,
        ~latestFetchedBlock=getBlockData(~blockNumber=1),
      )
      ->Result.getExn

    Assert.deepEqual(
      updatedFetchState->FetchState.getEarliestEvent,
      NoItem({
        latestFetchedBlock: {
          blockNumber: 0,
          blockTimestamp: 0,
        },
      }),
    )
  })

  it("Get earliest event", () => {
    let latestFetchedBlock = getBlockData(~blockNumber=500)

    let normalSelection: FetchState.selection = {
      isWildcard: false,
      eventConfigs: [
        {
          eventId: "0",
          contractName: "Greeter",
          isWildcard: false,
        },
      ],
    }

    let fetchState: FetchState.t = {
      partitions: [
        {
          id: "0",
          status: {fetchingStateId: None},
          latestFetchedBlock,
          selection: normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
          dynamicContracts: [],
          fetchedEventQueue: [
            mockEvent(~blockNumber=6, ~logIndex=2),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=2, ~logIndex=1),
          ],
        },
        {
          id: "1",
          status: {fetchingStateId: None},
          latestFetchedBlock,
          selection: normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
          dynamicContracts: [],
          fetchedEventQueue: [
            mockEvent(~blockNumber=6, ~logIndex=1),
            mockEvent(~blockNumber=5),
            mockEvent(~blockNumber=2, ~logIndex=2),
          ],
        },
      ],
      nextPartitionIndex: 2,
      isFetchingAtHead: false,
      maxAddrInPartition: 2,
      latestFullyFetchedBlock: latestFetchedBlock,
      queueSize: 5,
      firstEventBlockNumber: Some(1),
      endBlock: None,
      normalSelection,
    }

    Assert.deepEqual(
      fetchState->FetchState.getEarliestEvent->getItem,
      Some(mockEvent(~blockNumber=2, ~logIndex=1)),
    )

    Assert.deepEqual(
      fetchState
      ->FetchState.registerDynamicContracts(
        [makeDynContractRegistration(~contractAddress=mockAddress1, ~blockNumber=2)],
        ~currentBlockHeight=10,
      )
      ->FetchState.getEarliestEvent,
      NoItem({
        latestFetchedBlock: {
          blockNumber: 1,
          blockTimestamp: 0,
        },
      }),
      ~message=`Accounts for registered dynamic contracts`,
    )
  })

  it("Check contains contract address", () => {
    let fetchState = FetchState.make(
      ~eventConfigs=[
        {
          contractName: "ContractA",
          eventId: "0",
          isWildcard: false,
        },
        {
          contractName: "Gravatar",
          eventId: "0",
          isWildcard: false,
        },
      ],
      ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress1])]),
      ~dynamicContracts=[
        makeDynContractRegistration(~contractAddress=mockAddress2, ~blockNumber=1),
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=2,
    )->FetchState.registerDynamicContracts(
      [
        makeDynContractRegistration(
          ~contractType=NftFactory,
          ~contractAddress=mockAddress3,
          ~blockNumber=2,
        ),
      ],
      ~currentBlockHeight=10,
    )

    Assert.equal(
      fetchState->FetchState.checkContainsRegisteredContractAddress(
        ~contractAddress=mockAddress1,
        ~contractName="ContractA",
        ~chainId=1,
      ),
      true,
    )
    Assert.equal(
      fetchState->FetchState.checkContainsRegisteredContractAddress(
        ~contractAddress=mockAddress2,
        ~contractName=(Gravatar :> string),
        ~chainId=1,
      ),
      true,
    )
    Assert.equal(
      fetchState->FetchState.checkContainsRegisteredContractAddress(
        ~contractAddress=mockAddress3,
        ~contractName=(NftFactory :> string),
        ~chainId=1,
      ),
      true,
      ~message=`Should be able to register an event for a new contract, not defined in the initial event configs`,
    )
    Assert.equal(
      fetchState->FetchState.checkContainsRegisteredContractAddress(
        ~contractAddress=mockAddress4,
        ~contractName=(Gravatar :> string),
        ~chainId=1,
      ),
      false,
    )
  })

  it("Should be fetching at head only when all partitions are fetching at head", () => {
    let fetchState = FetchState.make(
      ~eventConfigs=[
        {
          contractName: "ContractA",
          eventId: "0",
          isWildcard: false,
        },
        {
          contractName: "ContractB",
          eventId: "0",
          isWildcard: false,
        },
      ],
      ~staticContracts=Js.Dict.fromArray([
        ("ContractA", [mockAddress1]),
        ("ContractB", [mockAddress2]),
      ]),
      ~dynamicContracts=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=1,
    )

    let q0 = {
      FetchState.partitionId: "0",
      target: Head,
      selection: fetchState.normalSelection,
      contractAddressMapping: ContractAddressingMap.make(),
      fromBlock: 0,
    }
    let q1 = {
      FetchState.partitionId: "1",
      target: Head,
      selection: fetchState.normalSelection,
      contractAddressMapping: ContractAddressingMap.make(),
      fromBlock: 0,
    }

    Assert.equal(fetchState.isFetchingAtHead, false)

    let fetchStateWithResponse1 =
      fetchState
      ->FetchState.setQueryResponse(
        ~query=q0,
        ~newItems=[],
        ~currentBlockHeight=10,
        ~latestFetchedBlock=getBlockData(~blockNumber=10),
      )
      ->Result.getExn

    Assert.equal(
      fetchStateWithResponse1.isFetchingAtHead,
      false,
      ~message=`Only partition "0" caught up to head,
      should wait for partition "1" to catch up to head as well`,
    )

    let fetchStateWithResponse2 =
      fetchStateWithResponse1
      ->FetchState.setQueryResponse(
        ~query=q1,
        ~newItems=[],
        ~currentBlockHeight=10,
        ~latestFetchedBlock=getBlockData(~blockNumber=10),
      )
      ->Result.getExn

    Assert.equal(
      fetchStateWithResponse2.isFetchingAtHead,
      true,
      ~message=`Both partitions "0" and "1" caught up to head`,
    )

    let fetchStateWithResponse3 =
      fetchStateWithResponse2
      ->FetchState.setQueryResponse(
        ~query=q0,
        ~newItems=[],
        ~currentBlockHeight=11,
        ~latestFetchedBlock=getBlockData(~blockNumber=11),
      )
      ->Result.getExn

    Assert.equal(
      fetchStateWithResponse3.isFetchingAtHead,
      false,
      ~message=`After partition "0" next query it got updated currentBlockHeight,
      and since both partitions are not in the sync range isFetchingAtHead should reset`,
    )

    let fetchStateAt999 =
      fetchState
      ->FetchState.setQueryResponse(
        ~query=q0,
        ~newItems=[],
        ~currentBlockHeight=999,
        ~latestFetchedBlock=getBlockData(~blockNumber=999),
      )
      ->Result.getExn
      ->FetchState.setQueryResponse(
        ~query=q1,
        ~newItems=[],
        ~currentBlockHeight=999,
        ~latestFetchedBlock=getBlockData(~blockNumber=999),
      )
      ->Result.getExn

    Assert.equal(
      fetchStateAt999.isFetchingAtHead,
      true,
      ~message=`This is a preparation for the next test, confirm that it's fetching at head`,
    )

    let fetchStatePartiallyAt1000 =
      fetchStateAt999
      ->FetchState.setQueryResponse(
        ~query=q0,
        ~newItems=[],
        ~currentBlockHeight=1000,
        ~latestFetchedBlock=getBlockData(~blockNumber=1000),
      )
      ->Result.getExn

    Assert.equal(
      fetchStatePartiallyAt1000.isFetchingAtHead,
      true,
      ~message=`Even though partition "1" is 1 block behind than currentBlockHeight,
      we still don't reset the isFetchingAtHead, since we consider it not leaving the sync range`,
    )

    let fetchStatePartiallyAt1001 =
      fetchStateAt999
      ->FetchState.setQueryResponse(
        ~query=q0,
        ~newItems=[],
        ~currentBlockHeight=1001,
        ~latestFetchedBlock=getBlockData(~blockNumber=1001),
      )
      ->Result.getExn

    Assert.equal(
      fetchStatePartiallyAt1001.isFetchingAtHead,
      false,
      ~message=`Sync range should be 1/1000 of the chain height, so having 2 blocks diff
      is going to be considered as leaving the sync range`,
    )

    let fetchStatePartiallyAt1000WithDcInSyncRange =
      fetchStatePartiallyAt1000->FetchState.registerDynamicContracts(
        [makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=1000)],
        ~currentBlockHeight=1000,
      )

    Assert.equal(
      fetchStatePartiallyAt1000WithDcInSyncRange.isFetchingAtHead,
      true,
      ~message=`Dynamic contract registration inside of a sync range shouldn't reset the isFetchingAtHead`,
    )

    let fetchStatePartiallyAt1000WithDcOutsideOfSyncRange =
      fetchStatePartiallyAt1000->FetchState.registerDynamicContracts(
        [makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=999)],
        ~currentBlockHeight=1000,
      )

    Assert.equal(
      fetchStatePartiallyAt1000WithDcOutsideOfSyncRange.isFetchingAtHead,
      false,
      ~message=`Dynamic contract registration outside of a sync range should reset the isFetchingAtHead`,
    )
  })

  it("isActively indexing", () => {
    Assert.deepEqual(
      makeInitial()->FetchState.isActivelyIndexing,
      true,
      ~message=`Should be actively indexing with initial state`,
    )
    Assert.deepEqual(
      {...makeInitial(), endBlock: Some(10)}->FetchState.isActivelyIndexing,
      true,
      ~message=`Should be actively indexing with initial state, even if there's an endBlock`,
    )
    Assert.deepEqual(
      {...makeInitial(), endBlock: Some(0)}->FetchState.isActivelyIndexing,
      false,
      ~message=`But if endBlock is equal to the startBlock, initial state shouldn't be active`,
    )
    Assert.deepEqual(
      {
        ...makeInitial(),
        endBlock: Some(0),
      }
      ->FetchState.setQueryResponse(
        ~query={
          partitionId: "0",
          fromBlock: 0,
          target: EndBlock({toBlock: 0}),
          selection: makeInitial().normalSelection,
          contractAddressMapping: ContractAddressingMap.make(),
        },
        ~newItems=[mockEvent(~blockNumber=0)],
        ~latestFetchedBlock={blockNumber: 0, blockTimestamp: 0},
        ~currentBlockHeight=1,
      )
      ->Result.getExn
      ->FetchState.isActivelyIndexing,
      true,
      ~message=`Although, with items in the queue it should be considered active`,
    )
  })

  it(
    "Adding dynamic between two registers while query is mid flight does no result in early merged registers",
    () => {
      let currentBlockHeight = 600

      let fetchState = FetchState.make(
        ~eventConfigs=[
          {
            contractName: "Gravatar",
            eventId: "0",
            isWildcard: false,
          },
        ],
        ~staticContracts=Js.Dict.fromArray([("Gravatar", [mockAddress1])]),
        ~dynamicContracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=2,
      )
      let fetchState =
        fetchState
        ->FetchState.setQueryResponse(
          ~query={
            partitionId: "0",
            target: Head,
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([
              (mockAddress1, (Gravatar :> string)),
            ]),
            fromBlock: 0,
          },
          ~newItems=[
            mockEvent(~blockNumber=1, ~logIndex=1),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=6, ~logIndex=2),
          ],
          ~currentBlockHeight,
          ~latestFetchedBlock=getBlockData(~blockNumber=500),
        )
        ->Result.getExn

      //Dynamic contract A registered at block 100
      let fetchStateWithDcA =
        fetchState->FetchState.registerDynamicContracts(
          [makeDynContractRegistration(~contractAddress=mockAddress2, ~blockNumber=100)],
          ~currentBlockHeight=10,
        )

      let queryA = switch fetchStateWithDcA->FetchState.getNextQuery(
        ~concurrencyLimit=10,
        ~currentBlockHeight,
        ~maxQueueSize=10,
        ~stateId=0,
      ) {
      | Ready([q]) => {
          Assert.deepEqual(
            q,
            {
              partitionId: "1",
              target: Merge({
                intoPartitionId: "0",
                toBlock: 500,
              }),
              selection: fetchState.normalSelection,
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress2, (Gravatar :> string)),
              ]),
              fromBlock: 100,
            },
          )
          q
        }
      | nextQuery =>
        Js.log2("nextQueryA res", nextQuery)
        Js.Exn.raiseError(
          "Should have returned a query with updated fetch state applying dynamic contracts",
        )
      }

      // Emulate that we started fetching the query
      fetchStateWithDcA->FetchState.startFetchingQueries(~queries=[queryA], ~stateId=0)

      //Next registration happens at block 200, between the first register and the upperbound of it's query
      let fetchStateWithDcB =
        fetchStateWithDcA->FetchState.registerDynamicContracts(
          [makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=200)],
          ~currentBlockHeight=10,
        )

      Assert.deepEqual(
        fetchStateWithDcB->FetchState.getNextQuery(
          ~concurrencyLimit=10,
          ~currentBlockHeight,
          ~maxQueueSize=10,
          ~stateId=0,
        ),
        NothingToQuery,
        ~message=`The newly registered contract should be locked from querying, since we have an active merge query`,
      )

      //Response with updated fetch state
      let fetchStateWithBothDcsAndQueryAResponse =
        fetchStateWithDcB
        ->FetchState.setQueryResponse(
          ~query=queryA,
          ~latestFetchedBlock=getBlockData(~blockNumber=400),
          ~currentBlockHeight,
          ~newItems=[],
        )
        ->Utils.unwrapResultExn

      Assert.deepEqual(
        fetchStateWithBothDcsAndQueryAResponse->FetchState.getNextQuery(
          ~concurrencyLimit=10,
          ~currentBlockHeight,
          ~maxQueueSize=10,
          ~stateId=0,
        ),
        Ready([
          {
            partitionId: "2",
            target: Merge({
              intoPartitionId: "1",
              toBlock: 400,
            }),
            selection: fetchState.normalSelection,
            contractAddressMapping: ContractAddressingMap.fromArray([
              (mockAddress3, (Gravatar :> string)),
            ]),
            fromBlock: 200,
          },
        ]),
        ~message=`Should have returned query using registered contract B, from it's registering block to the last block fetched in query A`,
      )
    },
  )
})

describe("Test queue item", () => {
  it("Correctly compares queue items", () => {
    Assert.deepEqual(
      FetchState.NoItem({
        latestFetchedBlock: getBlockData(~blockNumber=0),
      })->FetchState.qItemLt(
        NoItem({
          latestFetchedBlock: getBlockData(~blockNumber=0),
        }),
      ),
      false,
      ~message=`Both NoItem with the same block`,
    )
    Assert.deepEqual(
      FetchState.NoItem({
        latestFetchedBlock: getBlockData(~blockNumber=0),
      })->FetchState.qItemLt(
        NoItem({
          latestFetchedBlock: getBlockData(~blockNumber=1),
        }),
      ),
      true,
      ~message=`NoItem with the earlier block, than NoItem`,
    )

    let mockQueueItem = (~blockNumber, ~logIndex=0) => {
      FetchState.Item({
        item: mockEvent(~blockNumber, ~logIndex),
        popItemOffQueue: () => Assert.fail("Shouldn't be called"),
      })
    }

    Assert.deepEqual(
      FetchState.NoItem({
        latestFetchedBlock: getBlockData(~blockNumber=0),
      })->FetchState.qItemLt(mockQueueItem(~blockNumber=0)),
      true,
      ~message=`NoItem with 0 block should be lower than Item with 0 block`,
    )
    Assert.deepEqual(
      mockQueueItem(~blockNumber=0)->FetchState.qItemLt(
        FetchState.NoItem({
          latestFetchedBlock: getBlockData(~blockNumber=0),
        }),
      ),
      false,
      ~message=`1. Above reversed`,
    )

    Assert.deepEqual(
      mockQueueItem(~blockNumber=1)->FetchState.qItemLt(
        FetchState.NoItem({
          latestFetchedBlock: getBlockData(~blockNumber=1),
        }),
      ),
      true,
      ~message=`Item with 1 block should be lower than NoItem with 1 block`,
    )
    Assert.deepEqual(
      FetchState.NoItem({
        latestFetchedBlock: getBlockData(~blockNumber=1),
      })->FetchState.qItemLt(mockQueueItem(~blockNumber=1)),
      false,
      ~message=`2. Above reversed`,
    )

    Assert.deepEqual(
      mockQueueItem(~blockNumber=1)->FetchState.qItemLt(mockQueueItem(~blockNumber=2)),
      true,
      ~message=`Item with 1 block should be lower than Item with 2 block`,
    )
    Assert.deepEqual(
      mockQueueItem(~blockNumber=2)->FetchState.qItemLt(mockQueueItem(~blockNumber=1)),
      false,
      ~message=`3. Above reversed`,
    )

    Assert.deepEqual(
      mockQueueItem(~blockNumber=0)->FetchState.qItemLt(
        FetchState.NoItem({
          latestFetchedBlock: getBlockData(~blockNumber=1),
        }),
      ),
      true,
      ~message=`Item with 0 block should be lower than NoItem with 1 block`,
    )
    Assert.deepEqual(
      FetchState.NoItem({
        latestFetchedBlock: getBlockData(~blockNumber=1),
      })->FetchState.qItemLt(mockQueueItem(~blockNumber=0)),
      false,
      ~message=`4. Above reversed`,
    )

    Assert.deepEqual(
      mockQueueItem(~blockNumber=1)->FetchState.qItemLt(mockQueueItem(~blockNumber=1)),
      false,
      ~message=`Item shouldn't be lower than Item with the same`,
    )
    Assert.deepEqual(
      mockQueueItem(~blockNumber=1, ~logIndex=0)->FetchState.qItemLt(
        mockQueueItem(~blockNumber=1, ~logIndex=1),
      ),
      true,
      ~message=`Item should be lower than Item with the same, when it has lower logIndex`,
    )
    Assert.deepEqual(
      mockQueueItem(~blockNumber=1, ~logIndex=1)->FetchState.qItemLt(
        mockQueueItem(~blockNumber=1, ~logIndex=0),
      ),
      false,
      ~message=`5. Above reversed`,
    )
  })
})

describe("FetchState.queueItemIsInReorgThreshold", () => {
  it("Returns false when we just started the indexer and it has currentBlockHeight=0", () => {
    let fetchState = makeInitial()
    Assert.equal(
      fetchState
      ->FetchState.getEarliestEvent
      ->FetchState.queueItemIsInReorgThreshold(
        ~currentBlockHeight=0,
        ~heighestBlockBelowThreshold=0,
      ),
      false,
    )
  })

  it(
    "Returns false when we just started the indexer and it has currentBlockHeight=0, while start block is more than 0 + reorg threshold",
    () => {
      let fetchState = makeInitial(~startBlock=6000)
      Assert.equal(
        fetchState
        ->FetchState.getEarliestEvent
        ->FetchState.queueItemIsInReorgThreshold(
          ~currentBlockHeight=0,
          ~heighestBlockBelowThreshold=0,
        ),
        false,
      )
    },
  )
})
