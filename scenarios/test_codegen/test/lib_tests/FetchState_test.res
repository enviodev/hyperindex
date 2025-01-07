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

let makeEmpty = () => {
  FetchState.make(
    ~staticContracts=[],
    ~dynamicContracts=[],
    ~startBlock=0,
    ~maxAddrInPartition=2,
    ~isFetchingAtHead=false,
  )
}

let makeEmptyExpected = (): FetchState.t => {
  {
    partitions: [
      {
        id: "0",
        status: {fetchingStateId: None},
        latestFetchedBlock: {
          blockNumber: 0,
          blockTimestamp: 0,
        },
        contractAddressMapping: ContractAddressingMap.make(),
        fetchedEventQueue: [],
        dynamicContracts: [],
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
    firstEventBlockNumber: None,
    batchSize: 5000,
  }
}

describe("FetchState.make", () => {
  it("Creates FetchState with empty partition when no addresses provided (for wildcard)", () => {
    let fetchState = makeEmpty()

    Assert.deepEqual(fetchState, makeEmptyExpected())
  })

  it(
    "Creates FetchState with static and dc addresses reaching the maxAddrInPartition limit",
    () => {
      let dc = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress2)
      let fetchState = FetchState.make(
        ~staticContracts=[("ContractA", mockAddress1)],
        ~dynamicContracts=[dc],
        ~startBlock=0,
        ~maxAddrInPartition=2,
        ~isFetchingAtHead=false,
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
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress1, "ContractA"),
                (mockAddress2, "Gravatar"),
              ]),
              fetchedEventQueue: [],
              dynamicContracts: [dc],
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
          firstEventBlockNumber: None,
          batchSize: 5000,
        },
      )
    },
  )

  it(
    "Creates FetchState with static addresses and dc addresses exceeding the maxAddrInPartition limit",
    () => {
      let dc = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress2)
      let fetchState = FetchState.make(
        ~staticContracts=[("ContractA", mockAddress1)],
        ~dynamicContracts=[dc],
        ~startBlock=0,
        ~maxAddrInPartition=1,
        ~isFetchingAtHead=false,
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
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress1, "ContractA"),
              ]),
              fetchedEventQueue: [],
              dynamicContracts: [],
            },
            {
              id: "1",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress2, "Gravatar")]),
              fetchedEventQueue: [],
              dynamicContracts: [dc],
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
          firstEventBlockNumber: None,
          batchSize: 5000,
        },
      )
    },
  )

  it(
    "Creates FetchState with static and dc addresses exceeding the maxAddrInPartition limit",
    () => {
      let dc1 = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress3)
      let dc2 = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress4)
      let fetchState = FetchState.make(
        ~staticContracts=[("ContractA", mockAddress1), ("ContractA", mockAddress2)],
        ~dynamicContracts=[dc1, dc2],
        ~startBlock=0,
        ~maxAddrInPartition=1,
        ~isFetchingAtHead=false,
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
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress1, "ContractA"),
              ]),
              fetchedEventQueue: [],
              dynamicContracts: [],
            },
            {
              id: "1",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress2, "ContractA"),
              ]),
              fetchedEventQueue: [],
              dynamicContracts: [],
            },
            {
              id: "2",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress3, "Gravatar")]),
              fetchedEventQueue: [],
              dynamicContracts: [dc1],
            },
            {
              id: "3",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress4, "Gravatar")]),
              fetchedEventQueue: [],
              dynamicContracts: [dc2],
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
          batchSize: 5000,
        },
      )
    },
  )
})

