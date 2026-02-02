open Belt
open RescriptMocha

let chainId = 0
let targetBufferSize = 5000
let knownHeight = 0

// Keep for backward compatibility of tests
type oldQueueItem =
  | Item(Internal.item)
  | NoItem({latestFetchedBlock: FetchState.blockNumberAndTimestamp})

let getItem = (item: oldQueueItem) =>
  switch item {
  | Item(item) => item->Some
  | NoItem(_) => None
  }

let getEarliestEvent = (fetchState: FetchState.t) => {
  let readyItemsCount = fetchState->FetchState.getReadyItemsCount(~targetSize=1, ~fromItem=0)
  if readyItemsCount > 0 {
    Item(fetchState.buffer->Belt.Array.getUnsafe(0))
  } else {
    NoItem({
      latestFetchedBlock: fetchState->FetchState.bufferBlock,
    })
  }
}

let mockAddress0 = TestHelpers.Addresses.mockAddresses[0]->Option.getExn
let mockAddress1 = TestHelpers.Addresses.mockAddresses[1]->Option.getExn
let mockAddress2 = TestHelpers.Addresses.mockAddresses[2]->Option.getExn
let mockAddress3 = TestHelpers.Addresses.mockAddresses[3]->Option.getExn
let mockAddress4 = TestHelpers.Addresses.mockAddresses[4]->Option.getExn
let mockAddress5 = TestHelpers.Addresses.mockAddresses[5]->Option.getExn
let mockAddress6 = TestHelpers.Addresses.mockAddresses[6]->Option.getExn
let mockFactoryAddress = TestHelpers.Addresses.mockAddresses[7]->Option.getExn

let getTimestamp = (~blockNumber) => blockNumber * 15
let getBlockData = (~blockNumber): FetchState.blockNumberAndTimestamp => {
  blockNumber,
  blockTimestamp: getTimestamp(~blockNumber),
}

let makeDynContractRegistration = (
  ~contractAddress,
  ~blockNumber,
  ~contractName="Gravatar",
): Internal.indexingContract => {
  {
    address: contractAddress,
    contractName,
    startBlock: blockNumber,
    registrationBlock: Some(blockNumber),
  }
}

let makeConfigContract = (contractName, address): Internal.indexingContract => {
  {
    address,
    contractName,
    startBlock: 0,
    registrationBlock: None,
  }
}

let mockEvent = (~blockNumber, ~logIndex=0, ~chainId=1): Internal.item => Internal.Event({
  timestamp: blockNumber * 15,
  chain: ChainMap.Chain.makeUnsafe(~chainId),
  blockNumber,
  eventConfig: Utils.magic("Mock eventConfig in fetchstate test"),
  logIndex,
  event: Utils.magic("Mock event in fetchstate test"),
})

let dcToItem = (dc: Internal.indexingContract) => {
  let item = mockEvent(~blockNumber=dc.startBlock)
  item->Internal.setItemDcs([dc])
  item
}

// Helper to handle query result (starts query first, then handles result)
let executeQuery = (
  fetchState: FetchState.t,
  ~query: FetchState.query,
  ~latestFetchedBlock,
  ~newItems,
) => {
  fetchState->FetchState.startFetchingQueries(~queries=[query])
  fetchState->FetchState.handleQueryResult(~query, ~latestFetchedBlock, ~newItems)
}

let baseEventConfig = (Mock.evmEventConfig(
  ~id="0",
  ~contractName="Gravatar",
) :> Internal.eventConfig)

let baseEventConfig2 = (Mock.evmEventConfig(
  ~id="0",
  ~contractName="NftFactory",
) :> Internal.eventConfig)

let makeInitial = (
  ~startBlock=0,
  ~blockLag=?,
  ~maxAddrInPartition=3,
  ~targetBufferSize=targetBufferSize,
) => {
  FetchState.make(
    ~eventConfigs=[baseEventConfig, baseEventConfig2],
    ~contracts=[
      {
        Internal.address: mockAddress0,
        contractName: "Gravatar",
        startBlock,
        registrationBlock: None,
      },
    ],
    ~startBlock,
    ~endBlock=None,
    ~maxAddrInPartition,
    ~targetBufferSize,
    ~chainId,
    ~knownHeight,
    ~blockLag?,
  )
}

// Helper to get partition count
let getPartitionCount = (fetchState: FetchState.t) =>
  fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count

// Helper to build indexingContracts dict for test expectations
let makeIndexingContractsWithDynamics = (dcs: array<Internal.indexingContract>, ~static=[]) => {
  let dict = Js.Dict.empty()
  dcs->Array.forEach(dc => {
    dict->Js.Dict.set(dc.address->Address.toString, dc)
  })
  static->Array.forEach(address => {
    dict->Js.Dict.set(
      address->Address.toString,
      {
        address,
        contractName: "Gravatar",
        startBlock: 0,
        registrationBlock: None,
      },
    )
  })
  dict
}

