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

let baseEventConfig = (Mock.evmEventConfig(
  ~id="0",
  ~contractName="Gravatar",
) :> Internal.eventConfig)

let baseEventConfig2 = (Mock.evmEventConfig(
  ~id="0",
  ~contractName="NftFactory",
) :> Internal.eventConfig)

let makeInitial = (
  ~knownHeight=knownHeight,
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

// Helper to build indexingContracts dict for test expectations
// Note: dynamic contract info is now only tracked by the register field (DC variant)
let makeIndexingContractsWithDynamics = (
  dcs: array<Internal.indexingContract>,
  ~static=[],
  ~contractName="Gravatar",
) => {
  let dict = Js.Dict.empty()
  dcs->Array.forEach(dc => {
    dict->Js.Dict.set(dc.address->Address.toString, dc)
  })
  static->Array.forEach(address => {
    dict->Js.Dict.set(
      address->Address.toString,
      {
        address,
        contractName,
        startBlock: 0,
        registrationBlock: None,
      },
    )
  })
  dict
}

// A workaround for ReScript v11 issue, where it makes the field optional
// instead of setting a value to undefined. It's fixed in v12.
let undefined = (%raw(`undefined`): option<'a>)

describe("FetchState.make", () => {
  it("Creates FetchState with a single static address", () => {
    let fetchState = makeInitial()

    Assert.deepEqual(
      fetchState,
      {
        optimizedPartitions: FetchState.OptimizedPartitions.make(
          ~partitions=[
            {
              id: "0",
              latestFetchedBlock: {
                blockNumber: -1,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
              mergeBlock: None,
              dynamicContract: None,
              mutPendingQueries: [],
              prevQueryRange: 0,
              prevPrevQueryRange: 0,
              latestBlockRangeUpdateBlock: 0,
            },
          ],
          ~nextPartitionIndex=1,
          ~maxAddrInPartition=3,
          ~dynamicContracts=Utils.Set.make(),
        ),
        startBlock: 0,
        endBlock: undefined,
        latestOnBlockBlockNumber: -1,
        targetBufferSize: 5000,
        buffer: [],
        normalSelection: fetchState.normalSelection,
        chainId: 0,
        indexingContracts: fetchState.indexingContracts,
        contractConfigs: fetchState.contractConfigs,
        blockLag: 0,
        onBlockConfigs: [],
        knownHeight,
      },
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

      Assert.deepEqual(
        fetchState,
        {
          optimizedPartitions: FetchState.OptimizedPartitions.make(
            ~partitions=[
              {
                id: "0",
                latestFetchedBlock: {
                  blockNumber: -1,
                  blockTimestamp: 0,
                },
                selection: fetchState.normalSelection,
                addressesByContractName: Js.Dict.fromArray([
                  ("Gravatar", [mockAddress1, mockAddress2]),
                ]),
                mergeBlock: None,
                dynamicContract: Some("Gravatar"),
                mutPendingQueries: [],
                prevQueryRange: 0,
                prevPrevQueryRange: 0,
                latestBlockRangeUpdateBlock: 0,
              },
            ],
            ~nextPartitionIndex=1,
            ~maxAddrInPartition=2,
            ~dynamicContracts=Utils.Set.fromArray(["Gravatar"]),
          ),
          targetBufferSize,
          latestOnBlockBlockNumber: -1,
          buffer: [],
          startBlock: 0,
          endBlock: undefined,
          normalSelection: fetchState.normalSelection,
          chainId,
          indexingContracts: fetchState.indexingContracts,
          contractConfigs: fetchState.contractConfigs,
          blockLag: 0,
          onBlockConfigs: [],
          knownHeight,
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
        ~contracts=[makeConfigContract("ContractA", mockAddress1), dc],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=1,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      Assert.deepEqual(
        fetchState,
        {
          optimizedPartitions: FetchState.OptimizedPartitions.make(
            ~partitions=[
              {
                id: "0",
                latestFetchedBlock: {
                  blockNumber: -1,
                  blockTimestamp: 0,
                },
                selection: fetchState.normalSelection,
                addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress1])]),
                mergeBlock: None,
                dynamicContract: None,
                mutPendingQueries: [],
                prevQueryRange: 0,
                prevPrevQueryRange: 0,
                latestBlockRangeUpdateBlock: 0,
              },
              {
                id: "1",
                latestFetchedBlock: {
                  blockNumber: -1,
                  blockTimestamp: 0,
                },
                selection: fetchState.normalSelection,
                addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress2])]),
                mergeBlock: None,
                dynamicContract: Some("Gravatar"),
                mutPendingQueries: [],
                prevQueryRange: 0,
                prevPrevQueryRange: 0,
                latestBlockRangeUpdateBlock: 0,
              },
            ],
            ~nextPartitionIndex=2,
            ~maxAddrInPartition=1,
            ~dynamicContracts=Utils.Set.fromArray(["Gravatar"]),
          ),
          targetBufferSize,
          latestOnBlockBlockNumber: -1,
          buffer: [],
          startBlock: 0,
          endBlock: undefined,
          normalSelection: fetchState.normalSelection,
          chainId,
          indexingContracts: fetchState.indexingContracts,
          contractConfigs: fetchState.contractConfigs,
          blockLag: 0,
          onBlockConfigs: [],
          knownHeight,
        },
      )

      Assert.equal(
        (fetchState.optimizedPartitions.entities->Js.Dict.unsafeGet("0")).selection,
        (fetchState.optimizedPartitions.entities->Js.Dict.unsafeGet("1")).selection,
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

      Assert.deepEqual(
        fetchState,
        {
          optimizedPartitions: FetchState.OptimizedPartitions.make(
            ~partitions=[
              {
                id: "0",
                latestFetchedBlock: {
                  blockNumber: -1,
                  blockTimestamp: 0,
                },
                selection: fetchState.normalSelection,
                addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress1])]),
                mergeBlock: None,
                dynamicContract: None,
                mutPendingQueries: [],
                prevQueryRange: 0,
                prevPrevQueryRange: 0,
                latestBlockRangeUpdateBlock: 0,
              },
              {
                id: "1",
                latestFetchedBlock: {
                  blockNumber: -1,
                  blockTimestamp: 0,
                },
                selection: fetchState.normalSelection,
                addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress2])]),
                mergeBlock: None,
                dynamicContract: None,
                mutPendingQueries: [],
                prevQueryRange: 0,
                prevPrevQueryRange: 0,
                latestBlockRangeUpdateBlock: 0,
              },
              {
                id: "2",
                latestFetchedBlock: {
                  blockNumber: -1,
                  blockTimestamp: 0,
                },
                selection: fetchState.normalSelection,
                addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
                mergeBlock: None,
                dynamicContract: Some("Gravatar"),
                mutPendingQueries: [],
                prevQueryRange: 0,
                prevPrevQueryRange: 0,
                latestBlockRangeUpdateBlock: 0,
              },
              {
                id: "3",
                latestFetchedBlock: {
                  blockNumber: -1,
                  blockTimestamp: 0,
                },
                selection: fetchState.normalSelection,
                addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress4])]),
                mergeBlock: None,
                dynamicContract: Some("Gravatar"),
                mutPendingQueries: [],
                prevQueryRange: 0,
                prevPrevQueryRange: 0,
                latestBlockRangeUpdateBlock: 0,
              },
            ],
            ~nextPartitionIndex=4,
            ~maxAddrInPartition=1,
            ~dynamicContracts=Utils.Set.fromArray(["Gravatar"]),
          ),
          targetBufferSize,
          latestOnBlockBlockNumber: -1,
          buffer: [],
          startBlock: 0,
          endBlock: undefined,
          normalSelection: fetchState.normalSelection,
          chainId,
          indexingContracts: fetchState.indexingContracts,
          contractConfigs: fetchState.contractConfigs,
          blockLag: 0,
          onBlockConfigs: [],
          knownHeight,
        },
      )
    },
  )

  it("Two static contracts with different names merge based on block distance", () => {
    let contractAEventConfig = (Mock.evmEventConfig(
      ~id="0",
      ~contractName="ContractA",
    ) :> Internal.eventConfig)
    let contractBEventConfig = (Mock.evmEventConfig(
      ~id="0",
      ~contractName="ContractB",
    ) :> Internal.eventConfig)

    // --- Close startBlocks: direct push into current partition ---
    let closeFetchState = FetchState.make(
      ~eventConfigs=[contractAEventConfig, contractBEventConfig],
      ~contracts=[
        {
          address: mockAddress0,
          contractName: "ContractA",
          startBlock: 0,
          registrationBlock: None,
        },
        {
          address: mockAddress1,
          contractName: "ContractB",
          startBlock: 19_999,
          registrationBlock: None,
        },
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~targetBufferSize,
      ~chainId,
      ~knownHeight,
    )

    // Phase 1: ContractA partition (block -1), ContractB partition (block 19_998)
    // Phase 2: not too far, not filterByAddresses -> push ContractB addresses into ContractA partition
    let closePartitions = closeFetchState.optimizedPartitions
    Assert.deepEqual(
      closePartitions.idsInAscOrder,
      ["0"],
      ~message="Close startBlocks: should merge into a single partition (direct push)",
    )
    Assert.deepEqual(
      (closePartitions.entities->Js.Dict.unsafeGet("0")).addressesByContractName,
      Js.Dict.fromArray([("ContractA", [mockAddress0]), ("ContractB", [mockAddress1])]),
      ~message="Close startBlocks: single partition has both contracts' addresses",
    )
    Assert.deepEqual(
      (closePartitions.entities->Js.Dict.unsafeGet("0")).mergeBlock,
      None,
      ~message="Close startBlocks: no mergeBlock needed",
    )

    // --- Far startBlocks: mergeBlock on current, merge addresses into next ---
    let farFetchState = FetchState.make(
      ~eventConfigs=[contractAEventConfig, contractBEventConfig],
      ~contracts=[
        {
          address: mockAddress0,
          contractName: "ContractA",
          startBlock: 0,
          registrationBlock: None,
        },
        {
          address: mockAddress1,
          contractName: "ContractB",
          startBlock: 20_002,
          registrationBlock: None,
        },
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~targetBufferSize,
      ~chainId,
      ~knownHeight,
    )

    // Phase 1: ContractA partition (block -1), ContractB partition (block 20_001)
    // Phase 2: too far -> mergeBlock on earlier, merge addresses into later
    let farPartitions = farFetchState.optimizedPartitions
    Assert.deepEqual(
      farPartitions.idsInAscOrder,
      ["0", "1"],
      ~message="Far startBlocks: should have 2 partitions with mergeBlock on earlier",
    )
    Assert.deepEqual(
      (farPartitions.entities->Js.Dict.unsafeGet("0")).mergeBlock,
      Some(20_001),
      ~message="Far startBlocks: earlier partition has mergeBlock",
    )
    Assert.deepEqual(
      (farPartitions.entities->Js.Dict.unsafeGet("1")).addressesByContractName,
      Js.Dict.fromArray([("ContractB", [mockAddress1]), ("ContractA", [mockAddress0])]),
      ~message="Far startBlocks: later partition has merged addresses from both contracts",
    )
  })

  it(
    "Single contract with close startBlocks creates one partition, far startBlocks creates two with mergeBlock",
    () => {
      let gravatarEventConfig = (Mock.evmEventConfig(
        ~id="0",
        ~contractName="Gravatar",
      ) :> Internal.eventConfig)

      // --- Close startBlocks: Phase 1 merges into a single partition ---
      let closeFetchState = FetchState.make(
        ~eventConfigs=[gravatarEventConfig],
        ~contracts=[
          {
            address: mockAddress0,
            contractName: "Gravatar",
            startBlock: 0,
            registrationBlock: None,
          },
          {
            address: mockAddress1,
            contractName: "Gravatar",
            startBlock: 19_999,
            registrationBlock: None,
          },
        ],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      let closePartitions = closeFetchState.optimizedPartitions
      Assert.deepEqual(
        closePartitions.idsInAscOrder,
        ["0"],
        ~message="Close startBlocks: Phase 1 groups into a single partition",
      )
      Assert.deepEqual(
        (closePartitions.entities->Js.Dict.unsafeGet("0")).addressesByContractName,
        Js.Dict.fromArray([("Gravatar", [mockAddress0, mockAddress1])]),
        ~message="Close startBlocks: single partition has both addresses",
      )
      Assert.deepEqual(
        (closePartitions.entities->Js.Dict.unsafeGet("0")).mergeBlock,
        None,
        ~message="Close startBlocks: no mergeBlock needed for single partition",
      )

      // --- Far startBlocks: Phase 1 splits, Phase 2 merges with mergeBlock ---
      let farFetchState = FetchState.make(
        ~eventConfigs=[gravatarEventConfig],
        ~contracts=[
          {
            address: mockAddress0,
            contractName: "Gravatar",
            startBlock: 0,
            registrationBlock: None,
          },
          {
            address: mockAddress1,
            contractName: "Gravatar",
            startBlock: 20_002,
            registrationBlock: None,
          },
        ],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      // Phase 1: 2 partitions (same contract, far startBlocks)
      // Phase 2: merges them with mergeBlock
      let farPartitions = farFetchState.optimizedPartitions
      Assert.deepEqual(
        farPartitions.idsInAscOrder,
        ["0", "1"],
        ~message="Far startBlocks: Phase 1 splits into 2, Phase 2 merges with mergeBlock",
      )
      Assert.deepEqual(
        (farPartitions.entities->Js.Dict.unsafeGet("0")).latestFetchedBlock.blockNumber,
        -1,
        ~message="Far startBlocks: earlier partition starts at block -1",
      )
      Assert.deepEqual(
        (farPartitions.entities->Js.Dict.unsafeGet("0")).mergeBlock,
        Some(20_001),
        ~message="Far startBlocks: earlier partition has mergeBlock matching later partition's block",
      )
      Assert.deepEqual(
        (farPartitions.entities->Js.Dict.unsafeGet("1")).addressesByContractName,
        Js.Dict.fromArray([("Gravatar", [mockAddress1, mockAddress0])]),
        ~message="Far startBlocks: later partition has merged addresses",
      )
      Assert.deepEqual(
        (farPartitions.entities->Js.Dict.unsafeGet("1")).mergeBlock,
        None,
        ~message="Far startBlocks: later partition has no mergeBlock",
      )
    },
  )

  it("Single contract with filterByAddresses keeps separate partitions per startBlock", () => {
    let gravatarEventConfig = (Mock.evmEventConfig(
      ~id="0",
      ~contractName="Gravatar",
      ~filterByAddresses=true,
    ) :> Internal.eventConfig)

    let fetchState = FetchState.make(
      ~eventConfigs=[gravatarEventConfig],
      ~contracts=[
        {
          address: mockAddress0,
          contractName: "Gravatar",
          startBlock: 0,
          registrationBlock: None,
        },
        {
          address: mockAddress1,
          contractName: "Gravatar",
          startBlock: 100,
          registrationBlock: None,
        },
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~targetBufferSize,
      ~chainId,
      ~knownHeight,
    )

    // Phase 1: filterByAddresses=true -> separate partitions per startBlock
    // Phase 2: hasFilterByAddresses -> mergeBlock on earlier, merge addresses into later
    let partitions = fetchState.optimizedPartitions
    Assert.deepEqual(
      partitions.idsInAscOrder,
      ["0", "1"],
      ~message="filterByAddresses: should create separate partitions per startBlock",
    )
    Assert.deepEqual(
      (partitions.entities->Js.Dict.unsafeGet("0")).addressesByContractName,
      Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
      ~message="filterByAddresses: first partition has only first address",
    )
    Assert.deepEqual(
      (partitions.entities->Js.Dict.unsafeGet("0")).latestFetchedBlock.blockNumber,
      -1,
      ~message="filterByAddresses: first partition starts at block -1",
    )
    Assert.deepEqual(
      (partitions.entities->Js.Dict.unsafeGet("0")).mergeBlock,
      Some(99),
      ~message="filterByAddresses: first partition has mergeBlock matching second partition's block",
    )
    Assert.deepEqual(
      (partitions.entities->Js.Dict.unsafeGet("1")).addressesByContractName,
      Js.Dict.fromArray([("Gravatar", [mockAddress1, mockAddress0])]),
      ~message="filterByAddresses: second partition has merged addresses from both",
    )
    Assert.deepEqual(
      (partitions.entities->Js.Dict.unsafeGet("1")).latestFetchedBlock.blockNumber,
      99,
      ~message="filterByAddresses: second partition starts at block 99",
    )
  })

  it(
    "Different contracts with filterByAddresses use mergeBlock strategy and merge addresses into later partition",
    () => {
      let contractAEventConfig = (Mock.evmEventConfig(
        ~id="0",
        ~contractName="ContractA",
        ~filterByAddresses=true,
      ) :> Internal.eventConfig)
      let contractBEventConfig = (Mock.evmEventConfig(
        ~id="0",
        ~contractName="ContractB",
        ~filterByAddresses=true,
      ) :> Internal.eventConfig)

      let fetchState = FetchState.make(
        ~eventConfigs=[contractAEventConfig, contractBEventConfig],
        ~contracts=[
          {
            address: mockAddress0,
            contractName: "ContractA",
            startBlock: 0,
            registrationBlock: None,
          },
          {
            address: mockAddress1,
            contractName: "ContractB",
            startBlock: 100,
            registrationBlock: None,
          },
        ],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      // Phase 1: ContractA partition (block -1), ContractB partition (block 99)
      // Phase 2: hasFilterByAddresses -> mergeBlock on earlier, merge addresses into later
      let partitions = fetchState.optimizedPartitions
      Assert.deepEqual(
        partitions.idsInAscOrder,
        ["0", "1"],
        ~message="filterByAddresses cross-contract: should have 2 partitions",
      )
      Assert.deepEqual(
        (partitions.entities->Js.Dict.unsafeGet("0")).addressesByContractName,
        Js.Dict.fromArray([("ContractA", [mockAddress0])]),
        ~message="filterByAddresses cross-contract: first partition has only ContractA address",
      )
      Assert.deepEqual(
        (partitions.entities->Js.Dict.unsafeGet("0")).mergeBlock,
        Some(99),
        ~message="filterByAddresses cross-contract: first partition has mergeBlock",
      )
      Assert.deepEqual(
        (partitions.entities->Js.Dict.unsafeGet("1")).addressesByContractName,
        Js.Dict.fromArray([("ContractB", [mockAddress1]), ("ContractA", [mockAddress0])]),
        ~message="filterByAddresses cross-contract: second partition has merged addresses from both contracts",
      )
      Assert.deepEqual(
        (partitions.entities->Js.Dict.unsafeGet("1")).latestFetchedBlock.blockNumber,
        99,
        ~message="filterByAddresses cross-contract: second partition starts at block 99",
      )
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
        (
          fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count,
          fetchStateWithDc1.optimizedPartitions->FetchState.OptimizedPartitions.count,
        ),
        (1, 2),
        ~message="Should have created a new partition for the dc",
      )

      Assert.equal(
        fetchStateWithDc1->FetchState.registerDynamicContracts([dc1->dcToItem]),
        fetchStateWithDc1,
        ~message="Calling it with the same dc for the second time shouldn't change anything",
      )

      Assert.equal(
        fetchStateWithDc1->FetchState.registerDynamicContracts([
          makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress1)->dcToItem,
        ]),
        fetchStateWithDc1,
        ~message=`BROKEN: Calling it with the same dc
          but earlier block number should create a new short lived partition
          for the specific contract from block 0 to 1. And update the dc in db`,
        // This is an edge case we currently don't cover
        // But show a warning in the logs
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

    Assert.deepEqual(
      updatedFetchState.optimizedPartitions.entities->Js.Dict.values,
      [
        {
          ...fetchState.optimizedPartitions.entities->Js.Dict.unsafeGet("0"),
          mergeBlock: Some(1),
          dynamicContract: Some("Gravatar"),
        },
        {
          id: "1",
          latestFetchedBlock: {
            blockNumber: 1,
            blockTimestamp: 0,
          },
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([
            ("Gravatar", [mockAddress1, mockAddress2, mockAddress3]),
          ]),
          mergeBlock: None,
          dynamicContract: Some("Gravatar"),
          mutPendingQueries: [],
          prevQueryRange: 0,
          prevPrevQueryRange: 0,
          latestBlockRangeUpdateBlock: 0,
        },
        {
          id: "2",
          latestFetchedBlock: {
            blockNumber: 1,
            blockTimestamp: 0,
          },
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress4, mockAddress0])]),
          mergeBlock: None,
          dynamicContract: Some("Gravatar"),
          mutPendingQueries: [],
          prevQueryRange: 0,
          prevPrevQueryRange: 0,
          latestBlockRangeUpdateBlock: 0,
        },
      ],
      ~message=`Should add 2 new partitions + optimize the original partition to merge without blocking`,
    )

    let dc1FromAnotherContract = makeDynContractRegistration(
      ~blockNumber=2,
      ~contractAddress=mockAddress1,
      ~contractName="NftFactory",
    )
    let dc4FromAnotherContract = makeDynContractRegistration(
      ~blockNumber=2,
      ~contractAddress=mockAddress4,
      ~contractName="NftFactory",
    )
    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts([
        dc1FromAnotherContract->dcToItem,
        dc2->dcToItem,
        dc3->dcToItem,
        dc4FromAnotherContract->dcToItem,
      ])

    Assert.deepEqual(
      updatedFetchState.optimizedPartitions.entities->Js.Dict.values,
      [
        {
          ...fetchState.optimizedPartitions.entities->Js.Dict.unsafeGet("0"),
          mergeBlock: Some(1),
          dynamicContract: Some("Gravatar"),
        },
        {
          id: "1",
          latestFetchedBlock: {
            blockNumber: 1,
            blockTimestamp: 0,
          },
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([
            ("NftFactory", [mockAddress1, mockAddress4]),
          ]),
          mergeBlock: None,
          dynamicContract: Some("NftFactory"),
          mutPendingQueries: [],
          prevQueryRange: 0,
          prevPrevQueryRange: 0,
          latestBlockRangeUpdateBlock: 0,
        },
        {
          id: "2",
          latestFetchedBlock: {
            blockNumber: 1,
            blockTimestamp: 0,
          },
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([
            ("Gravatar", [mockAddress2, mockAddress3, mockAddress0]),
          ]),
          mergeBlock: None,
          dynamicContract: Some("Gravatar"),
          mutPendingQueries: [],
          prevQueryRange: 0,
          prevPrevQueryRange: 0,
          latestBlockRangeUpdateBlock: 0,
        },
      ],
      ~message=`Should add 2 new partitions
+ optimize the original partition to merge without blocking
+ dynamic contracts don't share partitions`,
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

      Assert.deepEqual(
        updatedFetchState.optimizedPartitions.entities->Js.Dict.values,
        [
          {
            ...fetchState.optimizedPartitions.entities->Js.Dict.unsafeGet("0"),
            // Immediately merge to the original partition
            addressesByContractName: Js.Dict.fromArray([
              ("Gravatar", [mockAddress0, mockAddress1]),
            ]),
            dynamicContract: Some("Gravatar"),
          },
          // Partition to catch up with partition 0
          {
            id: "1",
            latestFetchedBlock: {
              blockNumber: 2,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress1])]),
            mergeBlock: Some(9),
            dynamicContract: Some("Gravatar"),
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
          },
          {
            id: "2",
            latestFetchedBlock: {
              blockNumber: 2,
              blockTimestamp: 0,
            },
            mergeBlock: Some(4),
            selection: fetchState.normalSelection,
            addressesByContractName: Js.Dict.fromArray([
              ("SimpleNft", [mockAddress2, mockAddress3]),
            ]),
            dynamicContract: Some("SimpleNft"),
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
          },
          {
            id: "3",
            latestFetchedBlock: {
              blockNumber: 4,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            addressesByContractName: Js.Dict.fromArray([
              ("SimpleNft", [mockAddress4, mockAddress2, mockAddress3]),
            ]),
            mergeBlock: None,
            dynamicContract: Some("SimpleNft"),
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
          },
          {
            id: "4",
            latestFetchedBlock: {
              blockNumber: 5,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            addressesByContractName: Js.Dict.fromArray([("NftFactory", [mockAddress5])]),
            mergeBlock: None,
            dynamicContract: Some("NftFactory"),
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
          },
        ],
        ~message=`All dcs without filterByAddresses should use the original logic and be grouped into a single partition,
          while dcs with filterByAddress should be split into partition per every registration block`,
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
  And remove the dc from the later one, so they are not duplicated in the db`,
    )
    Assert.deepEqual(
      updatedFetchState.indexingContracts,
      makeIndexingContractsWithDynamics([dc2], ~static=[mockAddress0]),
      ~message="Should choose the earliest dc from the batch",
    )
    Assert.deepEqual(
      updatedFetchState.optimizedPartitions.entities->Js.Dict.values,
      [
        {
          ...fetchState.optimizedPartitions.entities->Js.Dict.unsafeGet("0"),
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
          dynamicContract: Some("Gravatar"),
          mergeBlock: Some(9),
        },
        {
          id: "1",
          latestFetchedBlock: {
            blockNumber: 9,
            blockTimestamp: 0,
          },
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress1, mockAddress0])]),
          mergeBlock: None,
          dynamicContract: Some("Gravatar"),
          mutPendingQueries: [],
          prevQueryRange: 0,
          prevPrevQueryRange: 0,
          latestBlockRangeUpdateBlock: 0,
        },
      ],
      ~message="Adds dc and optimizes partitions",
    )
  })

  it("All dcs are grouped in a single partition, but don't merged with an existing one", () => {
    let fetchState = makeInitial()

    let dc1 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress1)
    // Even if there's too big of a block difference,
    // we don't care because:
    // RPC - The registrations come from requested batch,
    //       which is not very big by itself.
    // HyperSync - Even though the block range of the batch with registrations
    //             might be big, HyperSync will efficiently handle addresses registered
    //             later on chain.
    // If there are events before the contract registratins,
    // they will be filtered client-side by the the router.
    let dc2 = makeDynContractRegistration(~blockNumber=10_000, ~contractAddress=mockAddress2)
    // But for too big block difference, we create different partitions just in case
    let dc3 = makeDynContractRegistration(~blockNumber=300_000, ~contractAddress=mockAddress3)

    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts(// Order of dcs doesn't matter
      // but they are not sorted in fetch state
      [dc1->dcToItem, dc3->dcToItem, dc2->dcToItem])
    Assert.equal(updatedFetchState.indexingContracts->Utils.Dict.size, 4)
    Assert.deepEqual(
      updatedFetchState.optimizedPartitions.entities->Js.Dict.values,
      [
        {
          ...fetchState.optimizedPartitions.entities->Js.Dict.unsafeGet("0"),
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
          dynamicContract: Some("Gravatar"),
          mergeBlock: Some(1),
        },
        {
          id: "1",
          latestFetchedBlock: {
            blockNumber: 1,
            blockTimestamp: 0,
          },
          mergeBlock: None,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([
            ("Gravatar", [mockAddress1, mockAddress2, mockAddress0]),
          ]),
          dynamicContract: Some("Gravatar"),
          mutPendingQueries: [],
          prevQueryRange: 0,
          prevPrevQueryRange: 0,
          latestBlockRangeUpdateBlock: 0,
        },
        {
          id: "2",
          latestFetchedBlock: {
            blockNumber: 299_999,
            blockTimestamp: 0,
          },
          mergeBlock: None,
          selection: fetchState.normalSelection,
          // The partition is too far, so we don't merge addresses from the prev partition too early
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
          dynamicContract: Some("Gravatar"),
          mutPendingQueries: [],
          prevQueryRange: 0,
          prevPrevQueryRange: 0,
          latestBlockRangeUpdateBlock: 0,
        },
      ],
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

      Assert.deepEqual(
        fetchState,
        {
          optimizedPartitions: FetchState.OptimizedPartitions.make(
            ~partitions=[
              {
                id: "0",
                latestFetchedBlock: {
                  blockNumber: -1,
                  blockTimestamp: 0,
                },
                selection: {
                  dependsOnAddresses: false,
                  // Even though normal2 is also a wildcard event
                  // it should be a part of the normal selection
                  eventConfigs: [wildcard1, wildcard2],
                },
                addressesByContractName: Js.Dict.empty(),
                mergeBlock: None,
                dynamicContract: None,
                mutPendingQueries: [],
                prevQueryRange: 0,
                prevPrevQueryRange: 0,
                latestBlockRangeUpdateBlock: 0,
              },
              {
                id: "1",
                latestFetchedBlock: {
                  blockNumber: -1,
                  blockTimestamp: 0,
                },
                selection: {
                  dependsOnAddresses: true,
                  eventConfigs: [normal1, normal2],
                },
                addressesByContractName: Js.Dict.fromArray([
                  ("NftFactory", [mockAddress0, mockAddress1, mockAddress5]),
                ]),
                mergeBlock: None,
                dynamicContract: Some("NftFactory"),
                mutPendingQueries: [],
                prevQueryRange: 0,
                prevPrevQueryRange: 0,
                latestBlockRangeUpdateBlock: 0,
              },
            ],
            ~nextPartitionIndex=2,
            ~maxAddrInPartition=1000,
            ~dynamicContracts=Utils.Set.fromArray(["NftFactory"]),
          ),
          startBlock: 0,
          endBlock: undefined,
          latestOnBlockBlockNumber: -1,
          targetBufferSize,
          buffer: [],
          normalSelection: fetchState.normalSelection,
          chainId,
          indexingContracts: fetchState.indexingContracts,
          contractConfigs: fetchState.contractConfigs,
          blockLag: 0,
          onBlockConfigs: [],
          knownHeight,
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
    let normalSelection = makeInitial().normalSelection
    {
      optimizedPartitions: FetchState.OptimizedPartitions.make(
        ~partitions=[
          {
            id: "0",
            latestFetchedBlock: {
              blockNumber: 10,
              blockTimestamp: 10,
            },
            dynamicContract: None,
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
            selection: normalSelection,
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=1,
        ~maxAddrInPartition=3,
        ~dynamicContracts=Utils.Set.make(),
      ),
      latestOnBlockBlockNumber: knownHeight,
      targetBufferSize,
      buffer: [mockEvent(~blockNumber=1), mockEvent(~blockNumber=2)],
      startBlock: 0,
      endBlock: None,
      blockLag: 0,
      normalSelection,
      chainId,
      indexingContracts: Js.Dict.fromArray([
        (
          mockAddress0->Address.toString,
          {
            Internal.contractName: "Gravatar",
            startBlock: 0,
            address: mockAddress0,
            registrationBlock: None,
          },
        ),
      ]),
      contractConfigs: makeInitial().contractConfigs,
      onBlockConfigs: [],
      knownHeight,
    }
  }

  let makeIntermidiateDcMerge = (~maxAddrInPartition=3, ~knownHeight=knownHeight): FetchState.t => {
    let normalSelection = makeInitial().normalSelection
    {
      optimizedPartitions: FetchState.OptimizedPartitions.make(
        ~partitions=[
          {
            id: "0",
            latestFetchedBlock: {
              blockNumber: 10,
              blockTimestamp: 10,
            },
            dynamicContract: Some("Gravatar"),
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
            selection: normalSelection,
            addressesByContractName: Js.Dict.fromArray([
              ("Gravatar", [mockAddress0, mockAddress1, mockAddress2]),
            ]),
            mergeBlock: None,
          },
          {
            id: "2",
            latestFetchedBlock: {
              blockNumber: 2,
              blockTimestamp: 0,
            },
            dynamicContract: Some("Gravatar"),
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
            selection: normalSelection,
            addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=3,
        ~maxAddrInPartition,
        ~dynamicContracts=Utils.Set.fromArray(["Gravatar"]),
      ),
      latestOnBlockBlockNumber: knownHeight,
      targetBufferSize,
      buffer: [mockEvent(~blockNumber=1), mockEvent(~blockNumber=2)],
      startBlock: 0,
      endBlock: undefined,
      normalSelection,
      chainId,
      indexingContracts: makeIndexingContractsWithDynamics([dc3, dc2, dc1], ~static=[mockAddress0]),
      contractConfigs: makeInitial().contractConfigs,
      blockLag: 0,
      onBlockConfigs: [],
      knownHeight,
    }
  }

  // The default configuration with ability to overwrite some values
  let getNextQuery = (
    fs,
    ~endBlock=None,
    ~knownHeight=10,
    ~targetBufferSize=10,
    ~concurrencyLimit=10,
  ) =>
    switch endBlock {
    | Some(_) => {...fs, targetBufferSize, endBlock}
    | None => {...fs, targetBufferSize}
    }
    ->FetchState.updateKnownHeight(~knownHeight)
    ->FetchState.getNextQuery(~concurrencyLimit)

  it("Emulate first indexer queries with a static event", () => {
    let fetchState = makeInitial()

    Assert.deepEqual(fetchState->getNextQuery(~knownHeight=0), WaitingForNewBlock)

    let nextQuery = fetchState->getNextQuery

    Assert.deepEqual(
      nextQuery,
      Ready([
        {
          partitionId: "0",
          fromBlock: 0,
          toBlock: None,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
          indexingContracts: fetchState.indexingContracts,
          isChunk: false,
        },
      ]),
    )

    let query = switch nextQuery {
    | Ready([q]) => q
    | _ => Assert.fail("Failed to extract query")
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])

    Assert.deepEqual(
      (fetchState.optimizedPartitions.entities->Js.Dict.unsafeGet("0")).mutPendingQueries,
      [
        {
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          fetchedBlock: None,
        },
      ],
      ~message="The startFetchingQueries should mutate mutPendingQueries",
    )

    let repeatedNextQuery = fetchState->getNextQuery

    Assert.deepEqual(
      repeatedNextQuery,
      NothingToQuery,
      ~message="Shouldn't double fetch the same partition",
    )

    let updatedFetchState = fetchState->FetchState.handleQueryResult(
      ~query,
      ~latestFetchedBlock={
        blockNumber: 10,
        blockTimestamp: 10,
      },
      ~newItems=[mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
    )

    Assert.deepEqual(
      updatedFetchState,
      makeAfterFirstStaticAddressesQuery(),
      ~message="Should be equal to the initial state",
    )

    Assert.deepEqual(
      updatedFetchState->getNextQuery,
      WaitingForNewBlock,
      ~message="Should wait for new block",
    )
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
      updatedFetchState->getNextQuery(~targetBufferSize=2),
      WaitingForNewBlock,
      ~message=`Should wait for new block even if partitions have nothing to query`,
    )
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~targetBufferSize=2, ~knownHeight=11),
      NothingToQuery,
      ~message=`Should do nothing if the case above is not waiting for new block`,
    )

    updatedFetchState->FetchState.startFetchingQueries(~queries=[query])
    Assert.deepEqual(
      updatedFetchState->getNextQuery,
      NothingToQuery,
      ~message=`Test that even if all partitions reached the current block height,
      we won't wait for new block while even one partition is fetching.
      It might return an updated knownHeight in response and we won't need to poll for new block`,
    )
  })

  it("Emulate first indexer queries with block lag configured", () => {
    let fetchState = makeInitial(~blockLag=2)

    Assert.deepEqual(fetchState->getNextQuery(~knownHeight=0), WaitingForNewBlock)

    Assert.deepEqual(
      fetchState->getNextQuery(~knownHeight=1),
      WaitingForNewBlock,
      ~message="Should wait for new block when current block height - block lag is less than 0",
    )

    let nextQuery = fetchState->getNextQuery(~endBlock=Some(8), ~knownHeight=10)
    Assert.deepEqual(
      nextQuery,
      Ready([
        {
          partitionId: "0",
          toBlock: Some(8),
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
          isChunk: false,
        },
      ]),
      ~message="No block lag when we are close to the end block",
    )

    let nextQuery = fetchState->getNextQuery(~endBlock=Some(10), ~knownHeight=10)
    Assert.deepEqual(
      nextQuery,
      Ready([
        {
          partitionId: "0",
          toBlock: Some(8),
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
          isChunk: false,
        },
      ]),
      ~message="Should apply block lag even when there's an upcoming end block",
    )

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

    let updatedFetchState = fetchState->FetchState.handleQueryResult(
      ~query,
      ~latestFetchedBlock={
        blockNumber: 8,
        blockTimestamp: 8,
      },
      ~newItems=[mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
    )

    Assert.deepEqual(updatedFetchState->getNextQuery, WaitingForNewBlock)
  })

  it("Emulate dynamic contract registration", () => {
    // Continue with the state from previous test
    let fetchState = makeAfterFirstStaticAddressesQuery()

    let fetchStateWithDcs =
      fetchState
      ->FetchState.registerDynamicContracts([dc2->dcToItem, dc1->dcToItem])
      ->FetchState.registerDynamicContracts([dc3->dcToItem])

    Assert.deepEqual(
      fetchStateWithDcs.optimizedPartitions.entities->Js.Dict.values,
      [
        {
          ...fetchState.optimizedPartitions.entities->Js.Dict.unsafeGet("0"),
          dynamicContract: Some("Gravatar"),
          addressesByContractName: Js.Dict.fromArray([
            ("Gravatar", [mockAddress0, mockAddress1, mockAddress2]),
          ]),
        },
        {
          id: "1",
          latestFetchedBlock: {
            blockNumber: 0,
            blockTimestamp: 0,
          },
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress1, mockAddress2])]),
          mergeBlock: Some(10),
          dynamicContract: Some("Gravatar"),
          mutPendingQueries: [],
          prevQueryRange: 0,
          prevPrevQueryRange: 0,
          latestBlockRangeUpdateBlock: 0,
        },
        // Creates a new partition for this without merging, since 0 is full and 1 has mergeBlock
        {
          FetchState.id: "2",
          latestFetchedBlock: {
            blockNumber: 1,
            blockTimestamp: 0,
          },
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
          mergeBlock: None,
          dynamicContract: Some("Gravatar"),
          mutPendingQueries: [],
          prevQueryRange: 0,
          prevPrevQueryRange: 0,
          latestBlockRangeUpdateBlock: 0,
        },
      ],
      ~message="Assert internal representation of the fetch state",
    )

    Assert.deepEqual(
      fetchStateWithDcs->getNextQuery,
      Ready([
        {
          partitionId: "1",
          toBlock: Some(10),
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress1, mockAddress2])]),
          fromBlock: 1,
          indexingContracts: fetchStateWithDcs.indexingContracts,
        },
        {
          partitionId: "2",
          fromBlock: 2,
          toBlock: None,
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
          indexingContracts: fetchStateWithDcs.indexingContracts,
        },
        // Partition 0 is not included since it's below knownHeight
      ]),
      ~message="Merge DC partition into the later one + query other partitions in parallel",
    )

    let queries = switch fetchStateWithDcs->getNextQuery {
    | Ready(queries) => queries
    | _ => Assert.fail("Failed to extract query. The getNextQuery should be idempotent")
    }

    fetchStateWithDcs->FetchState.startFetchingQueries(~queries)
    Assert.deepEqual(
      fetchStateWithDcs->getNextQuery,
      NothingToQuery,
      ~message="All partitions below known height are already quering and can't be chunked",
    )

    let updatedFetchState =
      fetchStateWithDcs
      ->FetchState.handleQueryResult(
        ~query=queries->Array.getUnsafe(0),
        ~latestFetchedBlock={
          blockNumber: 10,
          blockTimestamp: 10,
        },
        ~newItems=[],
      )
      ->FetchState.handleQueryResult(
        ~query=queries->Array.getUnsafe(1),
        ~latestFetchedBlock={
          blockNumber: 2,
          blockTimestamp: 0,
        },
        ~newItems=[],
      )

    Assert.deepEqual(
      updatedFetchState,
      makeIntermidiateDcMerge(),
      ~message="Should be equal to intermidiate state",
    )

    let expectedPartition2Query: FetchState.query = {
      partitionId: "2",
      fromBlock: 3,
      toBlock: None,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
      indexingContracts: fetchStateWithDcs.indexingContracts,
      isChunk: false,
    }
    let expectedPartition0Query: FetchState.query = {
      partitionId: "0",
      toBlock: None,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.fromArray([
        ("Gravatar", [mockAddress0, mockAddress1, mockAddress2]),
      ]),
      fromBlock: 11,
      indexingContracts: fetchStateWithDcs.indexingContracts,
      isChunk: false,
    }

    Assert.deepEqual(
      updatedFetchState->getNextQuery(~knownHeight=11),
      Ready([expectedPartition2Query, expectedPartition0Query]),
      ~message=`Since the partition "0" reached the maxAddrNumber,
      there's no point to continue merging partitions,
      so we have two queries concurrently`,
    )
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~concurrencyLimit=1, ~knownHeight=11),
      Ready([expectedPartition2Query]),
      ~message=`Should be the query with smaller fromBlock`,
    )
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~knownHeight=10),
      Ready([expectedPartition2Query]),
      ~message=`Even if a single partition reached block height,
      we finish fetching other partitions until waiting for the new block first`,
    )

    updatedFetchState->FetchState.startFetchingQueries(~queries=[expectedPartition2Query])
    Assert.deepEqual(
      updatedFetchState->getNextQuery(~knownHeight=11),
      Ready([expectedPartition0Query]),
      ~message=`Should skip fetching queries`,
    )
  })

  it("Emulate partition merging cases", () => {
    let originalFetchState = makeIntermidiateDcMerge()
    let originalFetchState = {
      ...originalFetchState,
      optimizedPartitions: {
        ...originalFetchState.optimizedPartitions,
        maxAddrInPartition: 4,
      },
    }
    Assert.deepEqual(
      originalFetchState->getNextQuery(~knownHeight=11),
      Ready([
        {
          partitionId: "2",
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
          fromBlock: 3,
          indexingContracts: originalFetchState.indexingContracts,
          isChunk: false,
        },
        {
          FetchState.partitionId: "0",
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([
            ("Gravatar", [mockAddress0, mockAddress1, mockAddress2]),
          ]),
          fromBlock: 11,
          indexingContracts: originalFetchState.indexingContracts,
          isChunk: false,
        },
      ]),
      ~message="Until we optimize partitions - on handle query, we don't need to merge partitions",
    )

    // Continue with the state from previous test
    // But increase the maxAddrInPartition up to 4
    let fetchState = makeIntermidiateDcMerge(~maxAddrInPartition=4, ~knownHeight=11)
    Assert.deepEqual(
      fetchState->getNextQuery,
      Ready([
        {
          partitionId: "2",
          toBlock: Some(10),
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
          fromBlock: 3,
          indexingContracts: fetchState.indexingContracts,
          isChunk: false,
        },
        {
          FetchState.partitionId: "0",
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([
            ("Gravatar", [mockAddress0, mockAddress1, mockAddress2, mockAddress3]),
          ]),
          fromBlock: 11,
          indexingContracts: originalFetchState.indexingContracts,
          isChunk: false,
        },
      ]),
      ~message="Although, if we pass it through partition optimization, it should merge partitions now",
    )

    let queries = switch fetchState->getNextQuery {
    | Ready(queries) => queries
    | _ => Assert.fail("Failed to extract query. The getNextQuery should be idempotent")
    }

    let p2Query = queries->Array.getUnsafe(0)

    // When it didn't finish fetching to the target partition block
    fetchState->FetchState.startFetchingQueries(~queries=[p2Query])
    let fetchStateWithResponse1 = fetchState->FetchState.handleQueryResult(
      ~query=p2Query,
      ~latestFetchedBlock={
        blockNumber: 9,
        blockTimestamp: 9,
      },
      ~newItems=[mockEvent(~blockNumber=4, ~logIndex=6), mockEvent(~blockNumber=4, ~logIndex=2)],
    )

    Assert.deepEqual(
      (
        fetchStateWithResponse1->FetchState.bufferBlock,
        fetchStateWithResponse1.optimizedPartitions.idsInAscOrder,
        fetchStateWithResponse1.buffer->Js.Array2.length,
      ),
      (
        {
          blockNumber: 9,
          blockTimestamp: 9,
        },
        ["2", "0"],
        4,
      ),
      ~message="The buffer block should be the latest fetched block",
    )

    Assert.deepEqual(
      fetchStateWithResponse1->getNextQuery(~targetBufferSize=1),
      NothingToQuery,
      ~message=`Even if we have a partition with toBlock which wants to merge
      if it's outside of the targetBufferSize limit, we should return NothingToQuery`,
    )

    let queries = switch fetchStateWithResponse1->getNextQuery {
    | Ready(queries) => queries
    | _ => Assert.fail("Failed to extract query. The getNextQuery should be idempotent")
    }
    fetchStateWithResponse1->FetchState.startFetchingQueries(~queries)

    let fetchStateWithResponse2 = fetchStateWithResponse1->FetchState.handleQueryResult(
      ~query=queries->Array.getUnsafe(0),
      ~latestFetchedBlock={
        blockNumber: 10,
        blockTimestamp: 10,
      },
      ~newItems=[],
    )

    Assert.deepEqual(
      fetchStateWithResponse2,
      {
        ...fetchStateWithResponse1,
        optimizedPartitions: FetchState.OptimizedPartitions.make(
          ~partitions=[
            {
              id: "0",
              dynamicContract: Some("Gravatar"),
              mutPendingQueries: [
                {
                  fromBlock: 11,
                  toBlock: None,
                  isChunk: false,
                  fetchedBlock: None,
                },
              ],
              prevQueryRange: 0,
              prevPrevQueryRange: 0,
              latestBlockRangeUpdateBlock: 0,
              latestFetchedBlock: {
                blockNumber: 10,
                blockTimestamp: 10,
              },
              selection: fetchState.normalSelection,
              addressesByContractName: Js.Dict.fromArray([
                ("Gravatar", [mockAddress0, mockAddress1, mockAddress2, mockAddress3]),
              ]),
              mergeBlock: None,
            },
          ],
          ~nextPartitionIndex=fetchStateWithResponse1.optimizedPartitions.nextPartitionIndex,
          ~maxAddrInPartition=fetchStateWithResponse1.optimizedPartitions.maxAddrInPartition,
          ~dynamicContracts=fetchStateWithResponse1.optimizedPartitions.dynamicContracts,
        ),
      },
      ~message="Partition 2 should come to mergeBlock and be removed",
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

    Assert.deepEqual(fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count, 3)

    let nextQuery = {...fetchState, knownHeight: 10}->FetchState.getNextQuery(~concurrencyLimit=10)

    Assert.deepEqual(
      nextQuery,
      Ready([
        {
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
        },
        {
          partitionId: "1",
          fromBlock: 0,
          toBlock: undefined,
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("ContractA", [mockAddress1])]),
          indexingContracts: fetchState.indexingContracts,
        },
        {
          partitionId: "2",
          fromBlock: 2,
          toBlock: undefined,
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress2])]),
          indexingContracts: fetchState.indexingContracts,
        },
      ]),
      ~message=`Wildcard partition "0" is untouched.
      Partitions "1" and "2" split in optimized way for further dynamic contract registrations.
      All queries performed in parallel without locking.`,
    )
  })

  it("Correctly rollbacks fetch state", () => {
    let fetchState = makeIntermidiateDcMerge()

    // Rollback to block 2: both DCs survive (regBlock <= 2)
    // Partition "0" (lfb=10 > 2) -> DELETED, addresses recreated as partition "1"
    // Partition "2" (lfb=2 <= 2) -> KEPT as partition "0" (IDs reset)
    let fetchStateAfterRollback1 = fetchState->FetchState.rollback(~targetBlockNumber=2)
    Assert.deepEqual(
      fetchStateAfterRollback1,
      {
        ...fetchState,
        optimizedPartitions: FetchState.OptimizedPartitions.make(
          ~partitions=[
            {
              id: "0",
              latestFetchedBlock: {
                blockNumber: 2,
                blockTimestamp: 0,
              },
              dynamicContract: Some("Gravatar"),
              mutPendingQueries: [],
              prevQueryRange: 0,
              prevPrevQueryRange: 0,
              latestBlockRangeUpdateBlock: 0,
              selection: fetchState.normalSelection,
              addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
              mergeBlock: None,
            },
            {
              id: "1",
              latestFetchedBlock: {
                blockNumber: 2,
                blockTimestamp: 0,
              },
              dynamicContract: Some("Gravatar"),
              mutPendingQueries: [],
              prevQueryRange: 0,
              prevPrevQueryRange: 0,
              latestBlockRangeUpdateBlock: 0,
              selection: fetchState.normalSelection,
              addressesByContractName: Js.Dict.fromArray([
                ("Gravatar", [mockAddress0, mockAddress1, mockAddress2]),
              ]),
              mergeBlock: None,
            },
          ],
          ~nextPartitionIndex=2,
          ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
          ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
        ),
      },
      ~message=`Rollbacks partitions: kept "0", recreated "1" from deleted`,
    )

    // Rollback to block 1: dc2 and dc3 removed (regBlock=2 > 1)
    // Both partitions deleted (lfb > 1), surviving addresses [addr0, addr1] recreated
    let fetchStateAfterRollback2 = fetchState->FetchState.rollback(~targetBlockNumber=1)
    Assert.deepEqual(
      fetchStateAfterRollback2,
      {
        ...fetchState,
        indexingContracts: makeIndexingContractsWithDynamics([dc1], ~static=[mockAddress0]),
        optimizedPartitions: FetchState.OptimizedPartitions.make(
          ~partitions=[
            {
              id: "0",
              latestFetchedBlock: {
                blockNumber: 1,
                blockTimestamp: 0,
              },
              dynamicContract: Some("Gravatar"),
              mutPendingQueries: [],
              prevQueryRange: 0,
              prevPrevQueryRange: 0,
              latestBlockRangeUpdateBlock: 0,
              selection: fetchState.normalSelection,
              // Removed dc2 and dc3, even though the latestFetchedBlock is not exceeding the lastScannedBlock
              addressesByContractName: Js.Dict.fromArray([
                ("Gravatar", [mockAddress0, mockAddress1]),
              ]),
              mergeBlock: None,
            },
            // Removed partition "2"
          ],
          ~nextPartitionIndex=1,
          ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
          ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
        ),
        // Removed an item here

        buffer: [mockEvent(~blockNumber=1)],
      },
      ~message=`Both partitions deleted, surviving addresses recreated as partition "0"`,
    )

    // Rollback to block -1: all DCs removed, only static addr0 survives
    let fetchStateAfterRollback3 = fetchState->FetchState.rollback(~targetBlockNumber=-1)
    Assert.deepEqual(
      fetchStateAfterRollback3,
      {
        ...fetchState,
        indexingContracts: makeIndexingContractsWithDynamics([], ~static=[mockAddress0]),
        optimizedPartitions: FetchState.OptimizedPartitions.make(
          ~partitions=[
            {
              id: "0",
              latestFetchedBlock: {
                blockNumber: -1,
                blockTimestamp: 0,
              },
              dynamicContract: Some("Gravatar"),
              mutPendingQueries: [],
              prevQueryRange: 0,
              prevPrevQueryRange: 0,
              latestBlockRangeUpdateBlock: 0,
              selection: fetchState.normalSelection,
              addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
              mergeBlock: None,
            },
          ],
          ~nextPartitionIndex=1,
          ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
          ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
        ),
        buffer: [],
      },
      ~message=`All DCs removed, only static addr0 recreated as partition "0"`,
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

    // Additionally test that state being reset
    fetchState->FetchState.startFetchingQueries(
      ~queries=[
        {
          partitionId: "0",
          toBlock: None,
          selection: {
            dependsOnAddresses: false,
            eventConfigs: wildcardEventConfigs,
          },
          addressesByContractName: Js.Dict.empty(),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
          isChunk: false,
        },
      ],
    )

    Assert.deepEqual(
      fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count,
      2,
      ~message=`Should have 2 partitions before rollback`,
    )

    // resetPendingQueries must be called before rollback (removes in-flight queries)
    let fetchStateReset = fetchState->FetchState.resetPendingQueries
    let fetchStateAfterRollback = fetchStateReset->FetchState.rollback(~targetBlockNumber=1)

    Assert.deepEqual(
      fetchStateAfterRollback,
      {
        ...fetchState,
        indexingContracts: Js.Dict.empty(),
        optimizedPartitions: FetchState.OptimizedPartitions.make(
          ~partitions=[
            {
              id: "0",
              latestFetchedBlock: {
                blockNumber: -1,
                blockTimestamp: 0,
              },
              dynamicContract: None,
              mutPendingQueries: [],
              prevQueryRange: 0,
              prevPrevQueryRange: 0,
              latestBlockRangeUpdateBlock: 0,
              selection: {
                dependsOnAddresses: false,
                eventConfigs: wildcardEventConfigs,
              },
              addressesByContractName: Js.Dict.empty(),
              mergeBlock: None,
            },
          ],
          // IDs reset on rollback
          ~nextPartitionIndex=1,
          ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
          ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
        ),
        buffer: [],
      },
      ~message=`Should keep Wildcard partition even if it's empty`,
    )
  })
})