describe("FetchState.registerDynamicContract", () => {
  // It shouldn't happen, but just in case
  it("Nothing breaks when provided an empty array", () => {
    let fetchState = makeEmpty()

    Assert.deepEqual(
      fetchState->FetchState.registerDynamicContract([], ~isFetchingAtHead=true),
      {
        ...makeEmptyExpected(),
        // Should only update isFetchingAtHead
        isFetchingAtHead: true,
      },
    )
  })

  it(
    "Dcs with the same start block are grouped in a single partition. But don't merged with an existing one",
    () => {
      let fetchState = makeEmpty()

      let dc1 = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress1)
      let dc2 = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress2)
      let dc3 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress3)

      Assert.deepEqual(
        // Order of dcs doesn't matter
        fetchState->FetchState.registerDynamicContract([dc1, dc3, dc2], ~isFetchingAtHead=false),
        {
          ...makeEmptyExpected(),
          nextPartitionIndex: 3,
          partitions: [
            {
              id: "0",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              contractAddressMapping: ContractAddressingMap.make(),
              fetchedEventQueue: [],
              dynamicContracts: [],
            },
            {
              id: "1",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress1, "Gravatar"),
                (mockAddress2, "Gravatar"),
              ]),
              fetchedEventQueue: [],
              dynamicContracts: [dc1, dc2],
            },
            {
              id: "2",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 1,
                blockTimestamp: 0,
              },
              contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress3, "Gravatar")]),
              fetchedEventQueue: [],
              dynamicContracts: [dc3],
            },
          ],
        },
      )
    },
  )
})