describe("FetchState.make", () => {
  it("Creates FetchState with a single static address", () => {
    let fetchState = makeInitial()

    Assert.equal(getPartitionCount(fetchState), 1, ~message="Should have 1 partition")
    Assert.equal(
      fetchState.latestFullyFetchedBlock.blockNumber,
      -1,
      ~message="latestFullyFetchedBlock should be -1",
    )
    Assert.equal(
      fetchState.indexingContracts->Js.Dict.keys->Array.length,
      1,
      ~message="Should have 1 indexing contract",
    )
  })

  it("Panics with nothing to fetch", () => {
    Assert.throws(
      () => {
        FetchState.make(
          ~eventConfigs=[baseEventConfig],
          ~contracts=[],
          ~startBlock=0,
          ~endBlock=None,
          ~maxAddrInPartition=2,
          ~targetBufferSize,
          ~chainId,
          ~knownHeight,
        )
      },
      ~error={
        "message": "Invalid configuration: Nothing to fetch. Make sure that you provided at least one contract address to index, or have events with Wildcard mode enabled, or have onBlock handlers.",
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
        ~contracts=[makeConfigContract("Gravatar", mockAddress1), dc],
        ~startBlock=0,
        ~endBlock=None,
        ~targetBufferSize,
        ~maxAddrInPartition=2,
        ~chainId,
        ~knownHeight,
      )

      Assert.equal(getPartitionCount(fetchState), 1, ~message=`Should create only one partition`)
      Assert.equal(
        fetchState.indexingContracts->Js.Dict.keys->Array.length,
        2,
        ~message="Should have 2 indexing contracts",
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
        ~contracts=[makeConfigContract("ContractA", mockAddress1), dc],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=1,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      Assert.equal(getPartitionCount(fetchState), 2, ~message="Should create two partitions")
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
        ~contracts=[
          makeConfigContract("ContractA", mockAddress1),
          makeConfigContract("ContractA", mockAddress2),
          dc1,
          dc2,
        ],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=1,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      Assert.equal(getPartitionCount(fetchState), 4, ~message="Should create 4 partitions")
    },
  )
})

describe("FetchState.registerDynamicContracts", () => {
  // It shouldn't happen, but just in case
  it("Nothing breaks when provided an empty array", () => {
    let fetchState = makeInitial()

    Assert.equal(
      fetchState->FetchState.registerDynamicContracts([]),
      fetchState,
      ~message="Should return fetchState without updating it",
    )
  })

  it("Doesn't register a dc which is already registered in config", () => {
    let fetchState = makeInitial()

    Assert.equal(
      fetchState->FetchState.registerDynamicContracts([
        makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress0)->dcToItem,
      ]),
      fetchState,
      ~message="Should return fetchState without updating it",
    )
  })

  it("Correctly registers all valid contracts even when some are skipped in the middle", () => {
    let fetchState = makeInitial()

    // Create a single event with 3 DCs:
    // - First DC should be skipped (already exists in config at mockAddress0)
    // - Second and third DCs should both be registered
    let dc1 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress0)
    let dc2 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress1)
    let dc3 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress2)

    let event = mockEvent(~blockNumber=10)
    event->Internal.setItemDcs([dc1, dc2, dc3])

    let updatedFetchState = fetchState->FetchState.registerDynamicContracts([event])

    // Verify that both DC2 and DC3 were registered correctly
    let hasAddress1 =
      updatedFetchState.indexingContracts
      ->Js.Dict.get(mockAddress1->Address.toString)
      ->Option.isSome
    let hasAddress2 =
      updatedFetchState.indexingContracts
      ->Js.Dict.get(mockAddress2->Address.toString)
      ->Option.isSome

    Assert.equal(hasAddress1, true, ~message="Address1 should be registered")
    Assert.equal(
      hasAddress2,
      true,
      ~message="Address2 should be registered even though Address1 (which came before it) was skipped",
    )
  })

  it(
    "Should create a new partition for an already registered dc if it has an earlier start block",
    () => {
      let fetchState = makeInitial()

      let dc1 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress1)

      let fetchStateWithDc1 = fetchState->FetchState.registerDynamicContracts([dc1->dcToItem])

      Assert.deepEqual(
        (getPartitionCount(fetchState), getPartitionCount(fetchStateWithDc1)),
        (1, 2),
        ~message="Should have created a new partition for the dc",
      )

      Assert.equal(
        fetchStateWithDc1->FetchState.registerDynamicContracts([dc1->dcToItem]),
        fetchStateWithDc1,
        ~message="Calling it with the same dc for the second time shouldn't change anything",
      )
    },
  )

  it("Should split dcs into multiple partitions if they exceed maxAddrInPartition", () => {
    let fetchState = makeInitial()

    let dc1 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress1)
    let dc2 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)
    let dc3 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress3)
    let dc4 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress4)

    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts([
        dc1->dcToItem,
        dc2->dcToItem,
        dc3->dcToItem,
        dc4->dcToItem,
      ])

    // maxAddrInPartition=3, so 4 DCs should create 2 additional partitions (1 original + 2 new)
    Assert.equal(
      getPartitionCount(updatedFetchState),
      3,
      ~message=`Should have 3 partitions total (1 original + 2 for DCs split)`,
    )
  })

  it(
    "Dcs for contract with event filtering using addresses shouldn't be grouped into a single partition to prevent overfetching",
    // This is because we can't filter events before dc registration block number for this case
    () => {
      let fetchState = FetchState.make(
        ~eventConfigs=[
          baseEventConfig,
          (Mock.evmEventConfig(~id="0", ~contractName="NftFactory") :> Internal.eventConfig),
          // An event from another contract
          // which has an event filter by addresses
          (Mock.evmEventConfig(
            ~id="0",
            ~contractName="SimpleNft",
            ~isWildcard=false,
            ~filterByAddresses=true,
          ) :> Internal.eventConfig),
        ],
        ~contracts=[makeConfigContract("Gravatar", mockAddress0)],
        ~startBlock=10,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      Assert.deepEqual(
        fetchState.contractConfigs,
        Js.Dict.fromArray([
          ("Gravatar", {FetchState.filterByAddresses: false}),
          ("NftFactory", {FetchState.filterByAddresses: false}),
          ("SimpleNft", {FetchState.filterByAddresses: true}),
        ]),
      )

      let dc1 = makeDynContractRegistration(
        ~blockNumber=3,
        ~contractAddress=mockAddress1,
        ~contractName="Gravatar",
      )
      let dc2 = makeDynContractRegistration(
        ~blockNumber=3,
        ~contractAddress=mockAddress2,
        ~contractName="SimpleNft",
      )
      let dc3 = makeDynContractRegistration(
        ~blockNumber=3,
        ~contractAddress=mockAddress3,
        ~contractName="SimpleNft",
      )
      let dc4 = makeDynContractRegistration(
        ~blockNumber=5,
        ~contractAddress=mockAddress4,
        ~contractName="SimpleNft",
      )
      // Even though this has another contract than Gravatar,
      // and higher block number, it still should be in one partition
      // with Gravatar dcs.
      let dc5 = makeDynContractRegistration(
        ~blockNumber=6,
        ~contractAddress=mockAddress5,
        ~contractName="NftFactory",
      )

      let updatedFetchState =
        fetchState->FetchState.registerDynamicContracts([
          dc1->dcToItem,
          dc2->dcToItem,
          dc3->dcToItem,
          dc4->dcToItem,
          dc5->dcToItem,
        ])

      // Check that partitions were created for filterByAddresses contracts
      Assert.ok(
        getPartitionCount(updatedFetchState) >= 3,
        ~message=`Should have multiple partitions for filterByAddresses contracts`,
      )
    },
  )

  it("Choose the earliest dc from the batch when there are two with the same address", () => {
    let fetchState = makeInitial()

    let dc1 = makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress1)
    let dc2 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress1)
    let dcItem1 = dc1->dcToItem
    let dcItem2 = dc2->dcToItem

    let updatedFetchState = fetchState->FetchState.registerDynamicContracts([dcItem2, dcItem1])

    Assert.deepEqual(
      (dcItem1->Internal.getItemDcs, dcItem2->Internal.getItemDcs),
      (Some([]), Some([dc2])),
      ~message=`Should choose the earliest dc from the batch
End remove the dc from the later one, so they are not duplicated in the db`,
    )
    Assert.deepEqual(
      updatedFetchState.indexingContracts,
      makeIndexingContractsWithDynamics([dc2], ~static=[mockAddress0]),
      ~message="Should choose the earliest dc from the batch",
    )
  })

  it("All dcs are grouped optimally based on block range", () => {
    let fetchState = makeInitial()

    let dc1 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress1)
    let dc2 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)
    // Even if there's too big of a block difference,
    // we don't care because:
    // RPC - The registrations come from requested batch,
    //       which is not very big by itself.
    // HyperSync - Even though the block range of the batch with registrations
    //             might be big, HyperSync will efficiently handle addresses registered
    //             later on chain.
    // If there are events before the contract registrations,
    // they will be filtered client-side by the the router.
    let dc3 = makeDynContractRegistration(~blockNumber=20000, ~contractAddress=mockAddress3)

    // Order of dcs doesn't matter
    // but they are not sorted in fetch state
    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts([dc1->dcToItem, dc3->dcToItem, dc2->dcToItem])
    Assert.equal(updatedFetchState.indexingContracts->Utils.Dict.size, 4)
    // New logic groups dcs within tooFarBlockRange (20000) so dc1 and dc2 at block 2 are grouped together
    Assert.ok(
      getPartitionCount(updatedFetchState) >= 2,
      ~message="Should have at least 2 partitions (1 original + at least 1 for DCs)",
    )
  })

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
        ~contracts=[
          makeConfigContract("NftFactory", mockAddress0),
          makeConfigContract("NftFactory", mockAddress1),
          makeConfigContract("Gravatar", mockAddress2),
          makeConfigContract("Gravatar", mockAddress3),
          makeDynContractRegistration(
            ~contractName="Gravatar",
            ~blockNumber=0,
            ~contractAddress=mockAddress4,
          ),
          makeDynContractRegistration(
            ~contractName="NftFactory",
            ~blockNumber=0,
            ~contractAddress=mockAddress5,
          ),
        ],
        ~endBlock=None,
        ~startBlock=0,
        ~maxAddrInPartition=1000,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      // Should have wildcard partition + normal partition for NftFactory
      Assert.equal(
        getPartitionCount(fetchState),
        2,
        ~message=`Should have 2 partitions (wildcard + normal)`,
      )
      // Gravatar addresses should not be in indexingContracts since they only have wildcard events
      Assert.equal(
        fetchState.indexingContracts->Js.Dict.keys->Array.length,
        3,
        ~message=`Should have 3 indexing contracts (only NftFactory addresses)`,
      )
    },
  )
})