describe("FetchState unit tests for specific cases", () => {
  it("Should merge events in correct order on merging", () => {
    let base = makeInitial()
    let normalSelection = base.normalSelection
    let fetchState = base->FetchState.updateInternal(
      ~optimizedPartitions=FetchState.OptimizedPartitions.make(
        ~partitions=[
          {
            id: "0",
            latestFetchedBlock: {
              blockNumber: 10,
              blockTimestamp: 10,
            },
            dynamicContract: None,
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
            selection: normalSelection,
            addressesByContractName: Js.Dict.empty(),
            mergeBlock: None,
          },
          {
            id: "1",
            latestFetchedBlock: {
              blockNumber: 1,
              blockTimestamp: 0,
            },
            dynamicContract: None,
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
            selection: normalSelection,
            addressesByContractName: Js.Dict.empty(),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=2,
        ~maxAddrInPartition=base.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=base.optimizedPartitions.dynamicContracts,
      ),
      ~mutItems=[
        mockEvent(~blockNumber=4, ~logIndex=2),
        mockEvent(~blockNumber=4),
        mockEvent(~blockNumber=3),
        mockEvent(~blockNumber=2),
        mockEvent(~blockNumber=1),
      ],
    )

    let query: FetchState.query = {
      partitionId: "1",
      fromBlock: 1,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.empty(),
      indexingContracts: fetchState.indexingContracts,
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState = fetchState->FetchState.handleQueryResult(
      ~query,
      ~latestFetchedBlock={
        blockNumber: 10,
        blockTimestamp: 10,
      },
      ~newItems=[mockEvent(~blockNumber=4, ~logIndex=1), mockEvent(~blockNumber=4, ~logIndex=1)],
    )

    Assert.deepEqual(
      updatedFetchState.buffer,
      [
        mockEvent(~blockNumber=1),
        mockEvent(~blockNumber=2),
        mockEvent(~blockNumber=3),
        mockEvent(~blockNumber=4),
        mockEvent(~blockNumber=4, ~logIndex=1),
        mockEvent(~blockNumber=4, ~logIndex=1),
        mockEvent(~blockNumber=4, ~logIndex=2),
      ],
      ~message="Should merge events in correct order",
    )
  })

  it("Sorts newItems when source returns them unsorted", () => {
    let base = makeInitial()
    let fetchState = base

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
      addressesByContractName: Js.Dict.empty(),
      indexingContracts: fetchState.indexingContracts,
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
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
      ~message="Queue must be sorted DESC by (blockNumber, logIndex) regardless of input order",
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
      addressesByContractName: Js.Dict.empty(),
      indexingContracts: fetchState.indexingContracts,
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query0, query1])
    let fetchState =
      fetchState
      ->FetchState.handleQueryResult(
        ~query=query0,
        ~latestFetchedBlock=getBlockData(~blockNumber=1),
        ~newItems=[mockEvent(~blockNumber=1), mockEvent(~blockNumber=0)],
      )
      ->FetchState.handleQueryResult(
        ~query=query1,
        ~latestFetchedBlock=getBlockData(~blockNumber=2),
        ~newItems=[],
      )

    Assert.deepEqual(
      {...fetchState, knownHeight: 2}->FetchState.getNextQuery(~concurrencyLimit=10),
      Ready([
        {
          partitionId: "0",
          fromBlock: 2,
          toBlock: None,
          isChunk: false,
          selection: {
            dependsOnAddresses: false,
            eventConfigs: [wildcard],
          },
          addressesByContractName: Js.Dict.empty(),
          indexingContracts: fetchState.indexingContracts,
        },
      ]),
      ~message=`Should be possible to query wildcard partition,
      if it didn't reach max queue size limit`,
    )
    Assert.deepEqual(
      {
        ...fetchState,
        targetBufferSize: 2,
        knownHeight: 2,
      }->FetchState.getNextQuery(~concurrencyLimit=10),
      NothingToQuery,
      ~message=`Should wait until queue is processed, to continue fetching.
      Don't wait for new block, until all partitions reached the head`,
    )
  })

  it("Allows to get event one block earlier than the dc registring event", () => {
    let fetchState = makeInitial(~knownHeight=10)

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
      addressesByContractName: Js.Dict.empty(),
      indexingContracts: fetchState.indexingContracts,
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let fetchStateWithEvents =
      fetchState->FetchState.handleQueryResult(
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
      addressesByContractName: Js.Dict.empty(),
      indexingContracts: fetchState.indexingContracts,
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~newItems=[mockEvent(~blockNumber=0, ~logIndex=1)],
        ~latestFetchedBlock=getBlockData(~blockNumber=1),
      )

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

  it("Get earliest event", () => {
    let latestFetchedBlock = getBlockData(~blockNumber=500)
    let base = makeInitial()
    let normalSelection = base.normalSelection
    let fetchState = base->FetchState.updateInternal(
      ~optimizedPartitions=FetchState.OptimizedPartitions.make(
        ~partitions=[
          {
            id: "0",
            latestFetchedBlock,
            dynamicContract: None,
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
            selection: normalSelection,
            addressesByContractName: Js.Dict.empty(),
            mergeBlock: None,
          },
          {
            id: "1",
            latestFetchedBlock,
            dynamicContract: None,
            mutPendingQueries: [],
            prevQueryRange: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
            selection: normalSelection,
            addressesByContractName: Js.Dict.empty(),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=2,
        ~maxAddrInPartition=base.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=base.optimizedPartitions.dynamicContracts,
      ),
      ~mutItems=[
        mockEvent(~blockNumber=6, ~logIndex=1),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=2, ~logIndex=1),
      ],
      ~knownHeight=10,
    )

    Assert.deepEqual(
      fetchState->getEarliestEvent->getItem,
      Some(mockEvent(~blockNumber=2, ~logIndex=1)),
    )

    Assert.deepEqual(
      fetchState
      ->FetchState.registerDynamicContracts([
        makeDynContractRegistration(~contractAddress=mockAddress1, ~blockNumber=2)->dcToItem,
      ])
      ->getEarliestEvent,
      NoItem({
        latestFetchedBlock: {
          blockNumber: 1,
          blockTimestamp: 0,
        },
      }),
      ~message=`Accounts for registered dynamic contracts`,
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
    let fetchState = {
      ...makeInitial(),
      endBlock: Some(0),
    }
    let query: FetchState.query = {
      partitionId: "0",
      fromBlock: 0,
      toBlock: Some(0),
      isChunk: false,
      selection: makeInitial().normalSelection,
      addressesByContractName: Js.Dict.empty(),
      indexingContracts: fetchState.indexingContracts,
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    Assert.deepEqual(
      fetchState
      ->FetchState.handleQueryResult(
        ~query,
        ~newItems=[mockEvent(~blockNumber=0)],
        ~latestFetchedBlock={blockNumber: -1, blockTimestamp: 0},
      )
      ->FetchState.isActivelyIndexing,
      true,
      ~message=`Although, with items in the queue it should be considered active`,
    )
  })

  it(
    "Adding dc between two partitions while query is mid flight does no result in early merged partitinons",
    () => {
      let knownHeight = 600

      let fetchState = FetchState.make(
        ~eventConfigs=[baseEventConfig],
        ~contracts=[makeConfigContract("Gravatar", mockAddress1)],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=2,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      let query: FetchState.query = {
        partitionId: "0",
        selection: fetchState.normalSelection,
        addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress1])]),
        indexingContracts: fetchState.indexingContracts,
        fromBlock: 0,
        toBlock: None,
        isChunk: false,
      }
      fetchState->FetchState.startFetchingQueries(~queries=[query])
      let fetchState =
        fetchState->FetchState.handleQueryResult(
          ~query,
          ~newItems=[
            mockEvent(~blockNumber=6, ~logIndex=2),
            mockEvent(~blockNumber=4),
            mockEvent(~blockNumber=1, ~logIndex=1),
          ],
          ~latestFetchedBlock=getBlockData(~blockNumber=500),
        )

      //Dynamic contract A registered at block 100
      let dcA = makeDynContractRegistration(~contractAddress=mockAddress2, ~blockNumber=100)
      let fetchStateWithDcA = fetchState->FetchState.registerDynamicContracts([dcA->dcToItem])

      let queries = switch fetchStateWithDcA->FetchState.getNextQuery(~concurrencyLimit=10) {
      | Ready(queries) => queries
      | _ => Assert.fail("Expected Ready queries")
      }

      Assert.deepEqual(
        queries,
        [
          {
            ...queries->Array.getUnsafe(0),
            partitionId: "1",
            toBlock: Some(500),
            fromBlock: 100,
          },
          {
            ...queries->Array.getUnsafe(1),
            partitionId: "0",
            fromBlock: 501,
            toBlock: None,
          },
        ],
      )

      let queryA = queries->Array.getUnsafe(0)

      // Emulate that we started fetching the first query
      fetchStateWithDcA->FetchState.startFetchingQueries(~queries=[queryA])

      //Next registration happens at block 200, between the first register and the upperbound of it's query
      let dc3 = makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=200)
      let fetchStateWithDcB =
        fetchStateWithDcA->FetchState.registerDynamicContracts([dc3->dcToItem])

      let queries = switch fetchStateWithDcB->FetchState.getNextQuery(~concurrencyLimit=10) {
      | Ready(queries) => queries
      | _ => Assert.fail("Expected Ready queries")
      }
      let partition2Query = {
        ...queries->Array.getUnsafe(0),
        addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress3])]),
        indexingContracts: fetchStateWithDcB.indexingContracts,
        partitionId: "2",
        toBlock: None, // Didn't merge because reached max addresses in partition
        fromBlock: 200,
      }
      Assert.deepEqual(
        fetchStateWithDcB->FetchState.getNextQuery(~concurrencyLimit=10),
        Ready([partition2Query, queries->Array.getUnsafe(1)]),
        ~message=`Create a new partition for the newly registered contract`,
      )

      //Response with updated fetch state
      let fetchStateWithBothDcsAndQueryAResponse =
        fetchStateWithDcB->FetchState.handleQueryResult(
          ~query=queryA,
          ~latestFetchedBlock=getBlockData(~blockNumber=400),
          ~newItems=[],
        )

      Assert.deepEqual(
        fetchStateWithBothDcsAndQueryAResponse->FetchState.getNextQuery(~concurrencyLimit=10),
        Ready([
          partition2Query,
          {
            ...queryA,
            indexingContracts: fetchStateWithBothDcsAndQueryAResponse.indexingContracts,
            partitionId: "1",
            toBlock: Some(500),
            fromBlock: 401,
          },
          queries->Array.getUnsafe(1),
        ]),
        ~message=`We don't merge partition 2 to partition 1, since it already has end block`,
      )
    },
  )
})

