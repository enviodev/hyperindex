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
        status: {isFetching: false},
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
              status: {isFetching: false},
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
              status: {isFetching: false},
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
              status: {isFetching: false},
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
              status: {isFetching: false},
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
              status: {isFetching: false},
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
              status: {isFetching: false},
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
              status: {isFetching: false},
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
              status: {isFetching: false},
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
              status: {isFetching: false},
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
              status: {isFetching: false},
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
          status: {isFetching: false},
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
          status: {isFetching: false},
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
          status: {isFetching: false},
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
      fs->FetchState.getNextQuery(~currentBlockHeight, ~endBlock, ~concurrencyLimit, ~maxQueueSize)

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

    fetchState->FetchState.startFetchingQueries(~queries=[query])

    Assert.deepEqual(
      fetchState,
      {
        ...makeEmptyExpected(),
        partitions: [
          {
            id: "0",
            status: {isFetching: true},
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
      fs->FetchState.getNextQuery(~currentBlockHeight, ~endBlock, ~concurrencyLimit, ~maxQueueSize)

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
            status: {isFetching: false},
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
            status: {isFetching: false},
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

    fetchStateWithDcs->FetchState.startFetchingQueries(~queries=[query])
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

    updatedFetchState->FetchState.startFetchingQueries(~queries=[expectedPartition2Query])
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
      fs->FetchState.getNextQuery(~currentBlockHeight, ~endBlock, ~concurrencyLimit, ~maxQueueSize)

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
            status: {isFetching: false},
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
            status: {isFetching: false},
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
            status: {isFetching: false},
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
            status: {isFetching: false},
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
            status: {isFetching: false},
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

  it("Correctly rollbacks partitions", () => {
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
            status: {isFetching: false},
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
            status: {isFetching: false},
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
            status: {isFetching: false},
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

// describe("FetchState.fetchState", () => {

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
// mockEvent(~blockNumber=1, ~logIndex=2),
// mockEvent(~blockNumber=1, ~logIndex=1),
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