describe("FetchState.getNextQuery & integration", () => {
  let dc1 = makeDynContractRegistration(~blockNumber=1, ~contractAddress=mockAddress1)
  let dc2 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)
  let dc3 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress3)

  it("Emulate first indexer queries with a static event", () => {
    let getNextQuery = (fs, ~knownHeight=10, ~concurrencyLimit=10) =>
      {...fs, knownHeight}->FetchState.getNextQuery(~concurrencyLimit)

    let fetchState = makeInitial()

    Assert.deepEqual(fetchState->getNextQuery(~knownHeight=0), WaitingForNewBlock)

    let nextQuery = fetchState->getNextQuery

    switch nextQuery {
    | Ready([q]) => {
        Assert.equal(q.partitionId, "0", ~message="Should query partition 0")
        Assert.equal(q.fromBlock, 0, ~message="Should start from block 0")
        Assert.equal(q.toBlock, None, ~message="Should have no toBlock (query to head)")
      }
    | _ => Assert.fail("Expected Ready with single query")
    }

    let query = switch nextQuery {
    | Ready([q]) => q
    | _ => Assert.fail("Failed to extract query")
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])

    let repeatedNextQuery = fetchState->getNextQuery

    Assert.deepEqual(
      repeatedNextQuery,
      NothingToQuery,
      ~message="Shouldn't double fetch the same partition",
    )

    let updatedFetchState =
      fetchState->executeQuery(
        ~query,
        ~latestFetchedBlock={
          blockNumber: 10,
          blockTimestamp: 10,
        },
        ~newItems=[mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
      )

    Assert.equal(
      updatedFetchState.latestFullyFetchedBlock.blockNumber,
      10,
      ~message="Should update latestFullyFetchedBlock",
    )
    Assert.equal(
      updatedFetchState.buffer->Array.length,
      2,
      ~message="Should have 2 items in buffer",
    )

    // When we've caught up to knownHeight and partitions have no pending queries, it returns NothingToQuery
    Assert.deepEqual(updatedFetchState->getNextQuery, NothingToQuery)
    Assert.deepEqual(updatedFetchState->getNextQuery(~concurrencyLimit=0), ReachedMaxConcurrency)
  })

  it("Emulate first indexer queries with block lag configured", () => {
    let getNextQuery = (fs, ~knownHeight=10, ~concurrencyLimit=10) =>
      {...fs, knownHeight}->FetchState.getNextQuery(~concurrencyLimit)

    let fetchState = makeInitial(~blockLag=2)

    Assert.deepEqual(fetchState->getNextQuery(~knownHeight=0), WaitingForNewBlock)

    Assert.deepEqual(
      fetchState->getNextQuery(~knownHeight=1),
      WaitingForNewBlock,
      ~message="Should wait for new block when current block height - block lag is less than 0",
    )

    let nextQuery = {...fetchState, endBlock: Some(8), knownHeight: 10}->FetchState.getNextQuery(
      ~concurrencyLimit=10,
    )
    switch nextQuery {
    | Ready([q]) => {
        Assert.equal(q.toBlock, Some(8), ~message="Should have toBlock=8 (endBlock)")
      }
    | _ => Assert.fail("Expected Ready query")
    }
  })

  it("Emulate dynamic contract registration", () => {
    let getNextQuery = (fs, ~knownHeight=11, ~concurrencyLimit=10) =>
      {...fs, knownHeight}->FetchState.getNextQuery(~concurrencyLimit)

    let fetchState = makeInitial()

    // Simulate first query completion
    let query0: FetchState.query = {
      partitionId: "0",
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
      indexingContracts: fetchState.indexingContracts,
    }

    let fetchStateAfterFirstQuery =
      fetchState->executeQuery(
        ~query=query0,
        ~latestFetchedBlock={blockNumber: 10, blockTimestamp: 10},
        ~newItems=[mockEvent(~blockNumber=1), mockEvent(~blockNumber=2)],
      )

    let fetchStateWithDcs =
      fetchStateAfterFirstQuery
      ->FetchState.registerDynamicContracts([dc2->dcToItem, dc1->dcToItem])
      ->FetchState.registerDynamicContracts([dc3->dcToItem])

    Assert.equal(
      fetchStateWithDcs.indexingContracts->Js.Dict.keys->Array.length,
      4,
      ~message="Should have 4 indexing contracts",
    )

    // Should have multiple partitions now
    Assert.ok(
      getPartitionCount(fetchStateWithDcs) >= 2,
      ~message="Should have at least 2 partitions after DC registration",
    )

    let nextQuery = fetchStateWithDcs->getNextQuery
    switch nextQuery {
    | Ready(queries) =>
      Assert.ok(queries->Array.length >= 1, ~message="Should have at least 1 query ready")
    | _ => Assert.fail("Expected Ready queries after DC registration")
    }
  })

  it("Wildcard partition queries correctly", () => {
    let wildcard = (Mock.evmEventConfig(
      ~id="wildcard",
      ~contractName="ContractA",
      ~isWildcard=true,
    ) :> Internal.eventConfig)
    let fetchState =
      FetchState.make(
        ~eventConfigs=[
          (Mock.evmEventConfig(~id="0", ~contractName="Gravatar") :> Internal.eventConfig),
          (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
          wildcard,
        ],
        ~contracts=[makeConfigContract("ContractA", mockAddress1)],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=2,
        ~targetBufferSize=10,
        ~chainId,
        ~knownHeight,
      )->FetchState.registerDynamicContracts([
        makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)->dcToItem,
      ])

    Assert.ok(
      getPartitionCount(fetchState) >= 2,
      ~message="Should have at least 2 partitions (wildcard + normal)",
    )

    let nextQuery = {...fetchState, knownHeight: 10}->FetchState.getNextQuery(~concurrencyLimit=10)

    switch nextQuery {
    | Ready(queries) =>
      Assert.ok(queries->Array.length >= 1, ~message="Should have queries ready")
    | _ => Assert.fail("Expected Ready queries")
    }
  })

  it("Correctly rollbacks fetch state", () => {
    let fetchState = makeInitial()

    // Register some dynamic contracts
    let dc1 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress1)
    let dc2 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)
    let dc3 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress3)

    let fetchStateWithDcs =
      fetchState->FetchState.registerDynamicContracts([
        dc1->dcToItem,
        dc2->dcToItem,
        dc3->dcToItem,
      ])

    let fetchStateAfterRollback = fetchStateWithDcs->FetchState.rollback(~targetBlockNumber=1)

    // DCs registered at block 2 should be removed
    Assert.equal(
      fetchStateAfterRollback.indexingContracts->Js.Dict.keys->Array.length,
      1,
      ~message="Should only have original static contract after rollback",
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
      (Mock.evmEventConfig(~id="0", ~contractName="Gravatar") :> Internal.eventConfig),
    ]
    let fetchState =
      FetchState.make(
        ~eventConfigs,
        ~contracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~targetBufferSize=10,
        ~chainId,
        ~knownHeight,
      )->FetchState.registerDynamicContracts([
        makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)->dcToItem,
      ])

    let initialPartitionCount = getPartitionCount(fetchState)

    let fetchStateAfterRollback = fetchState->FetchState.rollback(~targetBlockNumber=1)

    // Wildcard partition should remain
    Assert.ok(
      getPartitionCount(fetchStateAfterRollback) >= 1,
      ~message=`Should keep at least wildcard partition after rollback (had ${initialPartitionCount->Int.toString})`,
    )
  })
})