describe("FetchState.sortForUnorderedBatch", () => {
  let mkQuery = (fetchState: FetchState.t) => {
    {
      FetchState.partitionId: "0",
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Js.Dict.empty(),
      fromBlock: 0,
      indexingContracts: fetchState.indexingContracts,
    }
  }

  // Helper: create a fetch state with desired latestFetchedBlock and queue items via public API
  let makeFsWith = (~latestBlock: int, ~queueBlocks: array<int>): FetchState.t => {
    let fs0 = makeInitial(~knownHeight=10)
    let query = mkQuery(fs0)
    fs0->FetchState.startFetchingQueries(~queries=[query])
    fs0->FetchState.handleQueryResult(
      ~query,
      ~latestFetchedBlock={blockNumber: latestBlock, blockTimestamp: latestBlock},
      ~newItems=queueBlocks->Array.map(b => mockEvent(~blockNumber=b)),
    )
  }

  it("Sorts by progress percentage. Chains further behind have higher priority", () => {
    // Low progress: first item at block 1, knownHeight=10 → 10% progress
    let fsLow = makeFsWith(~latestBlock=3, ~queueBlocks=[1])
    // Mid progress: first item at block 5, knownHeight=10 → 50% progress
    let fsMid = makeFsWith(~latestBlock=7, ~queueBlocks=[5])
    // High progress: first item at block 8, knownHeight=10 → 80% progress
    let fsHigh = makeFsWith(~latestBlock=10, ~queueBlocks=[8])

    let prepared = FetchState.sortForUnorderedBatch(
      [fsHigh, fsLow, fsMid],
      ~batchSizeTarget=3,
    )

    Assert.deepEqual(
      prepared->Array.map(fs => fs.buffer->Belt.Array.getUnsafe(0)->Internal.getItemBlockNumber),
      [1, 5, 8],
    )
  })

  it("Prioritizes full batches over half full ones", () => {
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

  it("Treats exactly-full batches as full", () => {
    // Exactly full (== maxBatchSize items)
    let fsExactFull = makeFsWith(~latestBlock=10, ~queueBlocks=[3, 2])
    // Half-full (1 item) but earlier earliest item
    let fsHalfEarlier = makeFsWith(~latestBlock=10, ~queueBlocks=[1])

    let prepared = FetchState.sortForUnorderedBatch(
      [fsHalfEarlier, fsExactFull],
      ~batchSizeTarget=2,
    )

    // Full batch should take priority regardless of earlier timestamp of half batch
    Assert.deepEqual(
      prepared->Array.map(fs => fs.buffer->Belt.Array.getUnsafe(0)->Internal.getItemBlockNumber),
      [2, 1],
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

  it("Returns true when no endBlock and latest >= head - blockLag (boundary)", () => {
    // latestFullyFetchedBlock = 50, head - lag = 50
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~contracts=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          startBlock: 51,
          registrationBlock: None,
        },
      ],
      ~startBlock=51,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~targetBufferSize,
      ~chainId,
      ~blockLag=10,
      ~knownHeight=60,
    )
    Assert.equal(fs->FetchState.isReadyToEnterReorgThreshold, true)
  })

  it("Returns false when no endBlock and latest < head - blockLag", () => {
    // latestFullyFetchedBlock = 49, head - lag = 50
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
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~targetBufferSize,
      ~chainId,
      ~blockLag=10,
      ~knownHeight=60,
    )
    Assert.equal(fs->FetchState.isReadyToEnterReorgThreshold, false)
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

  it("Returns true when the queue is empty and threshold is more than current block height", () => {
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
      ~blockLag=200,
      ~knownHeight=10,
    )
    Assert.equal(fs->FetchState.isReadyToEnterReorgThreshold, true)
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
    let fs0 = makeInitial(~knownHeight=1000)
    let query = {
      FetchState.partitionId: "0",
      toBlock: None,
      isChunk: false,
      selection: fs0.normalSelection,
      addressesByContractName: Js.Dict.empty(),
      fromBlock: 0,
      indexingContracts: fs0.indexingContracts,
    }
    fs0->FetchState.startFetchingQueries(~queries=[query])
    fs0->FetchState.handleQueryResult(
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

  it("When queue has a single item with non 0 log index", () => {
    let fetchStateSingleItem = makeFetchStateWith(~latestBlock=55, ~queueBlocks=[(55, 5)])

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

      let query0 = {
        FetchState.partitionId: "0",
        toBlock: None,
        isChunk: false,
        selection: fetchStateWithTwoPartitions.normalSelection,
        addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
        fromBlock: 0,
        indexingContracts: fetchStateWithTwoPartitions.indexingContracts,
      }

      fetchStateWithTwoPartitions->FetchState.startFetchingQueries(~queries=[query0])
      let fetchStateWithLargeQueue =
        fetchStateWithTwoPartitions->FetchState.handleQueryResult(
          ~query=query0,
          ~latestFetchedBlock={blockNumber: 30, blockTimestamp: 30 * 15},
          ~newItems=largeQueueEvents,
        )

      // Test case 1: With endBlock set, should be limited by maxQueryBlockNumber
      let fetchStateWithEndBlock = {
        ...fetchStateWithLargeQueue,
        endBlock: Some(25),
        knownHeight: 30,
      }

      switch fetchStateWithEndBlock->FetchState.getNextQuery(~concurrencyLimit=10) {
      | Ready([q]) =>
        // The query should have endBlock limited to maxQueryBlockNumber (15)
        Assert.equal(
          q.toBlock,
          Some(15),
          ~message="Should limit endBlock to maxQueryBlockNumber (15) when both endBlock and maxQueryBlockNumber are present",
        )
      | _ => Assert.fail("Expected Ready query when buffer limiting is active")
      }

      // Test case 2: endBlock=None, maxQueryBlockNumber=15 -> Should use Some(15)
      let fetchStateNoEndBlock = {...fetchStateWithLargeQueue, endBlock: None, knownHeight: 30}
      switch fetchStateNoEndBlock->FetchState.getNextQuery(~concurrencyLimit=10) {
      | Ready([q]) =>
        Assert.equal(
          q.toBlock,
          Some(15),
          ~message="Should set endBlock to maxQueryBlockNumber (15) when no endBlock was specified",
        )
      | _ => Assert.fail("Expected Ready query when buffer limiting is active")
      }

      // Test case 3: Small queue, no buffer limiting -> Should use Head target
      let query3 = {
        FetchState.partitionId: "0",
        toBlock: None,
        isChunk: false,
        selection: fetchState.normalSelection,
        addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
        fromBlock: 0,
        indexingContracts: fetchState.indexingContracts,
      }
      fetchState->FetchState.startFetchingQueries(~queries=[query3])
      let fetchStateSmallQueue =
        fetchState
        ->FetchState.handleQueryResult(
          ~query=query3,
          ~latestFetchedBlock={blockNumber: 10, blockTimestamp: 10 * 15},
          ~newItems=[mockEvent(~blockNumber=5)],
        )
        ->FetchState.updateKnownHeight(~knownHeight=30)

      switch fetchStateSmallQueue->FetchState.getNextQuery(~concurrencyLimit=10) {
      | Ready([q]) =>
        Assert.equal(q.toBlock, None, ~message="Should use None when buffer is not limited")
      | _ => Assert.fail("Expected Ready query")
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
      Assert.deepEqual(
        fetchState.optimizedPartitions.idsInAscOrder,
        [],
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

      // Verify buffer is now filled with block items
      Assert.equal(
        updatedFetchState.knownHeight,
        20,
        ~message="knownHeight should be updated to 20",
      )

      // Buffer should contain block items for blocks 0-9 (interval=1, startBlock=0, up to targetBufferSize limit)
      // Since latestFullyFetchedBlock is initially -1 and there are no partitions
      Assert.equal(
        updatedFetchState.latestOnBlockBlockNumber,
        10,
        ~message="latestOnBlockBlockNumber should be 10 since the onBlock config is interval=1 and startBlock=0",
      )
      Assert.equal(updatedFetchState->FetchState.bufferBlockNumber, 10)

      // Block items should be created from block 0 up to min(latestFullyFetchedBlock, targetBufferSize item)
      // With interval=1, startBlock=0, we expect blocks 0,1,2,3,4,5,6,7,8,9,10
      let blockNumbers =
        updatedFetchState.buffer->Array.map(item => item->Internal.getItemBlockNumber)

      Assert.deepEqual(
        blockNumbers,
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
        ~message="Buffer should contain block items for blocks 0-10",
      )

      // Test that getNextQuery returns NothingToQuery (no partitions to query)
      let nextQuery2 = updatedFetchState->FetchState.getNextQuery(~concurrencyLimit=10)
      Assert.deepEqual(
        nextQuery2,
        NothingToQuery,
        ~message="Should return NothingToQuery when there are no partitions to query",
      )
    },
  )
})

describe("Stale query response should not overwrite block range", () => {
  // The default configuration with ability to overwrite some values
  let getNextQuery = (
    fs,
    ~knownHeight=100000,
    ~concurrencyLimit=10,
  ) =>
    fs
    ->FetchState.updateKnownHeight(~knownHeight)
    ->FetchState.getNextQuery(~concurrencyLimit)

  it(
    "Out-of-order parallel query responses should not degrade chunking heuristic",
    () => {
      let fetchState = makeInitial(~knownHeight=100000)

      // -- Query 1: uncapped query from block 0 --
      let q1 = switch fetchState->getNextQuery {
      | Ready([q]) => q
      | _ => Assert.fail("Expected a single query")
      }
      fetchState->FetchState.startFetchingQueries(~queries=[q1])

      // Response arrives at block 500 (range = 501)
      // shouldUpdateBlockRange: None toBlock => 500 < 100000 - 10 = true
      let fs1 =
        fetchState
        ->FetchState.updateKnownHeight(~knownHeight=100000)
        ->FetchState.handleQueryResult(
          ~query=q1,
          ~latestFetchedBlock={blockNumber: 500, blockTimestamp: 500 * 15},
          ~newItems=[],
        )

      let p1 = fs1.optimizedPartitions.entities->Js.Dict.unsafeGet("0")
      Assert.equal(p1.prevQueryRange, 501, ~message="First query should set prevQueryRange=501")
      Assert.equal(
        p1.prevPrevQueryRange,
        0,
        ~message="First query prevPrevQueryRange should still be 0",
      )
      Assert.equal(
        p1.latestBlockRangeUpdateBlock,
        500,
        ~message="latestBlockRangeUpdateBlock should be 500 after first query",
      )

      // -- Query 2: uncapped query from block 501 --
      let q2 = switch fs1->getNextQuery {
      | Ready([q]) => q
      | _ => Assert.fail("Expected a single query for second round")
      }
      fs1->FetchState.startFetchingQueries(~queries=[q2])

      // Response arrives at block 1000 (range = 500)
      // shouldUpdateBlockRange: None toBlock => 1000 < 99990 = true
      let fs2 = fs1->FetchState.handleQueryResult(
        ~query=q2,
        ~latestFetchedBlock={blockNumber: 1000, blockTimestamp: 1000 * 15},
        ~newItems=[],
      )

      let p2 = fs2.optimizedPartitions.entities->Js.Dict.unsafeGet("0")
      Assert.equal(p2.prevQueryRange, 500, ~message="Second query should set prevQueryRange=500")
      Assert.equal(
        p2.prevPrevQueryRange,
        501,
        ~message="Second query should shift prevPrevQueryRange=501",
      )
      Assert.equal(p2.latestBlockRangeUpdateBlock, 1000)

      // Now chunking is active: getMinHistoryRange = Some(min(500, 501)) = Some(500)
      // chunkSize = ceil(500 * 1.8) = 900
      // Chunks: [1001..1900] and [1901..2800]

      // -- Query 3: get two chunk queries in parallel --
      let (chunkA, chunkB) = switch fs2->getNextQuery(~concurrencyLimit=2) {
      | Ready([a, b]) => (a, b)
      | _ => Assert.fail("Expected two chunk queries")
      }

      Assert.equal(chunkA.fromBlock, 1001, ~message="Chunk A should start at 1001")
      Assert.equal(chunkB.fromBlock, 1901, ~message="Chunk B should start at 1901")

      fs2->FetchState.startFetchingQueries(~queries=[chunkA, chunkB])

      // -- Respond to the LATER chunk (B) first --
      // Partial response: latestFetchedBlock=2500 < toBlock=2800
      // shouldUpdateBlockRange: 2500 > 1000 (latestBlockRangeUpdateBlock) = true,
      //   then 2500 < 2800 = true (partial response)
      // blockRange = 2500 - 1901 + 1 = 600
      let fs3 = fs2->FetchState.handleQueryResult(
        ~query=chunkB,
        ~latestFetchedBlock={blockNumber: 2500, blockTimestamp: 2500 * 15},
        ~newItems=[],
      )

      let p3 = fs3.optimizedPartitions.entities->Js.Dict.unsafeGet("0")
      Assert.equal(
        p3.prevQueryRange,
        600,
        ~message="Chunk B response should update prevQueryRange to 600",
      )
      Assert.equal(
        p3.prevPrevQueryRange,
        500,
        ~message="Chunk B response should shift prevPrevQueryRange to 500",
      )
      Assert.equal(
        p3.latestBlockRangeUpdateBlock,
        2500,
        ~message="latestBlockRangeUpdateBlock should update to 2500",
      )

      // -- Now respond to the EARLIER chunk (A) --
      // Partial response: latestFetchedBlock=1400 < toBlock=1900
      // shouldUpdateBlockRange: 1400 > 2500 (latestBlockRangeUpdateBlock) = FALSE
      // So prevQueryRange should NOT change
      let fs4 = fs3->FetchState.handleQueryResult(
        ~query=chunkA,
        ~latestFetchedBlock={blockNumber: 1400, blockTimestamp: 1400 * 15},
        ~newItems=[],
      )

      let p4 = fs4.optimizedPartitions.entities->Js.Dict.unsafeGet("0")
      Assert.equal(
        p4.prevQueryRange,
        600,
        ~message="Earlier chunk A response should NOT overwrite prevQueryRange (still 600)",
      )
      Assert.equal(
        p4.prevPrevQueryRange,
        500,
        ~message="Earlier chunk A response should NOT overwrite prevPrevQueryRange (still 500)",
      )
      Assert.equal(
        p4.latestBlockRangeUpdateBlock,
        2500,
        ~message="latestBlockRangeUpdateBlock should remain 2500 after stale response",
      )
    },
  )
})