describe("FetchState.getNextQuery & integration", () => {
  let dc1 = makeDynContractRegistration(~blockNumber=1, ~contractAddress=mockAddress1)
  let dc2 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)

  let makeAfterFirstStaticAddressesQuery = (): FetchState.t => {
    {
      partitions: [
        {
          id: "0",
          status: {fetchingStateId: None},
          latestFetchedBlock: {
            blockNumber: 10,
            blockTimestamp: 10,
          },
          contractAddressMapping: ContractAddressingMap.make(),
          fetchedEventQueue: [mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
          dynamicContracts: [],
        },
      ],
      nextPartitionIndex: 1,
      isFetchingAtHead: true,
      maxAddrInPartition: 2,
      latestFullyFetchedBlock: {
        blockNumber: 10,
        blockTimestamp: 10,
      },
      queueSize: 2,
      firstEventBlockNumber: Some(1),
      batchSize: 5000,
    }
  }

  let makeIntermidiateDcMerge = (): FetchState.t => {
    {
      partitions: [
        {
          id: "0",
          status: {fetchingStateId: None},
          latestFetchedBlock: {
            blockNumber: 10,
            blockTimestamp: 10,
          },
          contractAddressMapping: ContractAddressingMap.make(),
          fetchedEventQueue: [mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
          dynamicContracts: [],
        },
        {
          id: "2",
          status: {fetchingStateId: None},
          latestFetchedBlock: {
            blockNumber: 1,
            blockTimestamp: 0,
          },
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress2, "Gravatar"),
            (mockAddress1, "Gravatar"),
          ]),
          fetchedEventQueue: [],
          dynamicContracts: [dc2, dc1],
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
      batchSize: 5000,
    }
  }

  it("Emulate first indexer queris with only wildcard events", () => {
    // The default configuration with ability to overwrite some values
    let getNextQuery = (
      fs,
      ~endBlock=None,
      ~currentBlockHeight=10,
      ~maxQueueSize=10,
      ~concurrencyLimit=10,
    ) =>
      fs->FetchState.getNextQuery(
        ~currentBlockHeight,
        ~endBlock,
        ~concurrencyLimit,
        ~maxQueueSize,
        ~stateId=0,
      )

    let fetchState = makeEmpty()

    Assert.deepEqual(fetchState->getNextQuery(~currentBlockHeight=0), WaitingForNewBlock)

    let nextQuery = fetchState->getNextQuery

    Assert.deepEqual(
      nextQuery,
      Ready([
        PartitionQuery({
          partitionId: "0",
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 0,
          toBlock: None,
        }),
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
        ...makeEmptyExpected(),
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: Some(0)},
            latestFetchedBlock: {
              blockNumber: 0,
              blockTimestamp: 0,
            },
            contractAddressMapping: ContractAddressingMap.make(),
            fetchedEventQueue: [],
            dynamicContracts: [],
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
    Assert.deepEqual(updatedFetchState->getNextQuery(~endBlock=Some(10)), NothingToQuery)
    Assert.deepEqual(updatedFetchState->getNextQuery(~maxQueueSize=2), NothingToQuery)
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
      fs->FetchState.getNextQuery(
        ~currentBlockHeight,
        ~endBlock,
        ~concurrencyLimit,
        ~maxQueueSize,
        ~stateId=0,
      )

    // Continue with the state from previous test
    let fetchState = makeAfterFirstStaticAddressesQuery()

    let fetchStateWithDcs =
      fetchState->FetchState.registerDynamicContract([dc2, dc1], ~isFetchingAtHead=false)

    Assert.deepEqual(
      fetchStateWithDcs,
      {
        ...fetchState,
        // The isFetchingAtHead is overwritten. Although, I don't know whether it's correct
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
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "Gravatar")]),
            fetchedEventQueue: [],
            dynamicContracts: [dc1],
          },
          {
            id: "2",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 1,
              blockTimestamp: 0,
            },
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress2, "Gravatar")]),
            fetchedEventQueue: [],
            dynamicContracts: [dc2],
          },
        ]),
      },
    )

    Assert.deepEqual(
      fetchStateWithDcs->getNextQuery,
      Ready([
        MergeQuery({
          partitionId: "1",
          intoPartitionId: "2",
          // Should be fromBlock 0, but we have a bug
          fromBlock: 0,
          toBlock: 1,
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "Gravatar")]),
        }),
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
      {
        ...makeIntermidiateDcMerge(),
        maxAddrInPartition: 2,
      },
    )

    let expectedPartition2Query: FetchState.query = PartitionQuery({
      partitionId: "2",
      fromBlock: 2,
      toBlock: None,
      contractAddressMapping: ContractAddressingMap.fromArray([
        (mockAddress2, "Gravatar"),
        (mockAddress1, "Gravatar"),
      ]),
    })
    let expectedPartition1Query: FetchState.query = PartitionQuery({
      partitionId: "0",
      contractAddressMapping: ContractAddressingMap.make(),
      fromBlock: 11,
      toBlock: None,
    })

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
      fs->FetchState.getNextQuery(
        ~currentBlockHeight,
        ~endBlock,
        ~concurrencyLimit,
        ~maxQueueSize,
        ~stateId=0,
      )

    // Continue with the state from previous test
    // But increase the maxAddrInPartition up to 3
    let fetchState = makeIntermidiateDcMerge()

    Assert.deepEqual(
      fetchState->getNextQuery,
      Ready([
        MergeQuery({
          partitionId: "2",
          intoPartitionId: "0",
          fromBlock: 2,
          toBlock: 10,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress2, "Gravatar"),
            (mockAddress1, "Gravatar"),
          ]),
        }),
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
            contractAddressMapping: ContractAddressingMap.make(),
            fetchedEventQueue: [mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
            dynamicContracts: [],
          },
          {
            id: "2",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 9,
              blockTimestamp: 9,
            },
            contractAddressMapping: ContractAddressingMap.fromArray([
              (mockAddress2, "Gravatar"),
              (mockAddress1, "Gravatar"),
            ]),
            fetchedEventQueue: [
              mockEvent(~blockNumber=4, ~logIndex=6),
              mockEvent(~blockNumber=4, ~logIndex=2),
            ],
            dynamicContracts: [dc2, dc1],
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
        MergeQuery({
          partitionId: "2",
          intoPartitionId: "0",
          fromBlock: 10,
          toBlock: 10,
          contractAddressMapping: ContractAddressingMap.fromArray([
            (mockAddress2, "Gravatar"),
            (mockAddress1, "Gravatar"),
          ]),
        }),
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
            contractAddressMapping: ContractAddressingMap.fromArray([
              (mockAddress2, "Gravatar"),
              (mockAddress1, "Gravatar"),
            ]),
            fetchedEventQueue: [
              mockEvent(~blockNumber=4, ~logIndex=6),
              mockEvent(~blockNumber=4, ~logIndex=2),
              mockEvent(~blockNumber=2),
              mockEvent(~blockNumber=1),
            ],
            dynamicContracts: [dc2, dc1],
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
        maxAddrInPartition: 1,
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
        maxAddrInPartition: 1,
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 10,
              blockTimestamp: 10,
            },
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "Gravatar")]),
            fetchedEventQueue: [
              mockEvent(~blockNumber=4, ~logIndex=6),
              mockEvent(~blockNumber=4, ~logIndex=2),
              mockEvent(~blockNumber=2),
              mockEvent(~blockNumber=1),
            ],
            dynamicContracts: [dc1],
          },
          {
            id: "2",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 10,
              blockTimestamp: 10,
            },
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress2, "Gravatar")]),
            fetchedEventQueue: [],
            dynamicContracts: [dc2],
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

  it("Root partition never merges to another one (because of shouldApplyWildcards check)", () => {
    let fetchState =
      FetchState.make(
        ~staticContracts=[("ContractA", mockAddress1)],
        ~dynamicContracts=[],
        ~startBlock=0,
        ~maxAddrInPartition=2,
        ~isFetchingAtHead=false,
      )->FetchState.registerDynamicContract(
        [makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)],
        ~isFetchingAtHead=false,
      )

    Assert.deepEqual(fetchState.partitions->Array.length, 2)

    let nextQuery =
      fetchState->FetchState.getNextQuery(
        ~currentBlockHeight=10,
        ~endBlock=None,
        ~concurrencyLimit=10,
        ~maxQueueSize=10,
        ~stateId=0,
      )

    Assert.deepEqual(
      nextQuery,
      Ready([
        PartitionQuery({
          partitionId: "0",
          contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "ContractA")]),
          fromBlock: 0,
          toBlock: None,
        }),
      ]),
      ~message=`Still locks the partition "1", but performs a PartitionQuery for "0" instead of MergeQuery`,
    )
  })

  it("Correctly rollbacks fetch state", () => {
    let fetchState = makeIntermidiateDcMerge()

    let fetchStateAfterRollback1 =
      fetchState->FetchState.rollback(
        ~lastScannedBlock={blockNumber: 2, blockTimestamp: 2},
        ~firstChangeEvent={blockNumber: 2, logIndex: 0},
      )

    Assert.deepEqual(
      fetchStateAfterRollback1,
      {
        ...fetchState,
        partitions: [
          {
            id: "0",
            status: {fetchingStateId: None},
            latestFetchedBlock: {
              blockNumber: 2,
              blockTimestamp: 2,
            },
            contractAddressMapping: ContractAddressingMap.make(),
            // Removed an item here, but kept the partition.
            // Even though there are no addresses
            fetchedEventQueue: [mockEvent(~blockNumber=1)],
            dynamicContracts: [],
          },
          {
            id: "2",
            status: {fetchingStateId: None},
            // Should keep it's own latestFetchedBlock
            latestFetchedBlock: {
              blockNumber: 1,
              blockTimestamp: 0,
            },
            contractAddressMapping: ContractAddressingMap.fromArray([(mockAddress1, "Gravatar")]),
            fetchedEventQueue: [],
            // Removed dc2, even though the latestFetchedBlock is not exceeding the lastScannedBlock
            dynamicContracts: [dc1],
          },
        ],
        queueSize: 1,
      },
      ~message=`Should rollback the partition state, but keep them`,
    )

    // Rollback even more to see the removal of partition "2"
    let fetchStateAfterRollback2 =
      fetchStateAfterRollback1->FetchState.rollback(
        ~lastScannedBlock={blockNumber: 0, blockTimestamp: 0},
        ~firstChangeEvent={blockNumber: 0, logIndex: 0},
      )

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
            contractAddressMapping: ContractAddressingMap.make(),
            fetchedEventQueue: [],
            dynamicContracts: [],
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
})