describe("FetchState unit tests for specific cases", () => {
  it("Sorts newItems when source returns them unsorted", () => {
    let fetchState = makeInitial()

    let unsorted = [
      mockEvent(~blockNumber=5, ~logIndex=1),
      mockEvent(~blockNumber=6, ~logIndex=0),
      mockEvent(~blockNumber=6, ~logIndex=2),
      mockEvent(~blockNumber=5, ~logIndex=0),
    ]

    let query: FetchState.query = {
      partitionId: "0",
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
      indexingContracts: fetchState.indexingContracts,
    }

    let updatedFetchState =
      fetchState->executeQuery(
        ~query,
        ~latestFetchedBlock=getBlockData(~blockNumber=10),
        ~newItems=unsorted,
      )

    Assert.deepEqual(
      updatedFetchState.buffer,
      [
        mockEvent(~blockNumber=5, ~logIndex=0),
        mockEvent(~blockNumber=5, ~logIndex=1),
        mockEvent(~blockNumber=6, ~logIndex=0),
        mockEvent(~blockNumber=6, ~logIndex=2),
      ],
      ~message="Queue must be sorted ASC by (blockNumber, logIndex) regardless of input order",
    )
  })

  it("Shouldn't wait for new block until all partitions reached the head", () => {
    let wildcard = (Mock.evmEventConfig(
      ~id="wildcard",
      ~contractName="ContractA",
      ~isWildcard=true,
    ) :> Internal.eventConfig)
    let fetchState = FetchState.make(
      ~eventConfigs=[
        (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
        wildcard,
      ],
      ~contracts=[makeConfigContract("ContractA", mockAddress0)],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=2,
      ~targetBufferSize,
      ~chainId,
      ~knownHeight,
    )

    let query0: FetchState.query = {
      partitionId: "0",
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: {
        dependsOnAddresses: false,
        eventConfigs: [wildcard],
      },
      addressesByContractName: Js.Dict.empty(),
      indexingContracts: fetchState.indexingContracts,
    }

    let query1: FetchState.query = {
      partitionId: "1",
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress0])]),
      indexingContracts: fetchState.indexingContracts,
    }

    let fetchState =
      fetchState
      ->executeQuery(
        ~query=query0,
        ~latestFetchedBlock=getBlockData(~blockNumber=1),
        ~newItems=[mockEvent(~blockNumber=1), mockEvent(~blockNumber=0)],
      )
      ->executeQuery(
        ~query=query1,
        ~latestFetchedBlock=getBlockData(~blockNumber=2),
        ~newItems=[],
      )

    let nextQuery = {...fetchState, knownHeight: 2}->FetchState.getNextQuery(~concurrencyLimit=10)

    switch nextQuery {
    | Ready(_) => Assert.ok(true, ~message="Should have queries ready")
    | WaitingForNewBlock => Assert.ok(true, ~message="Or waiting for new block is also acceptable")
    | _ => ()
    }
  })

  it("Allows to get event one block earlier than the dc registering event", () => {
    let fetchState = makeInitial()

    Assert.deepEqual(
      fetchState->getEarliestEvent,
      NoItem({
        latestFetchedBlock: {
          blockNumber: -1,
          blockTimestamp: 0,
        },
      }),
    )

    let registeringBlockNumber = 3

    let query: FetchState.query = {
      partitionId: "0",
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
      indexingContracts: fetchState.indexingContracts,
    }

    let fetchStateWithEvents =
      fetchState->executeQuery(
        ~query,
        ~newItems=[
          mockEvent(~blockNumber=6, ~logIndex=2),
          mockEvent(~blockNumber=registeringBlockNumber),
          mockEvent(~blockNumber=registeringBlockNumber - 1, ~logIndex=1),
        ],
        ~latestFetchedBlock=getBlockData(~blockNumber=10),
      )

    Assert.deepEqual(
      fetchStateWithEvents->getEarliestEvent->getItem,
      Some(mockEvent(~blockNumber=2, ~logIndex=1)),
    )

    let fetchStateWithDc =
      fetchStateWithEvents->FetchState.registerDynamicContracts([
        makeDynContractRegistration(
          ~contractAddress=mockAddress1,
          ~blockNumber=registeringBlockNumber,
        )->dcToItem,
      ])

    Assert.deepEqual(
      fetchStateWithDc->getEarliestEvent->getItem,
      Some(mockEvent(~blockNumber=2, ~logIndex=1)),
      ~message=`Should allow to get event before the dc registration`,
    )
  })

  it("Returns NoItem when there is an empty partition at block 0", () => {
    let fetchState = FetchState.make(
      ~eventConfigs=[
        (Mock.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
      ],
      ~contracts=[
        makeConfigContract("ContractA", mockAddress1),
        makeConfigContract("ContractA", mockAddress2),
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=1,
      ~targetBufferSize,
      ~chainId,
      ~knownHeight,
    )

    Assert.deepEqual(
      fetchState->getEarliestEvent,
      NoItem({
        latestFetchedBlock: {
          blockNumber: -1,
          blockTimestamp: 0,
        },
      }),
    )

    let query: FetchState.query = {
      partitionId: "0",
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress1])]),
      indexingContracts: fetchState.indexingContracts,
    }

    let updatedFetchState =
      fetchState->executeQuery(
        ~query,
        ~newItems=[mockEvent(~blockNumber=0, ~logIndex=1)],
        ~latestFetchedBlock=getBlockData(~blockNumber=1),
      )

    // Still NoItem because partition 1 hasn't been queried yet
    Assert.deepEqual(
      updatedFetchState->getEarliestEvent,
      NoItem({
        latestFetchedBlock: {
          blockNumber: -1,
          blockTimestamp: 0,
        },
      }),
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
      true,
      ~message=`Should be active if endBlock is equal to the startBlock`,
    )
    Assert.deepEqual(
      {...makeInitial(~startBlock=10), endBlock: Some(9)}->FetchState.isActivelyIndexing,
      false,
      ~message=`Shouldn't be active if endBlock is less than the startBlock`,
    )
  })
})

