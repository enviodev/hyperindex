open Belt
open RescriptMocha
open Enums.ContractType

let chainId = 0

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
    id: UserContext.makeDynamicContractId(~chainId, ~contractAddress),
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
  eventConfig: Utils.magic("Mock eventConfig in fetchstate test"),
  logIndex,
  event: Utils.magic("Mock event in fetchstate test"),
}

let baseEventConfig = (Mock.evmEventConfig(
  ~id="0",
  ~contractName="Gravatar",
) :> Internal.eventConfig)

let makeInitial = (~startBlock=0) => {
  FetchState.make(
    ~eventConfigs=[baseEventConfig],
    ~staticContracts=Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
    ~dynamicContracts=[],
    ~startBlock,
    ~endBlock=None,
    ~maxAddrInPartition=3,
    ~chainId,
  )
}

// Helper to build indexingContracts dict for test expectations
// Note: dynamic contract info is now only tracked by the register field (DC variant)
let makeIndexingContractsWithDynamics = (dcs: array<TablesStatic.DynamicContractRegistry.t>) => {
  let dict = Js.Dict.empty()
  dcs->Array.forEach(dc => {
    let contract: FetchState.indexingContract = {
      address: dc.contractAddress,
      contractName: (dc.contractType :> string),
      startBlock: dc.registeringEventBlockNumber,
      register: DC({
        id: dc.id->Utils.magic,
        registeringEventBlockTimestamp: dc.registeringEventBlockTimestamp,
        registeringEventLogIndex: dc.registeringEventLogIndex,
        registeringEventContractName: dc.registeringEventContractName,
        registeringEventName: dc.registeringEventName,
        registeringEventSrcAddress: dc.registeringEventSrcAddress,
      }),
    }
    dict->Js.Dict.set(dc.contractAddress->Address.toString, contract)
  })
  dict
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
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
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
        chainId: 0,
        indexingContracts: fetchState.indexingContracts,
      },
    )
  })

  it("Panics with nothing to fetch", () => {
    Assert.throws(
      () => {
        FetchState.make(
          ~eventConfigs=[baseEventConfig],
          ~staticContracts=Js.Dict.empty(),
          ~dynamicContracts=[],
          ~startBlock=0,
          ~endBlock=None,
          ~maxAddrInPartition=2,
          ~chainId,
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
        ~eventConfigs=[baseEventConfig],
        ~staticContracts=Js.Dict.fromArray([("Gravatar", [mockAddress1])]),
        ~dynamicContracts=[dc],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=2,
        ~chainId,
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
              addressesByContractName: Js.Dict.fromArray([
                ("Gravatar", [mockAddress1, mockAddress2]),
              ]),
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
          chainId,
          indexingContracts: fetchState.indexingContracts,
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
          (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
          baseEventConfig,
        ],
        ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress1])]),
        ~dynamicContracts=[dc],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=1,
        ~chainId,
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
              addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress1])]),
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
              addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress2])]),
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
          chainId,
          indexingContracts: fetchState.indexingContracts,
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
          (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
          baseEventConfig,
        ],
        ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress1, mockAddress2])]),
        ~dynamicContracts=[dc1, dc2],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=1,
        ~chainId,
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
              addressesByContractName: Js.Dict.fromArray([
                ("ContractA", [mockAddress1, mockAddress2]),
              ]),
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
              addressesByContractName: Js.Dict.fromArray([
                ("Gravatar", [mockAddress3, mockAddress4]),
              ]),
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
          firstEventBlockNumber: None,
          endBlock: None,
          normalSelection: fetchState.normalSelection,
          chainId,
          indexingContracts: fetchState.indexingContracts,
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
              addressesByContractName: Js.Dict.fromArray([
                ("Gravatar", [mockAddress1, mockAddress2]),
              ]),
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
              addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
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
      let wildcard1 = (Mock.evmEventConfig(
        ~id="wildcard1",
        ~contractName="Gravatar",
        ~isWildcard=true,
      ) :> Internal.eventConfig)
      let wildcard2 = (Mock.evmEventConfig(
        ~id="wildcard2",
        ~contractName="Gravatar",
        ~isWildcard=true,
      ) :> Internal.eventConfig)
      let normal1 = (Mock.evmEventConfig(
        ~id="normal1",
        ~contractName="NftFactory",
      ) :> Internal.eventConfig)
      let normal2 = (Mock.evmEventConfig(
        ~id="normal2",
        ~contractName="NftFactory",
        ~isWildcard=true,
        ~dependsOnAddresses=true,
      ) :> Internal.eventConfig)

      let fetchState = FetchState.make(
        ~eventConfigs=[wildcard1, wildcard2, normal1, normal2],
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
        ~chainId,
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
                dependsOnAddresses: false,
                // Even though normal2 is also a wildcard event
                // it should be a part of the normal selection
                eventConfigs: [wildcard1, wildcard2],
              },
              addressesByContractName: Js.Dict.empty(),
              fetchedEventQueue: [],
            },
            {
              id: "1",
              status: {fetchingStateId: None},
              latestFetchedBlock: {
                blockNumber: 0,
                blockTimestamp: 0,
              },
              selection: {
                dependsOnAddresses: true,
                eventConfigs: [normal1, normal2],
              },
              addressesByContractName: Js.Dict.fromArray([
                ("NftFactory", [mockAddress0, mockAddress1]),
                ("Gravatar", [mockAddress2, mockAddress3]),
                ("NftFactory", [mockAddress5]),
              ]),
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
          chainId,
          indexingContracts: fetchState.indexingContracts,
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
      dependsOnAddresses: true,
      eventConfigs: [baseEventConfig],
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
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
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
      chainId,
      indexingContracts: Js.Dict.empty(),
    }
  }

  let makeIntermidiateDcMerge = (): FetchState.t => {
    let normalSelection: FetchState.selection = {
      dependsOnAddresses: true,
      eventConfigs: [baseEventConfig],
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
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
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
          addressesByContractName: Js.Dict.fromArray([
            ("Gravatar", [mockAddress2, mockAddress3, mockAddress1]),
          ]),
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
      chainId,
      indexingContracts: makeIndexingContractsWithDynamics([dc1, dc2, dc3]),
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
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
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
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
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
      ->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock={
          blockNumber: 10,
          blockTimestamp: 10,
        },
        ~reversedNewItems=[mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
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
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress1])]),
            // dynamicContracts: [dc1],
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
            addressesByContractName: Js.Dict.fromArray([
              ("Gravatar", [mockAddress2, mockAddress3]),
            ]),
            // dynamicContracts: [dc2, dc3],
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
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress1])]),
          // Should be fromBlock 0, but we have a bug
          fromBlock: 0,
          indexingContracts: fetchStateWithDcs.indexingContracts,
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
      ->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock={
          blockNumber: 1,
          blockTimestamp: 1,
        },
        ~reversedNewItems=[],
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
      addressesByContractName: Js.Dict.fromArray([
        ("Gravatar", [mockAddress2, mockAddress3, mockAddress1]),
      ]),
      indexingContracts: fetchStateWithDcs.indexingContracts,
    }
    let expectedPartition1Query: FetchState.query = {
      partitionId: "0",
      target: Head,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
      fromBlock: 11,
      indexingContracts: fetchStateWithDcs.indexingContracts,
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
          addressesByContractName: Js.Dict.fromArray([
            ("Gravatar", [mockAddress2, mockAddress3, mockAddress1]),
          ]),
          fromBlock: 2,
          indexingContracts: fetchState.indexingContracts,
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
      ->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock={
          blockNumber: 9,
          blockTimestamp: 9,
        },
        ~reversedNewItems=[
          mockEvent(~blockNumber=4, ~logIndex=6),
          mockEvent(~blockNumber=4, ~logIndex=2),
        ],
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
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
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
            addressesByContractName: Js.Dict.fromArray([
              ("Gravatar", [mockAddress2, mockAddress3, mockAddress1]),
            ]),
            // dynamicContracts: [dc2, dc3, dc1],
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
          addressesByContractName: Js.Dict.fromArray([
            ("Gravatar", [mockAddress2, mockAddress3, mockAddress1]),
          ]),
          fromBlock: 10,
          indexingContracts: fetchState.indexingContracts,
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
      ->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock={
          blockNumber: 10,
          blockTimestamp: 10,
        },
        ~reversedNewItems=[],
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
            addressesByContractName: Js.Dict.fromArray([
              ("Gravatar", [mockAddress0, mockAddress2, mockAddress3, mockAddress1]),
            ]),
            // dynamicContracts: [dc2, dc3, dc1],
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
      ->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock={
          blockNumber: 10,
          blockTimestamp: 10,
        },
        ~reversedNewItems=[],
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
            addressesByContractName: Js.Dict.fromArray([
              ("Gravatar", [mockAddress0, mockAddress1]),
            ]),
            // dynamicContracts: [dc1],
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
            addressesByContractName: Js.Dict.fromArray([
              ("Gravatar", [mockAddress2, mockAddress3]),
            ]),
            // dynamicContracts: [dc2, dc3],
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
    let wildcard = (Mock.evmEventConfig(
      ~id="wildcard",
      ~contractName="ContractA",
      ~isWildcard=true,
    ) :> Internal.eventConfig)
    let fetchState =
      FetchState.make(
        ~eventConfigs=[
          (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
          wildcard,
        ],
        ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress1])]),
        ~dynamicContracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=2,
        ~chainId,
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
            dependsOnAddresses: false,
            eventConfigs: [wildcard],
          },
          addressesByContractName: Js.Dict.empty(),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        {
          partitionId: "1",
          target: Merge({
            intoPartitionId: "2",
            toBlock: 1,
          }),
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress1])]),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
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
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
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
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress1])]),
            // dynamicContracts: [dc1],
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
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
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
      (Mock.evmEventConfig(
        ~id="wildcard",
        ~contractName="ContractA",
        ~isWildcard=true,
      ) :> Internal.eventConfig),
    ]
    let eventConfigs = [
      ...wildcardEventConfigs,
      (Mock.evmEventConfig(~id="0", ~contractName="Greeter") :> Internal.eventConfig),
    ]
    let fetchState =
      FetchState.make(
        ~eventConfigs,
        ~staticContracts=Js.Dict.empty(),
        ~dynamicContracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~chainId,
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
            dependsOnAddresses: false,
            eventConfigs: wildcardEventConfigs,
          },
          addressesByContractName: Js.Dict.empty(),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
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
              dependsOnAddresses: false,
              eventConfigs: wildcardEventConfigs,
            },
            addressesByContractName: Js.Dict.empty(),
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
      dependsOnAddresses: true,
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
          addressesByContractName: Js.Dict.empty(),
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
          addressesByContractName: Js.Dict.empty(),
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
      chainId,
      indexingContracts: Js.Dict.empty(),
    }

    let updatedFetchState =
      fetchState
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "1",
          target: Merge({
            intoPartitionId: "0",
            toBlock: 10,
          }),
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.empty(),
          fromBlock: 1,
          indexingContracts: fetchState.indexingContracts,
        },
        ~latestFetchedBlock={
          blockNumber: 10,
          blockTimestamp: 10,
        },
        ~currentBlockHeight=11,
        ~reversedNewItems=[
          mockEvent(~blockNumber=4, ~logIndex=1),
          mockEvent(~blockNumber=4, ~logIndex=1),
        ],
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
            addressesByContractName: Js.Dict.empty(),
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
    let wildcard = (Mock.evmEventConfig(
      ~id="wildcard",
      ~contractName="ContractA",
      ~isWildcard=true,
    ) :> Internal.eventConfig)
    // FetchState with 2 partitions,
    // one of them reached the head
    // another reached max queue size
    let fetchState = FetchState.make(
      ~eventConfigs=[
        (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
        wildcard,
      ],
      ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress0])]),
      ~dynamicContracts=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=2,
      ~chainId,
    )
    let fetchState =
      fetchState
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "0",
          target: Head,
          selection: {
            dependsOnAddresses: false,
            eventConfigs: [wildcard],
          },
          addressesByContractName: Js.Dict.empty(),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        ~latestFetchedBlock=getBlockData(~blockNumber=1),
        ~reversedNewItems=[mockEvent(~blockNumber=1), mockEvent(~blockNumber=0)],
        ~currentBlockHeight=2,
      )
      ->Result.getExn
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "1",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.empty(),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        ~latestFetchedBlock=getBlockData(~blockNumber=2),
        ~reversedNewItems=[],
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
            dependsOnAddresses: false,
            eventConfigs: [wildcard],
          },
          addressesByContractName: Js.Dict.empty(),
          fromBlock: 2,
          indexingContracts: fetchState.indexingContracts,
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
        (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
      ],
      ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress0, mockAddress1])]),
      ~dynamicContracts=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=1,
      ~chainId,
    )
    let fetchState =
      fetchState
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.empty(),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        ~latestFetchedBlock=getBlockData(~blockNumber=currentBlockHeight - syncRange),
        ~reversedNewItems=[],
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
          addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress1])]),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
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
          addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress0])]),
          fromBlock: 999001,
          indexingContracts: fetchState.indexingContracts,
        },
        {
          partitionId: "1",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress1])]),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
      ]),
      ~message=`After partition exists from the sync range, it should be included to the query again.
        Not a perfect solution, but as a quick fix it's good to query every 1000+ blocks than every block`,
    )

    let fetchStateWithBothInSyncRange =
      fetchState
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "1",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.empty(),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        ~latestFetchedBlock=getBlockData(~blockNumber=currentBlockHeight - syncRange),
        ~reversedNewItems=[],
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
          addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress0])]),
          fromBlock: 999001,
          indexingContracts: fetchState.indexingContracts,
        },
        {
          partitionId: "1",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress1])]),
          fromBlock: 999001,
          indexingContracts: fetchState.indexingContracts,
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
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.empty(),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        ~reversedNewItems=[
          mockEvent(~blockNumber=6, ~logIndex=2),
          mockEvent(~blockNumber=registeringBlockNumber),
          mockEvent(~blockNumber=registeringBlockNumber - 1, ~logIndex=1),
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
        (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
      ],
      ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress1, mockAddress2])]),
      ~dynamicContracts=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=1,
      ~chainId,
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
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.empty(),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        ~reversedNewItems=[mockEvent(~blockNumber=0, ~logIndex=1)],
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
      dependsOnAddresses: true,
      eventConfigs: [
        (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
      ],
    }

    let fetchState: FetchState.t = {
      partitions: [
        {
          id: "0",
          status: {fetchingStateId: None},
          latestFetchedBlock,
          selection: normalSelection,
          addressesByContractName: Js.Dict.empty(),
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
          addressesByContractName: Js.Dict.empty(),
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
      chainId,
      indexingContracts: Js.Dict.empty(),
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

  // it("Check contains contract address", () => {
  //   let fetchState =
  //     FetchState.make(
  //       ~eventConfigs=[
  //         (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
  //         baseEventConfig,
  //       ],
  //       ~staticContracts=Js.Dict.fromArray([("ContractA", [mockAddress1])]),
  //       ~dynamicContracts=[
  //         makeDynContractRegistration(~contractAddress=mockAddress2, ~blockNumber=1),
  //       ],
  //       ~startBlock=0,
  //       ~endBlock=None,
  //       ~maxAddrInPartition=2,
  //       ~chainId,
  //     )->FetchState.registerDynamicContracts(
  //       [
  //         makeDynContractRegistration(
  //           ~contractType=NftFactory,
  //           ~contractAddress=mockAddress3,
  //           ~blockNumber=2,
  //         ),
  //       ],
  //       ~currentBlockHeight=10,
  //     )

  //   Assert.equal(
  //     fetchState->FetchState.checkContainsRegisteredContractAddress(
  //       ~contractAddress=mockAddress1,
  //       ~contractName="ContractA",
  //       ~chainId=1,
  //     ),
  //     true,
  //   )
  //   Assert.equal(
  //     fetchState->FetchState.checkContainsRegisteredContractAddress(
  //       ~contractAddress=mockAddress2,
  //       ~contractName=(Gravatar :> string),
  //       ~chainId=1,
  //     ),
  //     true,
  //   )
  //   Assert.equal(
  //     fetchState->FetchState.checkContainsRegisteredContractAddress(
  //       ~contractAddress=mockAddress3,
  //       ~contractName=(NftFactory :> string),
  //       ~chainId=1,
  //     ),
  //     true,
  //     ~message=`Should be able to register an event for a new contract, not defined in the initial event configs`,
  //   )
  //   Assert.equal(
  //     fetchState->FetchState.checkContainsRegisteredContractAddress(
  //       ~contractAddress=mockAddress4,
  //       ~contractName=(Gravatar :> string),
  //       ~chainId=1,
  //     ),
  //     false,
  //   )
  // })

  it("Should be fetching at head only when all partitions are fetching at head", () => {
    let fetchState = FetchState.make(
      ~eventConfigs=[
        (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
        (Mock.evmEventConfig(~id="0", ~contractName="ContractB") :> Internal.eventConfig),
      ],
      ~staticContracts=Js.Dict.fromArray([
        ("ContractA", [mockAddress1]),
        ("ContractB", [mockAddress2]),
      ]),
      ~dynamicContracts=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=1,
      ~chainId,
    )

    let q0 = {
      FetchState.partitionId: "0",
      target: Head,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.empty(),
      fromBlock: 0,
      indexingContracts: fetchState.indexingContracts,
    }
    let q1 = {
      FetchState.partitionId: "1",
      target: Head,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.empty(),
      fromBlock: 0,
      indexingContracts: fetchState.indexingContracts,
    }

    Assert.equal(fetchState.isFetchingAtHead, false)

    let fetchStateWithResponse1 =
      fetchState
      ->FetchState.handleQueryResult(
        ~query=q0,
        ~reversedNewItems=[],
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
      ->FetchState.handleQueryResult(
        ~query=q1,
        ~reversedNewItems=[],
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
      ->FetchState.handleQueryResult(
        ~query=q0,
        ~reversedNewItems=[],
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
      ->FetchState.handleQueryResult(
        ~query=q0,
        ~reversedNewItems=[],
        ~currentBlockHeight=999,
        ~latestFetchedBlock=getBlockData(~blockNumber=999),
      )
      ->Result.getExn
      ->FetchState.handleQueryResult(
        ~query=q1,
        ~reversedNewItems=[],
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
      ->FetchState.handleQueryResult(
        ~query=q0,
        ~reversedNewItems=[],
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
      ->FetchState.handleQueryResult(
        ~query=q0,
        ~reversedNewItems=[],
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
    let fetchState = {
      ...makeInitial(),
      endBlock: Some(0),
    }
    Assert.deepEqual(
      fetchState
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "0",
          fromBlock: 0,
          target: EndBlock({toBlock: 0}),
          selection: makeInitial().normalSelection,
          addressesByContractName: Js.Dict.empty(),
          indexingContracts: fetchState.indexingContracts,
        },
        ~reversedNewItems=[mockEvent(~blockNumber=0)],
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
        ~eventConfigs=[baseEventConfig],
        ~staticContracts=Js.Dict.fromArray([("Gravatar", [mockAddress1])]),
        ~dynamicContracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=2,
        ~chainId,
      )
      let fetchState =
        fetchState
        ->FetchState.handleQueryResult(
          ~query={
            partitionId: "0",
            target: Head,
            selection: fetchState.normalSelection,
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress1])]),
            indexingContracts: fetchState.indexingContracts,
            fromBlock: 0,
          },
          ~reversedNewItems=[
            mockEvent(~blockNumber=6, ~logIndex=2),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=1, ~logIndex=1),
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
              addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress2])]),
              fromBlock: 100,
              indexingContracts: fetchState.indexingContracts,
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
        ->FetchState.handleQueryResult(
          ~query=queryA,
          ~latestFetchedBlock=getBlockData(~blockNumber=400),
          ~currentBlockHeight,
          ~reversedNewItems=[],
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
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
            fromBlock: 200,
            indexingContracts: fetchState.indexingContracts,
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