describe("FetchState unit tests for specific cases", () => {
  it("Should merge events in correct order on merging", () => {
    let fetchState: FetchState.t = {
      partitions: [
        {
          id: "0",
          status: {fetchingStateId: None},
          latestFetchedBlock: {
            blockNumber: 10,
            blockTimestamp: 10,
          },
          contractAddressMapping: ContractAddressingMap.make(),
          fetchedEventQueue: [
            mockEvent(~blockNumber=4, ~logIndex=2),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=2),
          ],
          dynamicContracts: [],
        },
        {
          id: "1",
          status: {fetchingStateId: None},
          latestFetchedBlock: {
            blockNumber: 1,
            blockTimestamp: 0,
          },
          contractAddressMapping: ContractAddressingMap.make(),
          fetchedEventQueue: [mockEvent(~blockNumber=3), mockEvent(~blockNumber=1)],
          dynamicContracts: [],
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
      batchSize: 5000,
    }

    let updatedFetchState =
      fetchState
      ->FetchState.setQueryResponse(
        ~query=MergeQuery({
          partitionId: "1",
          intoPartitionId: "0",
          fromBlock: 1,
          toBlock: 10,
          contractAddressMapping: ContractAddressingMap.make(),
        }),
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
            contractAddressMapping: ContractAddressingMap.make(),
            fetchedEventQueue: [
              mockEvent(~blockNumber=4, ~logIndex=2),
              mockEvent(~blockNumber=4, ~logIndex=1),
              mockEvent(~blockNumber=4, ~logIndex=1),
              mockEvent(~blockNumber=4),
              mockEvent(~blockNumber=3),
              mockEvent(~blockNumber=2),
              mockEvent(~blockNumber=1),
            ],
            dynamicContracts: [],
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

  it("Allows to get event before the dc registring item", () => {
    let fetchState = makeEmpty()

    Assert.deepEqual(
      fetchState->FetchState.getEarliestEvent,
      NoItem({
        blockNumber: 0,
        blockTimestamp: 0,
      }),
    )

    let registeringBlockNumber = 3

    let fetchStateWithEvents =
      fetchState
      ->FetchState.setQueryResponse(
        ~query=PartitionQuery({
          partitionId: "0",
          contractAddressMapping: ContractAddressingMap.make(),
          fromBlock: 0,
          toBlock: None,
        }),
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
      fetchStateWithEvents->FetchState.registerDynamicContract(
        [
          makeDynContractRegistration(
            ~contractAddress=mockAddress1,
            ~blockNumber=registeringBlockNumber,
          ),
        ],
        ~isFetchingAtHead=false,
      )

    Assert.deepEqual(
      fetchStateWithDc->FetchState.getEarliestEvent->getItem,
      // Some(mockEvent(~blockNumber=2, ~logIndex=1)),
      None,
      ~message=`Should allow to get event before the dc registration`,
    )
  })

  it("Get earliest event", () => {
    let latestFetchedBlock = getBlockData(~blockNumber=500)

    let fetchState: FetchState.t = {
      partitions: [
        {
          id: "0",
          status: {fetchingStateId: None},
          latestFetchedBlock,
          contractAddressMapping: ContractAddressingMap.make(),
          fetchedEventQueue: [
            mockEvent(~blockNumber=6, ~logIndex=2),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=2, ~logIndex=1),
          ],
          dynamicContracts: [],
        },
        {
          id: "1",
          status: {fetchingStateId: None},
          latestFetchedBlock,
          contractAddressMapping: ContractAddressingMap.make(),
          fetchedEventQueue: [
            mockEvent(~blockNumber=6, ~logIndex=1),
            mockEvent(~blockNumber=5),
            mockEvent(~blockNumber=2, ~logIndex=2),
          ],
          dynamicContracts: [],
        },
      ],
      nextPartitionIndex: 2,
      isFetchingAtHead: false,
      maxAddrInPartition: 2,
      latestFullyFetchedBlock: latestFetchedBlock,
      queueSize: 5,
      firstEventBlockNumber: Some(1),
      batchSize: 5000,
    }

    Assert.deepEqual(
      fetchState->FetchState.getEarliestEvent->getItem,
      Some(mockEvent(~blockNumber=2, ~logIndex=1)),
    )

    Assert.deepEqual(
      fetchState
      ->FetchState.registerDynamicContract(
        [makeDynContractRegistration(~contractAddress=mockAddress1, ~blockNumber=2)],
        ~isFetchingAtHead=false,
      )
      ->FetchState.getEarliestEvent,
      NoItem({
        blockNumber: 1,
        blockTimestamp: 0,
      }),
      ~message=`Accounts for registered dynamic contracts`,
    )
  })

  it("Check contains contract address", () => {
    let fetchState =
      FetchState.make(
        ~staticContracts=[("ContractA", mockAddress1)],
        ~dynamicContracts=[
          makeDynContractRegistration(~contractAddress=mockAddress2, ~blockNumber=1),
        ],
        ~startBlock=0,
        ~maxAddrInPartition=2,
        ~isFetchingAtHead=false,
      )->FetchState.registerDynamicContract(
        [makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=2)],
        ~isFetchingAtHead=false,
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
        ~contractName=(Gravatar :> string),
        ~chainId=1,
      ),
      true,
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

  it("isActively indexing", () => {
    Assert.deepEqual(
      makeEmpty()->FetchState.isActivelyIndexing(~endBlock=None),
      true,
      ~message=`Should be actively indexing with initial state`,
    )
    Assert.deepEqual(
      makeEmpty()->FetchState.isActivelyIndexing(~endBlock=Some(10)),
      true,
      ~message=`Should be actively indexing with initial state, even if there's an endBlock`,
    )
    Assert.deepEqual(
      makeEmpty()->FetchState.isActivelyIndexing(~endBlock=Some(0)),
      false,
      ~message=`But if endBlock is equal to the startBlock, initial state shouldn't be active`,
    )
    Assert.deepEqual(
      makeEmpty()
      ->FetchState.setQueryResponse(
        ~query=PartitionQuery({
          partitionId: "0",
          fromBlock: 0,
          toBlock: Some(0),
          contractAddressMapping: ContractAddressingMap.make(),
        }),
        ~newItems=[mockEvent(~blockNumber=0)],
        ~latestFetchedBlock={blockNumber: 0, blockTimestamp: 0},
        ~currentBlockHeight=1,
      )
      ->Result.getExn
      ->FetchState.isActivelyIndexing(~endBlock=Some(0)),
      true,
      ~message=`Although, with items in the queue it should be considered active`,
    )
  })

  it(
    "Adding dynamic between two registers while query is mid flight does no result in early merged registers",
    () => {
      let currentBlockHeight = 600

      let fetchState =
        FetchState.make(
          ~staticContracts=[((Gravatar :> string), mockAddress1)],
          ~dynamicContracts=[],
          ~startBlock=0,
          ~maxAddrInPartition=2,
          ~isFetchingAtHead=false,
        )
        ->FetchState.setQueryResponse(
          ~query=PartitionQuery({
            partitionId: "0",
            contractAddressMapping: ContractAddressingMap.fromArray([
              (mockAddress1, (Gravatar :> string)),
            ]),
            fromBlock: 0,
            toBlock: None,
          }),
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
        fetchState->FetchState.registerDynamicContract(
          [makeDynContractRegistration(~contractAddress=mockAddress2, ~blockNumber=100)],
          ~isFetchingAtHead=false,
        )

      let queryA = switch fetchStateWithDcA->FetchState.getNextQuery(
        ~endBlock=None,
        ~concurrencyLimit=10,
        ~currentBlockHeight,
        ~maxQueueSize=10,
        ~stateId=0,
      ) {
      | Ready([q]) => {
          Assert.deepEqual(
            q,
            MergeQuery({
              partitionId: "1",
              intoPartitionId: "0",
              contractAddressMapping: ContractAddressingMap.fromArray([
                (mockAddress2, (Gravatar :> string)),
              ]),
              fromBlock: 100,
              toBlock: 500,
            }),
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
        fetchStateWithDcA->FetchState.registerDynamicContract(
          [makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=200)],
          ~isFetchingAtHead=false,
        )

      Assert.deepEqual(
        fetchStateWithDcB->FetchState.getNextQuery(
          ~endBlock=None,
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
          ~endBlock=None,
          ~concurrencyLimit=10,
          ~currentBlockHeight,
          ~maxQueueSize=10,
          ~stateId=0,
        ),
        Ready([
          MergeQuery({
            partitionId: "2",
            intoPartitionId: "1",
            contractAddressMapping: ContractAddressingMap.fromArray([
              (mockAddress3, (Gravatar :> string)),
            ]),
            fromBlock: 200,
            toBlock: 400,
          }),
        ]),
        ~message=`Should have returned query using registered contract B, from it's registering block to the last block fetched in query A`,
      )
    },
  )
})