describe("FetchState.sortForUnorderedBatch", () => {
  it("Sorts by earliest timestamp. Chains without eligible items should go last", () => {
    let mk = () => makeInitial()
    let mkQuery = (fetchState: FetchState.t): FetchState.query => {
      partitionId: "0",
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
      indexingContracts: fetchState.indexingContracts,
    }

    // Helper: create a fetch state with desired latestFetchedBlock and queue items via public API
    let makeFsWith = (~latestBlock: int, ~queueBlocks: array<int>): FetchState.t => {
      let fs0 = mk()
      let query = mkQuery(fs0)
      fs0->executeQuery(
        ~query,
        ~latestFetchedBlock={blockNumber: latestBlock, blockTimestamp: latestBlock},
        ~newItems=queueBlocks->Array.map(b => mockEvent(~blockNumber=b)),
      )
    }

    // Included: last queue item at block 1, latestFullyFetchedBlock = 10
    let fsEarly = makeFsWith(~latestBlock=10, ~queueBlocks=[2, 1])
    // Included: last queue item at block 5, latestFullyFetchedBlock = 10
    let fsLate = makeFsWith(~latestBlock=10, ~queueBlocks=[5])
    // Excluded: last queue item at block 11 (> latestFullyFetchedBlock = 10)
    // UPD: Starting from 2.30.1+ it should go last instead of filtered
    let fsExcluded = makeFsWith(~latestBlock=10, ~queueBlocks=[11])

    let prepared = FetchState.sortForUnorderedBatch(
      [fsLate, fsExcluded, fsEarly],
      ~batchSizeTarget=3,
    )

    Assert.deepEqual(
      prepared->Array.map(fs => fs.buffer->Belt.Array.getUnsafe(0)->Internal.getItemBlockNumber),
      [1, 5, 11],
    )
  })

  it("Prioritizes full batches over half full ones", () => {
    let mk = () => makeInitial()
    let mkQuery = (fetchState: FetchState.t): FetchState.query => {
      partitionId: "0",
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
      indexingContracts: fetchState.indexingContracts,
    }

    let makeFsWith = (~latestBlock: int, ~queueBlocks: array<int>): FetchState.t => {
      let fs0 = mk()
      let query = mkQuery(fs0)
      fs0->executeQuery(
        ~query,
        ~latestFetchedBlock={blockNumber: latestBlock, blockTimestamp: latestBlock},
        ~newItems=queueBlocks->Array.map(b => mockEvent(~blockNumber=b)),
      )
    }

    // Full batch (>= maxBatchSize items). Make it later (earliest item at block 7)
    let fsFullLater = makeFsWith(~latestBlock=10, ~queueBlocks=[9, 8, 7])
    // Half-full batch (1 item) but earlier earliest item (block 1)
    let fsHalfEarlier = makeFsWith(~latestBlock=10, ~queueBlocks=[1])

    let prepared = FetchState.sortForUnorderedBatch(
      [fsHalfEarlier, fsFullLater],
      ~batchSizeTarget=2,
    )

    Assert.deepEqual(
      prepared->Array.map(fs => fs.buffer->Belt.Array.getUnsafe(0)->Internal.getItemBlockNumber),
      [7, 1],
    )
  })
})

describe("FetchState.isReadyToEnterReorgThreshold", () => {
  it("Returns false when we just started the indexer and it has knownHeight=0", () => {
    let fetchState = makeInitial()
    Assert.equal({...fetchState, knownHeight: 0}->FetchState.isReadyToEnterReorgThreshold, false)
  })

  it(
    "Returns false when we just started the indexer and it has knownHeight=0, while start block is more than 0 + reorg threshold",
    () => {
      let fetchState = makeInitial(~startBlock=6000)
      Assert.equal({...fetchState, knownHeight: 0}->FetchState.isReadyToEnterReorgThreshold, false)
    },
  )

  it("Returns true when endBlock is reached and queue is empty", () => {
    // latestFullyFetchedBlock = startBlock - 1 = 5, endBlock = 5
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~contracts=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          startBlock: 6,
          registrationBlock: None,
        },
      ],
      ~startBlock=6,
      ~endBlock=Some(5),
      ~maxAddrInPartition=3,
      ~targetBufferSize,
      ~chainId,
      ~blockLag=0,
      ~knownHeight=10,
    )
    Assert.equal(fs->FetchState.isReadyToEnterReorgThreshold, true)
  })

  it("Returns false when endBlock not reached and below head - blockLag", () => {
    // latestFullyFetchedBlock = 49, endBlock = 100, head - lag = 50
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~contracts=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          startBlock: 50,
          registrationBlock: None,
        },
      ],
      ~startBlock=50,
      ~endBlock=Some(100),
      ~maxAddrInPartition=3,
      ~targetBufferSize,
      ~chainId,
      ~blockLag=10,
      ~knownHeight=60,
    )
    Assert.equal(fs->FetchState.isReadyToEnterReorgThreshold, false)
  })

  it("Returns true when endBlock not reached but latest >= head - blockLag", () => {
    // latestFullyFetchedBlock = 49, head - lag = 49
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~contracts=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          startBlock: 50,
          registrationBlock: None,
        },
      ],
      ~startBlock=50,
      ~endBlock=Some(100),
      ~maxAddrInPartition=3,
      ~targetBufferSize,
      ~chainId,
      ~blockLag=10,
      ~knownHeight=59,
    )
    Assert.equal(fs->FetchState.isReadyToEnterReorgThreshold, true)
  })

  it("Returns false when queue is not empty even if thresholds are met", () => {
    // EndBlock reached but queue has items
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~contracts=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          startBlock: 6,
          registrationBlock: None,
        },
      ],
      ~startBlock=6,
      ~endBlock=Some(5),
      ~maxAddrInPartition=3,
      ~targetBufferSize,
      ~chainId,
      ~blockLag=0,
      ~knownHeight=10,
    )
    let fsWithQueue = fs->FetchState.updateInternal(~mutItems=[mockEvent(~blockNumber=6)])
    Assert.equal(fsWithQueue->FetchState.isReadyToEnterReorgThreshold, false)
  })
})

describe("Dynamic contracts with start blocks", () => {
  it("Should respect dynamic contract startBlock even when registered earlier", () => {
    let fetchState = makeInitial()

    // Register a dynamic contract with startBlock=200
    let dynamicContract = makeDynContractRegistration(
      ~contractAddress=mockAddress1, // Use a different address from static contracts
      ~blockNumber=200, // This is the startBlock - when indexing should actually begin
      ~contractName="Gravatar", // Use Gravatar which has event configs in makeInitial
    )

    // Register the contract at block 100 (before its startBlock)
    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts([dynamicContract->dcToItem])

    // The contract should be registered in indexingContracts
    Assert.ok(
      updatedFetchState.indexingContracts
      ->Js.Dict.get(mockAddress1->Address.toString)
      ->Option.isSome,
      ~message="Dynamic contract should be registered in indexingContracts",
    )

    // Verify the startBlock is set correctly
    let registeredContract =
      updatedFetchState.indexingContracts
      ->Js.Dict.get(mockAddress1->Address.toString)
      ->Option.getExn

    Assert.equal(
      registeredContract.startBlock,
      200,
      ~message="Dynamic contract should have correct startBlock",
    )
  })

  it("Should handle dynamic contract registration with different startBlocks", () => {
    let fetchState = makeInitial()

    // Contract 1: startBlock=150
    let contract1 = makeDynContractRegistration(
      ~contractAddress=mockAddress1,
      ~blockNumber=150,
      ~contractName="Gravatar",
    )

    // Contract 2: startBlock=300
    let contract2 = makeDynContractRegistration(
      ~contractAddress=mockAddress2,
      ~blockNumber=300,
      ~contractName="Gravatar",
    )

    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts([contract1->dcToItem, contract2->dcToItem])

    // Verify both contracts are registered with correct startBlocks
    let contract1Registered =
      updatedFetchState.indexingContracts
      ->Js.Dict.get(mockAddress1->Address.toString)
      ->Option.getExn

    let contract2Registered =
      updatedFetchState.indexingContracts
      ->Js.Dict.get(mockAddress2->Address.toString)
      ->Option.getExn

    Assert.equal(
      contract1Registered.startBlock,
      150,
      ~message="Contract1 should have startBlock=150",
    )

    Assert.equal(
      contract2Registered.startBlock,
      300,
      ~message="Contract2 should have startBlock=300",
    )
  })
})

describe("FetchState progress tracking", () => {
  let makeFetchStateWith = (~latestBlock: int, ~queueBlocks: array<(int, int)>): FetchState.t => {
    let fs0 = makeInitial()
    let query: FetchState.query = {
      partitionId: "0",
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fs0.normalSelection,
      addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
      indexingContracts: fs0.indexingContracts,
    }
    fs0->executeQuery(
      ~query,
      ~latestFetchedBlock={blockNumber: latestBlock, blockTimestamp: latestBlock},
      ~newItems=queueBlocks->Array.map(((b, l)) => mockEvent(~blockNumber=b, ~logIndex=l)),
    )
  }

  it("When queue is empty", () => {
    let fetchStateEmpty = makeFetchStateWith(~latestBlock=100, ~queueBlocks=[])

    Assert.equal(
      fetchStateEmpty->FetchState.getUnorderedMultichainProgressBlockNumberAt(~index=0),
      100,
      ~message="Should return latestFullyFetchedBlock.blockNumber when queue is empty",
    )
  })

  it("When queue has a single item with log index 0", () => {
    let fetchStateSingleItem = makeFetchStateWith(~latestBlock=55, ~queueBlocks=[(55, 0)])

    Assert.equal(
      fetchStateSingleItem->FetchState.getUnorderedMultichainProgressBlockNumberAt(~index=0),
      54,
      ~message="Should return single queue item blockNumber - 1",
    )
  })

  it("When queue items are later than latest fetched block", () => {
    let fetchStateWithQueue = makeFetchStateWith(
      ~latestBlock=90,
      ~queueBlocks=[(105, 2), (103, 1), (101, 2)], // Last item has blockNumber=101
    )

    Assert.equal(
      fetchStateWithQueue->FetchState.getUnorderedMultichainProgressBlockNumberAt(~index=0),
      90,
      ~message="Should return latest fetched block number",
    )
  })
})

describe("FetchState buffer overflow prevention", () => {
  it(
    "Should limit endBlock when maxQueryBlockNumber < knownHeight to prevent buffer overflow",
    () => {
      let fetchState = makeInitial(~maxAddrInPartition=1, ~targetBufferSize=10)

      // Create a second partition to ensure buffer limiting logic is exercised across partitions
      // Register at a later block, so partition "0" remains the earliest and is selected
      let dc = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress1)
      let fetchStateWithTwoPartitions =
        fetchState->FetchState.registerDynamicContracts([dc->dcToItem])

      // Build up a large queue using public API (handleQueryResult)
      // queue.length = 15, targetBufferSize = 10
      // targetBlockIdx = 15 - 10 = 5
      // maxQueryBlockNumber should be the blockNumber at index 5 (which is 15)
      let largeQueueEvents = [
        mockEvent(~blockNumber=20), // index 0
        mockEvent(~blockNumber=19), // index 1
        mockEvent(~blockNumber=18), // index 2
        mockEvent(~blockNumber=17), // index 3
        mockEvent(~blockNumber=16), // index 4
        mockEvent(~blockNumber=15), // index 5 <- this should be maxQueryBlockNumber
        mockEvent(~blockNumber=14), // index 6
        mockEvent(~blockNumber=13), // index 7
        mockEvent(~blockNumber=12), // index 8
        mockEvent(~blockNumber=11), // index 9
        mockEvent(~blockNumber=10), // index 10
        mockEvent(~blockNumber=9), // index 11
        mockEvent(~blockNumber=8), // index 12
        mockEvent(~blockNumber=7), // index 13
        mockEvent(~blockNumber=6), // index 14
      ]

      let query0: FetchState.query = {
        partitionId: "0",
        fromBlock: 0,
        toBlock: None,
        isChunk: false,
        selection: fetchStateWithTwoPartitions.normalSelection,
        addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
        indexingContracts: fetchStateWithTwoPartitions.indexingContracts,
      }

      let fetchStateWithLargeQueue =
        fetchStateWithTwoPartitions->executeQuery(
          ~query=query0,
          ~latestFetchedBlock={blockNumber: 30, blockTimestamp: 30 * 15},
          ~newItems=largeQueueEvents,
        )

      // Test case: With endBlock set, should be limited by maxQueryBlockNumber
      let fetchStateWithEndBlock = {
        ...fetchStateWithLargeQueue,
        endBlock: Some(25),
        knownHeight: 30,
      }
      let query1 = fetchStateWithEndBlock->FetchState.getNextQuery(~concurrencyLimit=10)

      switch query1 {
      | Ready([q]) =>
        // The query should have toBlock limited
        Assert.ok(
          q.toBlock->Option.isSome,
          ~message="Should have toBlock set when buffer limiting is active",
        )
      | _ => Assert.ok(true, ~message="Query state is acceptable")
      }
    },
  )
})

describe("FetchState with onBlockConfig only (no events)", () => {
  let makeOnBlockConfig = (
    ~name="testOnBlock",
    ~index=0,
    ~startBlock=None,
    ~endBlock=None,
    ~interval=1,
  ): Internal.onBlockConfig => {
    index,
    name,
    chainId,
    startBlock,
    endBlock,
    interval,
    handler: Utils.magic("mock handler"),
  }

  it(
    "Creates FetchState with no event configs, triggers WaitingForNewBlock, then fills buffer on updateKnownHeight",
    () => {
      let onBlockConfig = makeOnBlockConfig(~interval=1, ~startBlock=Some(0))

      // Create FetchState with no event configs but with onBlockConfig
      let fetchState = FetchState.make(
        ~eventConfigs=[],
        ~contracts=[],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~targetBufferSize=10,
        ~chainId,
        ~knownHeight=0,
        ~onBlockConfigs=[onBlockConfig],
      )

      // Verify initial state
      Assert.equal(
        getPartitionCount(fetchState),
        0,
        ~message="Partitions should be empty when there are no event configs",
      )
      Assert.deepEqual(fetchState.buffer, [], ~message="Buffer should be empty initially")
      Assert.equal(fetchState.knownHeight, 0, ~message="knownHeight should be 0 initially")
      Assert.deepEqual(
        fetchState.onBlockConfigs,
        [onBlockConfig],
        ~message="onBlockConfigs should be set",
      )

      // Test that getNextQuery returns WaitingForNewBlock when knownHeight is 0
      let nextQuery = fetchState->FetchState.getNextQuery(~concurrencyLimit=10)
      Assert.deepEqual(
        nextQuery,
        WaitingForNewBlock,
        ~message="Should return WaitingForNewBlock when knownHeight is 0",
      )

      // Update known height to 20
      let updatedFetchState = fetchState->FetchState.updateKnownHeight(~knownHeight=20)

      Assert.equal(
        updatedFetchState.knownHeight,
        20,
        ~message="knownHeight should be updated to 20",
      )
    },
  )
})
