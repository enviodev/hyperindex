open Vitest

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

let mockAddress0 = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow
let mockAddress1 = Envio.TestHelpers.Addresses.mockAddresses[1]->Option.getOrThrow
let mockAddress2 = Envio.TestHelpers.Addresses.mockAddresses[2]->Option.getOrThrow
let mockAddress3 = Envio.TestHelpers.Addresses.mockAddresses[3]->Option.getOrThrow
let mockAddress4 = Envio.TestHelpers.Addresses.mockAddresses[4]->Option.getOrThrow
let mockAddress5 = Envio.TestHelpers.Addresses.mockAddresses[5]->Option.getOrThrow
let mockAddress6 = Envio.TestHelpers.Addresses.mockAddresses[6]->Option.getOrThrow
let mockFactoryAddress = Envio.TestHelpers.Addresses.mockAddresses[7]->Option.getOrThrow

let getTimestamp = (~blockNumber) => blockNumber * 15
let getBlockData = (~blockNumber): FetchState.blockNumberAndTimestamp => {
  blockNumber,
  blockTimestamp: getTimestamp(~blockNumber),
}

let makeDynContractRegistration = (
  ~contractAddress,
  ~blockNumber,
  ~contractName="Gravatar",
): Internal.indexingAddress => {
  {
    address: contractAddress,
    contractName,
    registrationBlock: blockNumber,
  }
}

let makeConfigContract = (contractName, address): Internal.indexingAddress => {
  {
    address,
    contractName,
    registrationBlock: -1,
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

let dcToItem = (dc: Internal.indexingAddress) => {
  let item = mockEvent(~blockNumber=dc.registrationBlock)
  item->Internal.setItemDcs([dc])
  item
}

let baseEventConfig = (MockIndexer.evmEventConfig(
  ~id="0",
  ~contractName="Gravatar",
) :> Internal.eventConfig)

let baseEventConfig2 = (MockIndexer.evmEventConfig(
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
    ~addresses=[
      {
        Internal.address: mockAddress0,
        contractName: "Gravatar",
        registrationBlock: -1,
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

// Helper to build indexingAddresses dict for test expectations
// Note: dynamic contract info is now only tracked by the register field (DC variant)
let makeIndexingContractsWithDynamics = (
  dcs: array<Internal.indexingAddress>,
  ~static=[],
  ~contractName="Gravatar",
) => {
  let dict: dict<FetchState.indexingAddress> = Dict.make()
  dcs->Array.forEach(dc => {
    dict->Dict.set(
      dc.address->Address.toString,
      {
        address: dc.address,
        contractName: dc.contractName,
        registrationBlock: dc.registrationBlock,
        effectiveStartBlock: FetchState.deriveEffectiveStartBlock(
          ~registrationBlock=dc.registrationBlock,
          ~contractStartBlock=None,
        ),
      },
    )
  })
  static->Array.forEach(address => {
    dict->Dict.set(
      address->Address.toString,
      {
        address,
        contractName,
        registrationBlock: -1,
        effectiveStartBlock: 0,
      },
    )
  })
  dict
}

describe("FetchState.make", () => {
  it("Creates FetchState with a single static address", t => {
    let fetchState = makeInitial()

    t.expect(fetchState).toEqual({
      optimizedPartitions: FetchState.OptimizedPartitions.make(
        ~partitions=[
          {
            id: "0",
            latestFetchedBlock: {
              blockNumber: -1,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
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
      endBlock: None,
      latestOnBlockBlockNumber: -1,
      targetBufferSize: 5000,
      buffer: [],
      normalSelection: fetchState.normalSelection,
      chainId: 0,
      indexingAddresses: fetchState.indexingAddresses,
      contractConfigs: fetchState.contractConfigs,
      blockLag: 0,
      onBlockConfigs: [],
      knownHeight,
      firstEventBlock: None,
    })
  })

  it("Panics with nothing to fetch", t => {
    t.expect(
      () => {
        FetchState.make(
          ~eventConfigs=[baseEventConfig],
          ~addresses=[],
          ~startBlock=0,
          ~endBlock=None,
          ~maxAddrInPartition=2,
          ~targetBufferSize,
          ~chainId,
          ~knownHeight,
        )
      },
      ~message=`Should panic if there's nothing to fetch`,
    ).toThrowError(
      "Invalid configuration: Nothing to fetch. Make sure that you provided at least one contract address to index, or have events with Wildcard mode enabled, or have onBlock handlers.",
    )
  })

  it(
    "Keeps addresses without a matching contract on fetchState so they can be picked up after config changes",
    t => {
      let fetchState = FetchState.make(
        ~eventConfigs=[baseEventConfig],
        ~addresses=[
          makeConfigContract("Gravatar", mockAddress0),
          // Address for a contract that currently has no events configured.
          // Should still be tracked on fetchState and counted via numAddresses.
          makeDynContractRegistration(
            ~blockNumber=42,
            ~contractAddress=mockAddress1,
            ~contractName="NftFactory",
          ),
        ],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      t.expect(
        (
          fetchState->FetchState.numAddresses,
          fetchState.indexingAddresses
          ->Dict.get(mockAddress1->Address.toString)
          ->Option.map(ia => ia.contractName),
          // No partition is created for the contract without events
          fetchState.optimizedPartitions.entities
          ->Dict.valuesToArray
          ->Array.every(p =>
            p.addressesByContractName
            ->Utils.Dict.dangerouslyGetNonOption("NftFactory")
            ->Option.isNone
          ),
        ),
        ~message=`numAddresses counts both addresses,
          the no-events address is tracked under its contract name,
          and no partition is created for the contract without events`,
      ).toEqual((2, Some("NftFactory"), true))
    },
  )

  it("Creates FetchState with static and dc addresses reaching the maxAddrInPartition limit", t => {
    let dc = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress2)
    let fetchState = FetchState.make(
      ~eventConfigs=[baseEventConfig],
      ~addresses=[makeConfigContract("Gravatar", mockAddress1), dc],
      ~startBlock=0,
      ~endBlock=None,
      ~targetBufferSize,
      ~maxAddrInPartition=2,
      ~chainId,
      ~knownHeight,
    )

    t.expect(fetchState, ~message=`Should create only one partition`).toEqual({
      optimizedPartitions: FetchState.OptimizedPartitions.make(
        ~partitions=[
          {
            id: "0",
            latestFetchedBlock: {
              blockNumber: -1,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress1, mockAddress2])]),
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
      endBlock: None,
      normalSelection: fetchState.normalSelection,
      chainId,
      indexingAddresses: fetchState.indexingAddresses,
      contractConfigs: fetchState.contractConfigs,
      blockLag: 0,
      onBlockConfigs: [],
      knownHeight,
      firstEventBlock: None,
    })
  })

  it(
    "Creates FetchState with static addresses and dc addresses exceeding the maxAddrInPartition limit",
    t => {
      let dc = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress2)
      let fetchState = FetchState.make(
        ~eventConfigs=[
          (MockIndexer.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
          baseEventConfig,
        ],
        ~addresses=[makeConfigContract("ContractA", mockAddress1), dc],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=1,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      t.expect(fetchState).toEqual({
        optimizedPartitions: FetchState.OptimizedPartitions.make(
          ~partitions=[
            {
              id: "0",
              latestFetchedBlock: {
                blockNumber: -1,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              addressesByContractName: Dict.fromArray([("ContractA", [mockAddress1])]),
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
              addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress2])]),
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
        endBlock: None,
        normalSelection: fetchState.normalSelection,
        chainId,
        indexingAddresses: fetchState.indexingAddresses,
        contractConfigs: fetchState.contractConfigs,
        blockLag: 0,
        onBlockConfigs: [],
        knownHeight,
        firstEventBlock: None,
      })

      t.expect(
        (fetchState.optimizedPartitions.entities->Dict.getUnsafe("0")).selection,
        ~message=`Selection should be the same instance for all partitions,
        so the WeakMap cache works correctly.`,
      ).toBe((fetchState.optimizedPartitions.entities->Dict.getUnsafe("1")).selection)
    },
  )

  it(
    "Creates FetchState with static and dc addresses exceeding the maxAddrInPartition limit",
    t => {
      let dc1 = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress3)
      let dc2 = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress4)
      let fetchState = FetchState.make(
        ~eventConfigs=[
          (MockIndexer.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
          baseEventConfig,
        ],
        ~addresses=[
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

      t.expect(fetchState).toEqual({
        optimizedPartitions: FetchState.OptimizedPartitions.make(
          ~partitions=[
            {
              id: "0",
              latestFetchedBlock: {
                blockNumber: -1,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              addressesByContractName: Dict.fromArray([("ContractA", [mockAddress1])]),
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
              addressesByContractName: Dict.fromArray([("ContractA", [mockAddress2])]),
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
              addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
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
              addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress4])]),
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
        endBlock: None,
        normalSelection: fetchState.normalSelection,
        chainId,
        indexingAddresses: fetchState.indexingAddresses,
        contractConfigs: fetchState.contractConfigs,
        blockLag: 0,
        onBlockConfigs: [],
        knownHeight,
        firstEventBlock: None,
      })
    },
  )

  it("Two static contracts with different names merge based on block distance", t => {
    let contractAEventConfig = (MockIndexer.evmEventConfig(
      ~id="0",
      ~contractName="ContractA",
    ) :> Internal.eventConfig)
    let closeContractBEventConfig = (MockIndexer.evmEventConfig(
      ~id="0",
      ~contractName="ContractB",
      ~startBlock=19_999,
    ) :> Internal.eventConfig)

    // --- Close startBlocks: direct push into current partition ---
    let closeFetchState = FetchState.make(
      ~eventConfigs=[contractAEventConfig, closeContractBEventConfig],
      ~addresses=[
        {
          address: mockAddress0,
          contractName: "ContractA",
          registrationBlock: -1,
        },
        {
          address: mockAddress1,
          contractName: "ContractB",
          registrationBlock: -1,
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
    t.expect(
      closePartitions.idsInAscOrder,
      ~message="Close startBlocks: should merge into a single partition (direct push)",
    ).toEqual(["0"])
    t.expect(
      (closePartitions.entities->Dict.getUnsafe("0")).addressesByContractName,
      ~message="Close startBlocks: single partition has both contracts' addresses",
    ).toEqual(Dict.fromArray([("ContractA", [mockAddress0]), ("ContractB", [mockAddress1])]))
    t.expect(
      (closePartitions.entities->Dict.getUnsafe("0")).mergeBlock,
      ~message="Close startBlocks: no mergeBlock needed",
    ).toEqual(None)

    // --- Far startBlocks: mergeBlock on current, merge addresses into next ---
    let farContractBEventConfig = (MockIndexer.evmEventConfig(
      ~id="0",
      ~contractName="ContractB",
      ~startBlock=20_002,
    ) :> Internal.eventConfig)
    let farFetchState = FetchState.make(
      ~eventConfigs=[contractAEventConfig, farContractBEventConfig],
      ~addresses=[
        {
          address: mockAddress0,
          contractName: "ContractA",
          registrationBlock: -1,
        },
        {
          address: mockAddress1,
          contractName: "ContractB",
          registrationBlock: -1,
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
    t.expect(
      farPartitions.idsInAscOrder,
      ~message="Far startBlocks: should have 2 partitions with mergeBlock on earlier",
    ).toEqual(["0", "1"])
    t.expect(
      (farPartitions.entities->Dict.getUnsafe("0")).mergeBlock,
      ~message="Far startBlocks: earlier partition has mergeBlock",
    ).toEqual(Some(20_001))
    t.expect(
      (farPartitions.entities->Dict.getUnsafe("1")).addressesByContractName,
      ~message="Far startBlocks: later partition has merged addresses from both contracts",
    ).toEqual(Dict.fromArray([("ContractB", [mockAddress1]), ("ContractA", [mockAddress0])]))
  })

  it(
    "Same contract with close configured startBlocks creates one partition, far startBlocks creates two with mergeBlock",
    t => {
      let contractAEventConfig = (MockIndexer.evmEventConfig(
        ~id="0",
        ~contractName="ContractA",
      ) :> Internal.eventConfig)
      let closeContractBEventConfig = (MockIndexer.evmEventConfig(
        ~id="0",
        ~contractName="ContractB",
        ~startBlock=19_999,
      ) :> Internal.eventConfig)

      // --- Close startBlocks: direct push into current partition ---
      let closeFetchState = FetchState.make(
        ~eventConfigs=[contractAEventConfig, closeContractBEventConfig],
        ~addresses=[
          {
            address: mockAddress0,
            contractName: "ContractA",
            registrationBlock: -1,
          },
          {
            address: mockAddress1,
            contractName: "ContractB",
            registrationBlock: -1,
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
      t.expect(
        closePartitions.idsInAscOrder,
        ~message="Close startBlocks: Phase 1 groups into a single partition",
      ).toEqual(["0"])
      t.expect(
        (closePartitions.entities->Dict.getUnsafe("0")).addressesByContractName,
        ~message="Close startBlocks: single partition has both addresses",
      ).toEqual(
        Dict.fromArray([("ContractA", [mockAddress0]), ("ContractB", [mockAddress1])]),
      )
      t.expect(
        (closePartitions.entities->Dict.getUnsafe("0")).mergeBlock,
        ~message="Close startBlocks: no mergeBlock needed for single partition",
      ).toEqual(None)

      // --- Far startBlocks: mergeBlock on current, merge addresses into next ---
      let farContractBEventConfig = (MockIndexer.evmEventConfig(
        ~id="0",
        ~contractName="ContractB",
        ~startBlock=20_002,
      ) :> Internal.eventConfig)
      let farFetchState = FetchState.make(
        ~eventConfigs=[contractAEventConfig, farContractBEventConfig],
        ~addresses=[
          {
            address: mockAddress0,
            contractName: "ContractA",
            registrationBlock: -1,
          },
          {
            address: mockAddress1,
            contractName: "ContractB",
            registrationBlock: -1,
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
      t.expect(
        farPartitions.idsInAscOrder,
        ~message="Far startBlocks: Phase 1 splits into 2, Phase 2 merges with mergeBlock",
      ).toEqual(["0", "1"])
      t.expect(
        (farPartitions.entities->Dict.getUnsafe("0")).latestFetchedBlock.blockNumber,
        ~message="Far startBlocks: earlier partition starts at block -1",
      ).toEqual(-1)
      t.expect(
        (farPartitions.entities->Dict.getUnsafe("0")).mergeBlock,
        ~message="Far startBlocks: earlier partition has mergeBlock matching later partition's block",
      ).toEqual(Some(20_001))
      t.expect(
        (farPartitions.entities->Dict.getUnsafe("1")).addressesByContractName,
        ~message="Far startBlocks: later partition has merged addresses",
      ).toEqual(
        Dict.fromArray([("ContractB", [mockAddress1]), ("ContractA", [mockAddress0])]),
      )
      t.expect(
        (farPartitions.entities->Dict.getUnsafe("1")).mergeBlock,
        ~message="Far startBlocks: later partition has no mergeBlock",
      ).toEqual(None)
    },
  )

  it("Different contracts with filterByAddresses keeps separate partitions per startBlock", t => {
    let contractAEventConfig = (MockIndexer.evmEventConfig(
      ~id="0",
      ~contractName="ContractA",
      ~filterByAddresses=true,
    ) :> Internal.eventConfig)
    let contractBEventConfig = (MockIndexer.evmEventConfig(
      ~id="0",
      ~contractName="ContractB",
      ~filterByAddresses=true,
      ~startBlock=100,
    ) :> Internal.eventConfig)

    let fetchState = FetchState.make(
      ~eventConfigs=[contractAEventConfig, contractBEventConfig],
      ~addresses=[
        {
          address: mockAddress0,
          contractName: "ContractA",
          registrationBlock: -1,
        },
        {
          address: mockAddress1,
          contractName: "ContractB",
          registrationBlock: -1,
        },
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~targetBufferSize,
      ~chainId,
      ~knownHeight,
    )

    // Phase 1: filterByAddresses=true -> separate partitions per effectiveStartBlock
    // Phase 2: hasFilterByAddresses -> mergeBlock on earlier, merge addresses into later
    let partitions = fetchState.optimizedPartitions
    t.expect(
      partitions.idsInAscOrder,
      ~message="filterByAddresses: should create separate partitions per startBlock",
    ).toEqual(["0", "1"])
    t.expect(
      (partitions.entities->Dict.getUnsafe("0")).addressesByContractName,
      ~message="filterByAddresses: first partition has only ContractA address",
    ).toEqual(Dict.fromArray([("ContractA", [mockAddress0])]))
    t.expect(
      (partitions.entities->Dict.getUnsafe("0")).latestFetchedBlock.blockNumber,
      ~message="filterByAddresses: first partition starts at block -1",
    ).toEqual(-1)
    t.expect(
      (partitions.entities->Dict.getUnsafe("0")).mergeBlock,
      ~message="filterByAddresses: first partition has mergeBlock matching second partition's block",
    ).toEqual(Some(99))
    t.expect(
      (partitions.entities->Dict.getUnsafe("1")).addressesByContractName,
      ~message="filterByAddresses: second partition has merged addresses from both",
    ).toEqual(
      Dict.fromArray([("ContractB", [mockAddress1]), ("ContractA", [mockAddress0])]),
    )
    t.expect(
      (partitions.entities->Dict.getUnsafe("1")).latestFetchedBlock.blockNumber,
      ~message="filterByAddresses: second partition starts at block 99",
    ).toEqual(99)
  })

  it(
    "Different contracts with filterByAddresses use mergeBlock strategy and merge addresses into later partition",
    t => {
      let contractAEventConfig = (MockIndexer.evmEventConfig(
        ~id="0",
        ~contractName="ContractA",
        ~filterByAddresses=true,
      ) :> Internal.eventConfig)
      let contractBEventConfig = (MockIndexer.evmEventConfig(
        ~id="0",
        ~contractName="ContractB",
        ~filterByAddresses=true,
        ~startBlock=100,
      ) :> Internal.eventConfig)

      let fetchState = FetchState.make(
        ~eventConfigs=[contractAEventConfig, contractBEventConfig],
        ~addresses=[
          {
            address: mockAddress0,
            contractName: "ContractA",
            registrationBlock: -1,
          },
          {
            address: mockAddress1,
            contractName: "ContractB",
            registrationBlock: -1,
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
      t.expect(
        partitions.idsInAscOrder,
        ~message="filterByAddresses cross-contract: should have 2 partitions",
      ).toEqual(["0", "1"])
      t.expect(
        (partitions.entities->Dict.getUnsafe("0")).addressesByContractName,
        ~message="filterByAddresses cross-contract: first partition has only ContractA address",
      ).toEqual(Dict.fromArray([("ContractA", [mockAddress0])]))
      t.expect(
        (partitions.entities->Dict.getUnsafe("0")).mergeBlock,
        ~message="filterByAddresses cross-contract: first partition has mergeBlock",
      ).toEqual(Some(99))
      t.expect(
        (partitions.entities->Dict.getUnsafe("1")).addressesByContractName,
        ~message="filterByAddresses cross-contract: second partition has merged addresses from both contracts",
      ).toEqual(Dict.fromArray([("ContractB", [mockAddress1]), ("ContractA", [mockAddress0])]))
      t.expect(
        (partitions.entities->Dict.getUnsafe("1")).latestFetchedBlock.blockNumber,
        ~message="filterByAddresses cross-contract: second partition starts at block 99",
      ).toEqual(99)
    },
  )
})

describe("FetchState.registerDynamicContracts", () => {
  // It shouldn't happen, but just in case
  it("Nothing breaks when provided an empty array", t => {
    let fetchState = makeInitial()

    t.expect(
      fetchState->FetchState.registerDynamicContracts([]),
      ~message="Should return fetchState without updating it",
    ).toBe(fetchState)
  })

  it("Doesn't register a dc which is already registered in config", t => {
    let fetchState = makeInitial()

    t.expect(
      fetchState->FetchState.registerDynamicContracts([
        makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress0)->dcToItem,
      ]),
      ~message="Should return fetchState without updating it",
    ).toBe(fetchState)
  })

  it(
    "Keeps dc for a contract with no events on the item so it is persisted to the db (but doesn't register it for fetching)",
    t => {
      let fetchState = makeInitial()

      // Contract has no event configs in fetchState, so no partition is
      // created. We still want the dc to stay on the item so that
      // InMemoryStore.setBatchDcs writes it to envio_addresses.
      let dc = makeDynContractRegistration(
        ~blockNumber=10,
        ~contractAddress=mockAddress1,
        ~contractName="UnknownContract",
      )
      let item = dc->dcToItem

      let updatedFetchState = fetchState->FetchState.registerDynamicContracts([item])

      t.expect(
        (
          // dc not spliced out of the item - will be saved to db by setBatchDcs
          item->Internal.getItemDcs,
          // not registered for fetching
          updatedFetchState.indexingAddresses
          ->Dict.get(mockAddress1->Address.toString)
          ->Option.isSome,
          updatedFetchState.optimizedPartitions->FetchState.OptimizedPartitions.count,
          // fetchState unchanged
          updatedFetchState === fetchState,
        ),
        ~message=`dc stays on the item (persisted to db),
          is NOT added to fetchState runtime state,
          and fetchState is unchanged`,
      ).toEqual((Some([dc]), false, 1, true))
    },
  )

  it("Correctly registers all valid contracts even when some are skipped in the middle", t => {
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
      updatedFetchState.indexingAddresses
      ->Dict.get(mockAddress1->Address.toString)
      ->Option.isSome
    let hasAddress2 =
      updatedFetchState.indexingAddresses
      ->Dict.get(mockAddress2->Address.toString)
      ->Option.isSome

    t.expect(hasAddress1, ~message="Address1 should be registered").toBe(true)
    t.expect(
      hasAddress2,
      ~message="Address2 should be registered even though Address1 (which came before it) was skipped",
    ).toBe(true)
  })

  it(
    "Should create a new partition for an already registered dc if it has an earlier start block",
    t => {
      let fetchState = makeInitial()

      let dc1 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress1)

      let fetchStateWithDc1 = fetchState->FetchState.registerDynamicContracts([dc1->dcToItem])

      t.expect(
        (
          fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count,
          fetchStateWithDc1.optimizedPartitions->FetchState.OptimizedPartitions.count,
        ),
        ~message="Should have created a new partition for the dc",
      ).toEqual((1, 2))

      t.expect(
        fetchStateWithDc1->FetchState.registerDynamicContracts([dc1->dcToItem]),
        ~message="Calling it with the same dc for the second time shouldn't change anything",
      ).toBe(fetchStateWithDc1)

      // This is an edge case we currently don't cover
      // But show a warning in the logs
      t.expect(
        fetchStateWithDc1->FetchState.registerDynamicContracts([
          makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress1)->dcToItem,
        ]),
        ~message=`BROKEN: Calling it with the same dc
          but earlier block number should create a new short lived partition
          for the specific contract from block 0 to 1. And update the dc in db`,
      ).toBe(fetchStateWithDc1)
    },
  )

  it("Should split dcs into multiple partitions if they exceed maxAddrInPartition", t => {
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

    t.expect(
      updatedFetchState.optimizedPartitions.entities->Dict.valuesToArray,
      ~message=`Should add 2 new partitions + optimize the original partition to merge without blocking`,
    ).toEqual([
      {
        ...fetchState.optimizedPartitions.entities->Dict.getUnsafe("0"),
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
        addressesByContractName: Dict.fromArray([
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
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress4, mockAddress0])]),
        mergeBlock: None,
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        prevQueryRange: 0,
        prevPrevQueryRange: 0,
        latestBlockRangeUpdateBlock: 0,
      },
    ])

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

    t.expect(
      updatedFetchState.optimizedPartitions.entities->Dict.valuesToArray,
      ~message=`Should add 2 new partitions
+ optimize the original partition to merge without blocking
+ dynamic contracts don't share partitions`,
    ).toEqual([
      {
        ...fetchState.optimizedPartitions.entities->Dict.getUnsafe("0"),
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
        addressesByContractName: Dict.fromArray([("NftFactory", [mockAddress1, mockAddress4])]),
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
        addressesByContractName: Dict.fromArray([
          ("Gravatar", [mockAddress2, mockAddress3, mockAddress0]),
        ]),
        mergeBlock: None,
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        prevQueryRange: 0,
        prevPrevQueryRange: 0,
        latestBlockRangeUpdateBlock: 0,
      },
    ])
  })

  it(
    "Dcs for contract with event filtering using addresses shouldn't be grouped into a single partition to prevent overfetching",
    // This is because we can't filter events before dc registration block number for this case
    t => {
      let fetchState = FetchState.make(
        ~eventConfigs=[
          baseEventConfig,
          (MockIndexer.evmEventConfig(~id="0", ~contractName="NftFactory") :> Internal.eventConfig),
          // An event from another contract
          // which has an event filter by addresses
          (MockIndexer.evmEventConfig(
            ~id="0",
            ~contractName="SimpleNft",
            ~isWildcard=false,
            ~filterByAddresses=true,
          ) :> Internal.eventConfig),
        ],
        ~addresses=[makeConfigContract("Gravatar", mockAddress0)],
        ~startBlock=10,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      t.expect(fetchState.contractConfigs).toEqual(
        Dict.fromArray([
          ("Gravatar", {FetchState.filterByAddresses: false, startBlock: None}),
          ("NftFactory", {FetchState.filterByAddresses: false, startBlock: None}),
          ("SimpleNft", {FetchState.filterByAddresses: true, startBlock: None}),
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

      t.expect(
        updatedFetchState.optimizedPartitions.entities->Dict.valuesToArray,
        ~message=`All dcs without filterByAddresses should use the original logic and be grouped into a single partition,
          while dcs with filterByAddress should be split into partition per every registration block`,
      ).toEqual([
        {
          ...fetchState.optimizedPartitions.entities->Dict.getUnsafe("0"),
          // Immediately merge to the original partition
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0, mockAddress1])]),
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
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress1])]),
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
          addressesByContractName: Dict.fromArray([("SimpleNft", [mockAddress2, mockAddress3])]),
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
          addressesByContractName: Dict.fromArray([
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
          addressesByContractName: Dict.fromArray([("NftFactory", [mockAddress5])]),
          mergeBlock: None,
          dynamicContract: Some("NftFactory"),
          mutPendingQueries: [],
          prevQueryRange: 0,
          prevPrevQueryRange: 0,
          latestBlockRangeUpdateBlock: 0,
        },
      ])
    },
  )

  it("Choose the earliest dc from the batch when there are two with the same address", t => {
    let fetchState = makeInitial()

    let dc1 = makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress1)
    let dc2 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress1)
    let dcItem1 = dc1->dcToItem
    let dcItem2 = dc2->dcToItem

    let updatedFetchState = fetchState->FetchState.registerDynamicContracts([dcItem2, dcItem1])

    t.expect(
      (dcItem1->Internal.getItemDcs, dcItem2->Internal.getItemDcs),
      ~message=`Should choose the earliest dc from the batch
  And remove the dc from the later one, so they are not duplicated in the db`,
    ).toEqual((Some([]), Some([dc2])))
    t.expect(
      updatedFetchState.indexingAddresses,
      ~message="Should choose the earliest dc from the batch",
    ).toEqual(makeIndexingContractsWithDynamics([dc2], ~static=[mockAddress0]))
    t.expect(
      updatedFetchState.optimizedPartitions.entities->Dict.valuesToArray,
      ~message="Adds dc and optimizes partitions",
    ).toEqual([
      {
        ...fetchState.optimizedPartitions.entities->Dict.getUnsafe("0"),
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
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
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress1, mockAddress0])]),
        mergeBlock: None,
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        prevQueryRange: 0,
        prevPrevQueryRange: 0,
        latestBlockRangeUpdateBlock: 0,
      },
    ])
  })

  it("All dcs are grouped in a single partition, but don't merged with an existing one", t => {
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
    t.expect(updatedFetchState.indexingAddresses->Utils.Dict.size).toBe(4)
    t.expect(updatedFetchState.optimizedPartitions.entities->Dict.valuesToArray).toEqual([
      {
        ...fetchState.optimizedPartitions.entities->Dict.getUnsafe("0"),
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
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
        addressesByContractName: Dict.fromArray([
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
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        prevQueryRange: 0,
        prevPrevQueryRange: 0,
        latestBlockRangeUpdateBlock: 0,
      },
    ])
  })

  it(
    "Creates FetchState with wildcard and normal events. Addresses not belonging to event configs should be skipped (pre-registration case)",
    t => {
      let wildcard1 = (MockIndexer.evmEventConfig(
        ~id="wildcard1",
        ~contractName="Gravatar",
        ~isWildcard=true,
      ) :> Internal.eventConfig)
      let wildcard2 = (MockIndexer.evmEventConfig(
        ~id="wildcard2",
        ~contractName="Gravatar",
        ~isWildcard=true,
      ) :> Internal.eventConfig)
      let normal1 = (MockIndexer.evmEventConfig(
        ~id="normal1",
        ~contractName="NftFactory",
      ) :> Internal.eventConfig)
      let normal2 = (MockIndexer.evmEventConfig(
        ~id="normal2",
        ~contractName="NftFactory",
        ~isWildcard=true,
        ~dependsOnAddresses=true,
      ) :> Internal.eventConfig)

      let fetchState = FetchState.make(
        ~eventConfigs=[wildcard1, wildcard2, normal1, normal2],
        ~addresses=[
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

      t.expect(
        fetchState,
        ~message=`The static addresses for the Gravatar contract should be skipped, since they don't have non-wildcard event configs`,
      ).toEqual({
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
              addressesByContractName: Dict.make(),
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
              addressesByContractName: Dict.fromArray([
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
        endBlock: None,
        latestOnBlockBlockNumber: -1,
        targetBufferSize,
        buffer: [],
        normalSelection: fetchState.normalSelection,
        chainId,
        indexingAddresses: fetchState.indexingAddresses,
        contractConfigs: fetchState.contractConfigs,
        blockLag: 0,
        onBlockConfigs: [],
        knownHeight,
        firstEventBlock: None,
      })
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
            addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
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
      indexingAddresses: Dict.fromArray([
        (
          mockAddress0->Address.toString,
          ({
            contractName: "Gravatar",
            address: mockAddress0,
            registrationBlock: -1,
            effectiveStartBlock: 0,
          }: FetchState.indexingAddress),
        ),
      ]),
      contractConfigs: makeInitial().contractConfigs,
      onBlockConfigs: [],
      knownHeight,
      firstEventBlock: None,
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
            addressesByContractName: Dict.fromArray([
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
            addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
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
      endBlock: None,
      normalSelection,
      chainId,
      indexingAddresses: makeIndexingContractsWithDynamics([dc3, dc2, dc1], ~static=[mockAddress0]),
      contractConfigs: makeInitial().contractConfigs,
      blockLag: 0,
      onBlockConfigs: [],
      knownHeight,
      firstEventBlock: None,
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

  it("Emulate first indexer queries with a static event", t => {
    let fetchState = makeInitial()

    t.expect(fetchState->getNextQuery(~knownHeight=0)).toEqual(WaitingForNewBlock)

    let nextQuery = fetchState->getNextQuery

    t.expect(nextQuery).toEqual(
      Ready([
        {
          partitionId: "0",
          fromBlock: 0,
          toBlock: None,
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
          indexingAddresses: fetchState.indexingAddresses,
          isChunk: false,
        },
      ]),
    )

    let query = switch nextQuery {
    | Ready([q]) => q
    | _ => JsError.throwWithMessage("Failed to extract query")
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])

    t.expect(
      (fetchState.optimizedPartitions.entities->Dict.getUnsafe("0")).mutPendingQueries,
      ~message="The startFetchingQueries should mutate mutPendingQueries",
    ).toEqual([
      {
        fromBlock: 0,
        toBlock: None,
        isChunk: false,
        fetchedBlock: None,
      },
    ])

    let repeatedNextQuery = fetchState->getNextQuery

    t.expect(repeatedNextQuery, ~message="Shouldn't double fetch the same partition").toEqual(
      NothingToQuery,
    )

    let updatedFetchState = fetchState->FetchState.handleQueryResult(
      ~query,
      ~latestFetchedBlock={
        blockNumber: 10,
        blockTimestamp: 10,
      },
      ~newItems=[mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
    )

    t.expect(updatedFetchState, ~message="Should be equal to the initial state").toEqual(
      makeAfterFirstStaticAddressesQuery(),
    )

    t.expect(updatedFetchState->getNextQuery, ~message="Should wait for new block").toEqual(
      WaitingForNewBlock,
    )
    t.expect(updatedFetchState->getNextQuery(~concurrencyLimit=0)).toEqual(ReachedMaxConcurrency)
    t.expect(
      updatedFetchState->getNextQuery(~endBlock=Some(11)),
      ~message=`Should wait for new block
      when block height didn't reach the end block`,
    ).toEqual(WaitingForNewBlock)
    t.expect(
      updatedFetchState->getNextQuery(~endBlock=Some(10)),
      ~message=`Shouldn't wait for new block
      when block height reached the end block`,
    ).toEqual(NothingToQuery)
    t.expect(
      updatedFetchState->getNextQuery(~endBlock=Some(9)),
      ~message=`Shouldn't wait for new block
      when block height exceeded the end block`,
    ).toEqual(NothingToQuery)
    t.expect(
      updatedFetchState->getNextQuery(~targetBufferSize=2),
      ~message=`Should wait for new block even if partitions have nothing to query`,
    ).toEqual(WaitingForNewBlock)
    t.expect(
      updatedFetchState->getNextQuery(~targetBufferSize=2, ~knownHeight=11),
      ~message=`Should do nothing if the case above is not waiting for new block`,
    ).toEqual(NothingToQuery)

    updatedFetchState->FetchState.startFetchingQueries(~queries=[query])
    t.expect(
      updatedFetchState->getNextQuery,
      ~message=`Test that even if all partitions reached the current block height,
      we won't wait for new block while even one partition is fetching.
      It might return an updated knownHeight in response and we won't need to poll for new block`,
    ).toEqual(NothingToQuery)
  })

  it("Emulate first indexer queries with block lag configured", t => {
    let fetchState = makeInitial(~blockLag=2)

    t.expect(fetchState->getNextQuery(~knownHeight=0)).toEqual(WaitingForNewBlock)

    t.expect(
      fetchState->getNextQuery(~knownHeight=1),
      ~message="Should wait for new block when current block height - block lag is less than 0",
    ).toEqual(WaitingForNewBlock)

    let nextQuery = fetchState->getNextQuery(~endBlock=Some(8), ~knownHeight=10)
    t.expect(nextQuery, ~message="No block lag when we are close to the end block").toEqual(
      Ready([
        {
          partitionId: "0",
          toBlock: Some(8),
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
          indexingAddresses: fetchState.indexingAddresses,
          isChunk: false,
        },
      ]),
    )

    let nextQuery = fetchState->getNextQuery(~endBlock=Some(10), ~knownHeight=10)
    t.expect(
      nextQuery,
      ~message="Should apply block lag even when there's an upcoming end block",
    ).toEqual(
      Ready([
        {
          partitionId: "0",
          toBlock: Some(8),
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
          indexingAddresses: fetchState.indexingAddresses,
          isChunk: false,
        },
      ]),
    )

    let query = switch nextQuery {
    | Ready([q]) => q
    | _ => JsError.throwWithMessage("Failed to extract query")
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])

    let repeatedNextQuery = fetchState->getNextQuery
    t.expect(repeatedNextQuery, ~message="Shouldn't double fetch the same partition").toEqual(
      NothingToQuery,
    )

    let updatedFetchState = fetchState->FetchState.handleQueryResult(
      ~query,
      ~latestFetchedBlock={
        blockNumber: 8,
        blockTimestamp: 8,
      },
      ~newItems=[mockEvent(~blockNumber=2), mockEvent(~blockNumber=1)],
    )

    t.expect(updatedFetchState->getNextQuery).toEqual(WaitingForNewBlock)
  })

  it("Emulate dynamic contract registration", t => {
    // Continue with the state from previous test
    let fetchState = makeAfterFirstStaticAddressesQuery()

    let fetchStateWithDcs =
      fetchState
      ->FetchState.registerDynamicContracts([dc2->dcToItem, dc1->dcToItem])
      ->FetchState.registerDynamicContracts([dc3->dcToItem])

    t.expect(
      fetchStateWithDcs.optimizedPartitions.entities->Dict.valuesToArray,
      ~message="Assert internal representation of the fetch state",
    ).toEqual([
      {
        ...fetchState.optimizedPartitions.entities->Dict.getUnsafe("0"),
        dynamicContract: Some("Gravatar"),
        addressesByContractName: Dict.fromArray([
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
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress1, mockAddress2])]),
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
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
        mergeBlock: None,
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        prevQueryRange: 0,
        prevPrevQueryRange: 0,
        latestBlockRangeUpdateBlock: 0,
      },
    ])

    t.expect(
      fetchStateWithDcs->getNextQuery,
      ~message="Merge DC partition into the later one + query other partitions in parallel",
    ).toEqual(
      Ready([
        {
          partitionId: "1",
          toBlock: Some(10),
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress1, mockAddress2])]),
          fromBlock: 1,
          indexingAddresses: fetchStateWithDcs.indexingAddresses,
        },
        {
          partitionId: "2",
          fromBlock: 2,
          toBlock: None,
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
          indexingAddresses: fetchStateWithDcs.indexingAddresses,
        },
        // Partition 0 is not included since it's below knownHeight
      ]),
    )

    let queries = switch fetchStateWithDcs->getNextQuery {
    | Ready(queries) => queries
    | _ =>
      JsError.throwWithMessage("Failed to extract query. The getNextQuery should be idempotent")
    }

    fetchStateWithDcs->FetchState.startFetchingQueries(~queries)
    t.expect(
      fetchStateWithDcs->getNextQuery,
      ~message="All partitions below known height are already quering and can't be chunked",
    ).toEqual(NothingToQuery)

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

    t.expect(updatedFetchState, ~message="Should be equal to intermidiate state").toEqual(
      makeIntermidiateDcMerge(),
    )

    let expectedPartition2Query: FetchState.query = {
      partitionId: "2",
      fromBlock: 3,
      toBlock: None,
      selection: fetchState.normalSelection,
      addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
      indexingAddresses: fetchStateWithDcs.indexingAddresses,
      isChunk: false,
    }
    let expectedPartition0Query: FetchState.query = {
      partitionId: "0",
      toBlock: None,
      selection: fetchState.normalSelection,
      addressesByContractName: Dict.fromArray([
        ("Gravatar", [mockAddress0, mockAddress1, mockAddress2]),
      ]),
      fromBlock: 11,
      indexingAddresses: fetchStateWithDcs.indexingAddresses,
      isChunk: false,
    }

    t.expect(
      updatedFetchState->getNextQuery(~knownHeight=11),
      ~message=`Since the partition "0" reached the maxAddrNumber,
      there's no point to continue merging partitions,
      so we have two queries concurrently`,
    ).toEqual(Ready([expectedPartition2Query, expectedPartition0Query]))
    t.expect(
      updatedFetchState->getNextQuery(~concurrencyLimit=1, ~knownHeight=11),
      ~message=`Should be the query with smaller fromBlock`,
    ).toEqual(Ready([expectedPartition2Query]))
    t.expect(
      updatedFetchState->getNextQuery(~knownHeight=10),
      ~message=`Even if a single partition reached block height,
      we finish fetching other partitions until waiting for the new block first`,
    ).toEqual(Ready([expectedPartition2Query]))

    updatedFetchState->FetchState.startFetchingQueries(~queries=[expectedPartition2Query])
    t.expect(
      updatedFetchState->getNextQuery(~knownHeight=11),
      ~message=`Should skip fetching queries`,
    ).toEqual(Ready([expectedPartition0Query]))
  })

  it("Emulate partition merging cases", t => {
    let originalFetchState = makeIntermidiateDcMerge()
    let originalFetchState = {
      ...originalFetchState,
      optimizedPartitions: {
        ...originalFetchState.optimizedPartitions,
        maxAddrInPartition: 4,
      },
    }
    t.expect(
      originalFetchState->getNextQuery(~knownHeight=11),
      ~message="Until we optimize partitions - on handle query, we don't need to merge partitions",
    ).toEqual(
      Ready([
        {
          partitionId: "2",
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
          fromBlock: 3,
          indexingAddresses: originalFetchState.indexingAddresses,
          isChunk: false,
        },
        {
          FetchState.partitionId: "0",
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addressesByContractName: Dict.fromArray([
            ("Gravatar", [mockAddress0, mockAddress1, mockAddress2]),
          ]),
          fromBlock: 11,
          indexingAddresses: originalFetchState.indexingAddresses,
          isChunk: false,
        },
      ]),
    )

    // Continue with the state from previous test
    // But increase the maxAddrInPartition up to 4
    let fetchState = makeIntermidiateDcMerge(~maxAddrInPartition=4, ~knownHeight=11)
    t.expect(
      fetchState->getNextQuery,
      ~message="Although, if we pass it through partition optimization, it should merge partitions now",
    ).toEqual(
      Ready([
        {
          partitionId: "2",
          toBlock: Some(10),
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
          fromBlock: 3,
          indexingAddresses: fetchState.indexingAddresses,
          isChunk: false,
        },
        {
          FetchState.partitionId: "0",
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addressesByContractName: Dict.fromArray([
            ("Gravatar", [mockAddress0, mockAddress1, mockAddress2, mockAddress3]),
          ]),
          fromBlock: 11,
          indexingAddresses: originalFetchState.indexingAddresses,
          isChunk: false,
        },
      ]),
    )

    let queries = switch fetchState->getNextQuery {
    | Ready(queries) => queries
    | _ =>
      JsError.throwWithMessage("Failed to extract query. The getNextQuery should be idempotent")
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

    t.expect(
      (
        fetchStateWithResponse1->FetchState.bufferBlock,
        fetchStateWithResponse1.optimizedPartitions.idsInAscOrder,
        fetchStateWithResponse1.buffer->Array.length,
      ),
      ~message="The buffer block should be the latest fetched block",
    ).toEqual((
      {
        blockNumber: 9,
        blockTimestamp: 9,
      },
      ["2", "0"],
      4,
    ))

    t.expect(
      fetchStateWithResponse1->getNextQuery(~targetBufferSize=1),
      ~message=`Even if we have a partition with toBlock which wants to merge
      if it's outside of the targetBufferSize limit, we should return NothingToQuery`,
    ).toEqual(NothingToQuery)

    let queries = switch fetchStateWithResponse1->getNextQuery {
    | Ready(queries) => queries
    | _ =>
      JsError.throwWithMessage("Failed to extract query. The getNextQuery should be idempotent")
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

    t.expect(
      fetchStateWithResponse2,
      ~message="Partition 2 should come to mergeBlock and be removed",
    ).toEqual({
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
            addressesByContractName: Dict.fromArray([
              ("Gravatar", [mockAddress0, mockAddress1, mockAddress2, mockAddress3]),
            ]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=fetchStateWithResponse1.optimizedPartitions.nextPartitionIndex,
        ~maxAddrInPartition=fetchStateWithResponse1.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=fetchStateWithResponse1.optimizedPartitions.dynamicContracts,
      ),
    })
  })

  it("Wildcard partition never merges to another one", t => {
    let wildcard = (MockIndexer.evmEventConfig(
      ~id="wildcard",
      ~contractName="ContractA",
      ~isWildcard=true,
    ) :> Internal.eventConfig)
    let fetchState =
      FetchState.make(
        ~eventConfigs=[
          (MockIndexer.evmEventConfig(~id="0", ~contractName="Gravatar") :> Internal.eventConfig),
          (MockIndexer.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
          wildcard,
        ],
        ~addresses=[makeConfigContract("ContractA", mockAddress1)],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=2,
        ~targetBufferSize=10,
        ~chainId,
        ~knownHeight,
      )->FetchState.registerDynamicContracts([
        makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)->dcToItem,
      ])

    t.expect(fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count).toEqual(3)

    let nextQuery = {...fetchState, knownHeight: 10}->FetchState.getNextQuery(~concurrencyLimit=10)

    t.expect(
      nextQuery,
      ~message=`Wildcard partition "0" is untouched.
      Partitions "1" and "2" split in optimized way for further dynamic contract registrations.
      All queries performed in parallel without locking.`,
    ).toEqual(
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
          addressesByContractName: Dict.make(),
          indexingAddresses: fetchState.indexingAddresses,
        },
        {
          partitionId: "1",
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("ContractA", [mockAddress1])]),
          indexingAddresses: fetchState.indexingAddresses,
        },
        {
          partitionId: "2",
          fromBlock: 2,
          toBlock: None,
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress2])]),
          indexingAddresses: fetchState.indexingAddresses,
        },
      ]),
    )
  })

  it("Correctly rollbacks fetch state", t => {
    let fetchState = makeIntermidiateDcMerge()

    // Rollback to block 2: both DCs survive (regBlock <= 2)
    // Partition "0" (lfb=10 > 2) -> DELETED, addresses recreated as partition "1"
    // Partition "2" (lfb=2 <= 2) -> KEPT as partition "0" (IDs reset)
    let fetchStateAfterRollback1 = fetchState->FetchState.rollback(~targetBlockNumber=2)
    t.expect(
      fetchStateAfterRollback1,
      ~message=`Rollbacks partitions: kept "0", recreated "1" from deleted`,
    ).toEqual({
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
            addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
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
            addressesByContractName: Dict.fromArray([
              ("Gravatar", [mockAddress0, mockAddress1, mockAddress2]),
            ]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=2,
        ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
      ),
    })

    // Rollback to block 1: dc2 and dc3 removed (regBlock=2 > 1)
    // Both partitions deleted (lfb > 1), surviving addresses [addr0, addr1] recreated
    let fetchStateAfterRollback2 = fetchState->FetchState.rollback(~targetBlockNumber=1)
    t.expect(
      fetchStateAfterRollback2,
      ~message=`Both partitions deleted, surviving addresses recreated as partition "0"`,
    ).toEqual({
      ...fetchState,
      indexingAddresses: makeIndexingContractsWithDynamics([dc1], ~static=[mockAddress0]),
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
            addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0, mockAddress1])]),
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
    })

    // Rollback to block -1: all DCs removed, only static addr0 survives
    let fetchStateAfterRollback3 = fetchState->FetchState.rollback(~targetBlockNumber=-1)
    t.expect(
      fetchStateAfterRollback3,
      ~message=`All DCs removed, only static addr0 recreated as partition "0"`,
    ).toEqual({
      ...fetchState,
      indexingAddresses: makeIndexingContractsWithDynamics([], ~static=[mockAddress0]),
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
            addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=1,
        ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
      ),
      buffer: [],
    })
  })

  it("Keeps wildcard partition on rollback", t => {
    let wildcardEventConfigs = [
      (MockIndexer.evmEventConfig(
        ~id="wildcard",
        ~contractName="ContractA",
        ~isWildcard=true,
      ) :> Internal.eventConfig),
    ]
    let eventConfigs = [
      ...wildcardEventConfigs,
      (MockIndexer.evmEventConfig(~id="0", ~contractName="Gravatar") :> Internal.eventConfig),
    ]
    let fetchState =
      FetchState.make(
        ~eventConfigs,
        ~addresses=[],
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
          addressesByContractName: Dict.make(),
          fromBlock: 0,
          indexingAddresses: fetchState.indexingAddresses,
          isChunk: false,
        },
      ],
    )

    t.expect(
      fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count,
      ~message=`Should have 2 partitions before rollback`,
    ).toEqual(2)

    // resetPendingQueries must be called before rollback (removes in-flight queries)
    let fetchStateReset = fetchState->FetchState.resetPendingQueries
    let fetchStateAfterRollback = fetchStateReset->FetchState.rollback(~targetBlockNumber=1)

    t.expect(
      fetchStateAfterRollback,
      ~message=`Should keep Wildcard partition even if it's empty`,
    ).toEqual({
      ...fetchState,
      indexingAddresses: Dict.make(),
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
            addressesByContractName: Dict.make(),
            mergeBlock: None,
          },
        ],
        // IDs reset on rollback
        ~nextPartitionIndex=1,
        ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
      ),
      buffer: [],
    })
  })
})

describe("FetchState unit tests for specific cases", () => {
  it("Should merge events in correct order on merging", t => {
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
            addressesByContractName: Dict.make(),
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
            addressesByContractName: Dict.make(),
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
      addressesByContractName: Dict.make(),
      indexingAddresses: fetchState.indexingAddresses,
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

    t.expect(updatedFetchState.buffer, ~message="Should merge events in correct order").toEqual([
      mockEvent(~blockNumber=1),
      mockEvent(~blockNumber=2),
      mockEvent(~blockNumber=3),
      mockEvent(~blockNumber=4),
      mockEvent(~blockNumber=4, ~logIndex=1),
      mockEvent(~blockNumber=4, ~logIndex=1),
      mockEvent(~blockNumber=4, ~logIndex=2),
    ])
  })

  it("Sorts newItems when source returns them unsorted", t => {
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
      addressesByContractName: Dict.make(),
      indexingAddresses: fetchState.indexingAddresses,
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock=getBlockData(~blockNumber=10),
        ~newItems=unsorted,
      )

    t.expect(
      updatedFetchState.buffer,
      ~message="Queue must be sorted DESC by (blockNumber, logIndex) regardless of input order",
    ).toEqual([
      mockEvent(~blockNumber=5, ~logIndex=0),
      mockEvent(~blockNumber=5, ~logIndex=1),
      mockEvent(~blockNumber=6, ~logIndex=0),
      mockEvent(~blockNumber=6, ~logIndex=2),
    ])
  })

  it("Shouldn't wait for new block until all partitions reached the head", t => {
    let wildcard = (MockIndexer.evmEventConfig(
      ~id="wildcard",
      ~contractName="ContractA",
      ~isWildcard=true,
    ) :> Internal.eventConfig)
    // FetchState with 2 partitions,
    // one of them reached the head
    // another reached max queue size
    let fetchState = FetchState.make(
      ~eventConfigs=[
        (MockIndexer.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
        wildcard,
      ],
      ~addresses=[makeConfigContract("ContractA", mockAddress0)],
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
      addressesByContractName: Dict.make(),
      indexingAddresses: fetchState.indexingAddresses,
    }
    let query1: FetchState.query = {
      partitionId: "1",
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Dict.make(),
      indexingAddresses: fetchState.indexingAddresses,
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

    t.expect(
      {...fetchState, knownHeight: 2}->FetchState.getNextQuery(~concurrencyLimit=10),
      ~message=`Should be possible to query wildcard partition,
      if it didn't reach max queue size limit`,
    ).toEqual(
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
          addressesByContractName: Dict.make(),
          indexingAddresses: fetchState.indexingAddresses,
        },
      ]),
    )
    t.expect(
      {
        ...fetchState,
        targetBufferSize: 2,
        knownHeight: 2,
      }->FetchState.getNextQuery(~concurrencyLimit=10),
      ~message=`Should wait until queue is processed, to continue fetching.
      Don't wait for new block, until all partitions reached the head`,
    ).toEqual(NothingToQuery)
  })

  it("Allows to get event one block earlier than the dc registring event", t => {
    let fetchState = makeInitial(~knownHeight=10)

    t.expect(fetchState->getEarliestEvent).toEqual(
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
      addressesByContractName: Dict.make(),
      indexingAddresses: fetchState.indexingAddresses,
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

    t.expect(fetchStateWithEvents->getEarliestEvent->getItem).toEqual(
      Some(mockEvent(~blockNumber=2, ~logIndex=1)),
    )

    let fetchStateWithDc =
      fetchStateWithEvents->FetchState.registerDynamicContracts([
        makeDynContractRegistration(
          ~contractAddress=mockAddress1,
          ~blockNumber=registeringBlockNumber,
        )->dcToItem,
      ])

    t.expect(
      fetchStateWithDc->getEarliestEvent->getItem,
      ~message=`Should allow to get event before the dc registration`,
    ).toEqual(Some(mockEvent(~blockNumber=2, ~logIndex=1)))
  })

  it("Returns NoItem when there is an empty partition at block 0", t => {
    let fetchState = FetchState.make(
      ~eventConfigs=[
        (MockIndexer.evmEventConfig(~id="0", ~contractName="ContractA") :> Internal.eventConfig),
      ],
      ~addresses=[
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

    t.expect(fetchState->getEarliestEvent).toEqual(
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
      addressesByContractName: Dict.make(),
      indexingAddresses: fetchState.indexingAddresses,
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~newItems=[mockEvent(~blockNumber=0, ~logIndex=1)],
        ~latestFetchedBlock=getBlockData(~blockNumber=1),
      )

    t.expect(updatedFetchState->getEarliestEvent).toEqual(
      NoItem({
        latestFetchedBlock: {
          blockNumber: -1,
          blockTimestamp: 0,
        },
      }),
    )
  })

  it("Get earliest event", t => {
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
            addressesByContractName: Dict.make(),
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
            addressesByContractName: Dict.make(),
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

    t.expect(fetchState->getEarliestEvent->getItem).toEqual(
      Some(mockEvent(~blockNumber=2, ~logIndex=1)),
    )

    t.expect(
      fetchState
      ->FetchState.registerDynamicContracts([
        makeDynContractRegistration(~contractAddress=mockAddress1, ~blockNumber=2)->dcToItem,
      ])
      ->getEarliestEvent,
      ~message=`Accounts for registered dynamic contracts`,
    ).toEqual(
      NoItem({
        latestFetchedBlock: {
          blockNumber: 1,
          blockTimestamp: 0,
        },
      }),
    )
  })

  it("isActively indexing", t => {
    t.expect(
      makeInitial()->FetchState.isActivelyIndexing,
      ~message=`Should be actively indexing with initial state`,
    ).toEqual(true)
    t.expect(
      {...makeInitial(), endBlock: Some(10)}->FetchState.isActivelyIndexing,
      ~message=`Should be actively indexing with initial state, even if there's an endBlock`,
    ).toEqual(true)
    t.expect(
      {...makeInitial(), endBlock: Some(0)}->FetchState.isActivelyIndexing,
      ~message=`Should be active if endBlock is equal to the startBlock`,
    ).toEqual(true)
    t.expect(
      {...makeInitial(~startBlock=10), endBlock: Some(9)}->FetchState.isActivelyIndexing,
      ~message=`Shouldn't be active if endBlock is less than the startBlock`,
    ).toEqual(false)
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
      addressesByContractName: Dict.make(),
      indexingAddresses: fetchState.indexingAddresses,
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    t.expect(
      fetchState
      ->FetchState.handleQueryResult(
        ~query,
        ~newItems=[mockEvent(~blockNumber=0)],
        ~latestFetchedBlock={blockNumber: -1, blockTimestamp: 0},
      )
      ->FetchState.isActivelyIndexing,
      ~message=`Although, with items in the queue it should be considered active`,
    ).toEqual(true)
  })

  it(
    "Adding dc between two partitions while query is mid flight does no result in early merged partitinons",
    t => {
      let knownHeight = 600

      let fetchState = FetchState.make(
        ~eventConfigs=[baseEventConfig],
        ~addresses=[makeConfigContract("Gravatar", mockAddress1)],
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
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress1])]),
        indexingAddresses: fetchState.indexingAddresses,
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
      | _ => JsError.throwWithMessage("Expected Ready queries")
      }

      t.expect(queries).toEqual([
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
      ])

      let queryA = queries->Array.getUnsafe(0)

      // Emulate that we started fetching the first query
      fetchStateWithDcA->FetchState.startFetchingQueries(~queries=[queryA])

      //Next registration happens at block 200, between the first register and the upperbound of it's query
      let dc3 = makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=200)
      let fetchStateWithDcB =
        fetchStateWithDcA->FetchState.registerDynamicContracts([dc3->dcToItem])

      let queries = switch fetchStateWithDcB->FetchState.getNextQuery(~concurrencyLimit=10) {
      | Ready(queries) => queries
      | _ => JsError.throwWithMessage("Expected Ready queries")
      }
      let partition2Query = {
        ...queries->Array.getUnsafe(0),
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
        indexingAddresses: fetchStateWithDcB.indexingAddresses,
        partitionId: "2",
        toBlock: None, // Didn't merge because reached max addresses in partition
        fromBlock: 200,
      }
      t.expect(
        fetchStateWithDcB->FetchState.getNextQuery(~concurrencyLimit=10),
        ~message=`Create a new partition for the newly registered contract`,
      ).toEqual(Ready([partition2Query, queries->Array.getUnsafe(1)]))

      //Response with updated fetch state
      let fetchStateWithBothDcsAndQueryAResponse =
        fetchStateWithDcB->FetchState.handleQueryResult(
          ~query=queryA,
          ~latestFetchedBlock=getBlockData(~blockNumber=400),
          ~newItems=[],
        )

      t.expect(
        fetchStateWithBothDcsAndQueryAResponse->FetchState.getNextQuery(~concurrencyLimit=10),
        ~message=`We don't merge partition 2 to partition 1, since it already has end block`,
      ).toEqual(
        Ready([
          partition2Query,
          {
            ...queryA,
            indexingAddresses: fetchStateWithBothDcsAndQueryAResponse.indexingAddresses,
            partitionId: "1",
            toBlock: Some(500),
            fromBlock: 401,
          },
          queries->Array.getUnsafe(1),
        ]),
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
      addressesByContractName: Dict.make(),
      fromBlock: 0,
      indexingAddresses: fetchState.indexingAddresses,
    }
  }

  // Helper: create a fetch state with desired latestFetchedBlock and queue items via public API
  let makeFsWith = (~latestBlock: int, ~queueBlocks: array<int>): FetchState.t => {
    let fs0 = makeInitial(~knownHeight=10)
    let query = mkQuery(fs0)
    fs0->FetchState.startFetchingQueries(~queries=[query])
    let fs =
      fs0->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock={blockNumber: latestBlock, blockTimestamp: latestBlock},
        ~newItems=queueBlocks->Array.map(b => mockEvent(~blockNumber=b)),
      )
    {...fs, firstEventBlock: Some(0)}
  }

  it("Sorts by progress percentage. Chains further behind have higher priority", t => {
    // Low progress: first item at block 1, knownHeight=10 → 10% progress
    let fsLow = makeFsWith(~latestBlock=3, ~queueBlocks=[1])
    // Mid progress: first item at block 5, knownHeight=10 → 50% progress
    let fsMid = makeFsWith(~latestBlock=7, ~queueBlocks=[5])
    // High progress: first item at block 8, knownHeight=10 → 80% progress
    let fsHigh = makeFsWith(~latestBlock=10, ~queueBlocks=[8])

    let prepared = FetchState.sortForUnorderedBatch([fsHigh, fsLow, fsMid], ~batchSizeTarget=3)

    t.expect(
      prepared->Array.map(fs => fs.buffer->Belt.Array.getUnsafe(0)->Internal.getItemBlockNumber),
    ).toEqual([1, 5, 8])
  })

  it("Prioritizes full batches over half full ones", t => {
    // Full batch (>= maxBatchSize items). Make it later (earliest item at block 7)
    let fsFullLater = makeFsWith(~latestBlock=10, ~queueBlocks=[9, 8, 7])
    // Half-full batch (1 item) but earlier earliest item (block 1)
    let fsHalfEarlier = makeFsWith(~latestBlock=10, ~queueBlocks=[1])

    let prepared = FetchState.sortForUnorderedBatch(
      [fsHalfEarlier, fsFullLater],
      ~batchSizeTarget=2,
    )

    t.expect(
      prepared->Array.map(fs => fs.buffer->Belt.Array.getUnsafe(0)->Internal.getItemBlockNumber),
    ).toEqual([7, 1])
  })

  it("Treats exactly-full batches as full", t => {
    // Exactly full (== maxBatchSize items)
    let fsExactFull = makeFsWith(~latestBlock=10, ~queueBlocks=[3, 2])
    // Half-full (1 item) but earlier earliest item
    let fsHalfEarlier = makeFsWith(~latestBlock=10, ~queueBlocks=[1])

    let prepared = FetchState.sortForUnorderedBatch(
      [fsHalfEarlier, fsExactFull],
      ~batchSizeTarget=2,
    )

    // Full batch should take priority regardless of earlier timestamp of half batch
    t.expect(
      prepared->Array.map(fs => fs.buffer->Belt.Array.getUnsafe(0)->Internal.getItemBlockNumber),
    ).toEqual([2, 1])
  })
})

describe("FetchState.isReadyToEnterReorgThreshold", () => {
  it("Returns false when we just started the indexer and it has knownHeight=0", t => {
    let fetchState = makeInitial()
    t.expect({...fetchState, knownHeight: 0}->FetchState.isReadyToEnterReorgThreshold).toBe(false)
  })

  it(
    "Returns false when we just started the indexer and it has knownHeight=0, while start block is more than 0 + reorg threshold",
    t => {
      let fetchState = makeInitial(~startBlock=6000)
      t.expect({...fetchState, knownHeight: 0}->FetchState.isReadyToEnterReorgThreshold).toBe(false)
    },
  )

  it("Returns true when endBlock is reached and queue is empty", t => {
    // latestFullyFetchedBlock = startBlock - 1 = 5, endBlock = 5
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~addresses=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          registrationBlock: -1,
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(true)
  })

  it("Returns false when endBlock not reached and below head - blockLag", t => {
    // latestFullyFetchedBlock = 49, endBlock = 100, head - lag = 50
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~addresses=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          registrationBlock: -1,
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(false)
  })

  it("Returns true when endBlock not reached but latest >= head - blockLag", t => {
    // latestFullyFetchedBlock = 49, head - lag = 49
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~addresses=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          registrationBlock: -1,
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(true)
  })

  it("Returns true when no endBlock and latest >= head - blockLag (boundary)", t => {
    // latestFullyFetchedBlock = 50, head - lag = 50
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~addresses=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          registrationBlock: -1,
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(true)
  })

  it("Returns false when no endBlock and latest < head - blockLag", t => {
    // latestFullyFetchedBlock = 49, head - lag = 50
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~addresses=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          registrationBlock: -1,
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(false)
  })

  it("Returns false when queue is not empty even if thresholds are met", t => {
    // EndBlock reached but queue has items
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~addresses=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          registrationBlock: -1,
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
    t.expect(fsWithQueue->FetchState.isReadyToEnterReorgThreshold).toBe(false)
  })

  it("Returns true when the queue is empty and threshold is more than current block height", t => {
    let fs = FetchState.make(
      ~eventConfigs=[baseEventConfig, baseEventConfig2],
      ~addresses=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          registrationBlock: -1,
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(true)
  })
})

describe("Dynamic contracts with start blocks", () => {
  it("Should respect dynamic contract startBlock even when registered earlier", t => {
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

    // The contract should be registered in indexingAddresses
    t.expect(
      updatedFetchState.indexingAddresses
      ->Dict.get(mockAddress1->Address.toString)
      ->Option.isSome,
      ~message="Dynamic contract should be registered in indexingAddresses",
    ).toBeTruthy()

    // Verify the startBlock is set correctly
    let registeredContract =
      updatedFetchState.indexingAddresses
      ->Dict.get(mockAddress1->Address.toString)
      ->Option.getOrThrow

    t.expect(
      registeredContract.effectiveStartBlock,
      ~message="Dynamic contract should have correct effectiveStartBlock",
    ).toBe(200)
  })

  it("Should handle dynamic contract registration with different startBlocks", t => {
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
      updatedFetchState.indexingAddresses
      ->Dict.get(mockAddress1->Address.toString)
      ->Option.getOrThrow

    let contract2Registered =
      updatedFetchState.indexingAddresses
      ->Dict.get(mockAddress2->Address.toString)
      ->Option.getOrThrow

    t.expect(contract1Registered.effectiveStartBlock, ~message="Contract1 should have startBlock=150").toBe(
      150,
    )

    t.expect(contract2Registered.effectiveStartBlock, ~message="Contract2 should have startBlock=300").toBe(
      300,
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
      addressesByContractName: Dict.make(),
      fromBlock: 0,
      indexingAddresses: fs0.indexingAddresses,
    }
    fs0->FetchState.startFetchingQueries(~queries=[query])
    fs0->FetchState.handleQueryResult(
      ~query,
      ~latestFetchedBlock={blockNumber: latestBlock, blockTimestamp: latestBlock},
      ~newItems=queueBlocks->Array.map(((b, l)) => mockEvent(~blockNumber=b, ~logIndex=l)),
    )
  }

  it("When queue is empty", t => {
    let fetchStateEmpty = makeFetchStateWith(~latestBlock=100, ~queueBlocks=[])

    t.expect(
      fetchStateEmpty->FetchState.getUnorderedMultichainProgressBlockNumberAt(~index=0),
      ~message="Should return latestFullyFetchedBlock.blockNumber when queue is empty",
    ).toBe(100)
  })

  it("When queue has a single item with log index 0", t => {
    let fetchStateSingleItem = makeFetchStateWith(~latestBlock=55, ~queueBlocks=[(55, 0)])

    t.expect(
      fetchStateSingleItem->FetchState.getUnorderedMultichainProgressBlockNumberAt(~index=0),
      ~message="Should return single queue item blockNumber - 1",
    ).toBe(54)
  })

  it("When queue has a single item with non 0 log index", t => {
    let fetchStateSingleItem = makeFetchStateWith(~latestBlock=55, ~queueBlocks=[(55, 5)])

    t.expect(
      fetchStateSingleItem->FetchState.getUnorderedMultichainProgressBlockNumberAt(~index=0),
      ~message="Should return single queue item blockNumber - 1",
    ).toBe(54)
  })

  it("When queue items are later than latest fetched block", t => {
    let fetchStateWithQueue = makeFetchStateWith(
      ~latestBlock=90,
      ~queueBlocks=[(105, 2), (103, 1), (101, 2)], // Last item has blockNumber=101
    )

    t.expect(
      fetchStateWithQueue->FetchState.getUnorderedMultichainProgressBlockNumberAt(~index=0),
      ~message="Should return latest fetched block number",
    ).toBe(90)
  })
})

describe("FetchState buffer overflow prevention", () => {
  it(
    "Should limit endBlock when maxQueryBlockNumber < knownHeight to prevent buffer overflow",
    t => {
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
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
        fromBlock: 0,
        indexingAddresses: fetchStateWithTwoPartitions.indexingAddresses,
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
        t.expect(
          q.toBlock,
          ~message="Should limit endBlock to maxQueryBlockNumber (15) when both endBlock and maxQueryBlockNumber are present",
        ).toBe(Some(15))
      | _ => JsError.throwWithMessage("Expected Ready query when buffer limiting is active")
      }

      // Test case 2: endBlock=None, maxQueryBlockNumber=15 -> Should use Some(15)
      let fetchStateNoEndBlock = {...fetchStateWithLargeQueue, endBlock: None, knownHeight: 30}
      switch fetchStateNoEndBlock->FetchState.getNextQuery(~concurrencyLimit=10) {
      | Ready([q]) =>
        t.expect(
          q.toBlock,
          ~message="Should set endBlock to maxQueryBlockNumber (15) when no endBlock was specified",
        ).toBe(Some(15))
      | _ => JsError.throwWithMessage("Expected Ready query when buffer limiting is active")
      }

      // Test case 3: Small queue, no buffer limiting -> Should use Head target
      let query3 = {
        FetchState.partitionId: "0",
        toBlock: None,
        isChunk: false,
        selection: fetchState.normalSelection,
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
        fromBlock: 0,
        indexingAddresses: fetchState.indexingAddresses,
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
        t.expect(q.toBlock, ~message="Should use None when buffer is not limited").toBe(None)
      | _ => JsError.throwWithMessage("Expected Ready query")
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
    t => {
      let onBlockConfig = makeOnBlockConfig(~interval=1, ~startBlock=Some(0))

      // Create FetchState with no event configs but with onBlockConfig
      let fetchState = FetchState.make(
        ~eventConfigs=[],
        ~addresses=[],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~targetBufferSize=10,
        ~chainId,
        ~knownHeight=0,
        ~onBlockConfigs=[onBlockConfig],
      )

      // Verify initial state
      t.expect(
        fetchState.optimizedPartitions.idsInAscOrder,
        ~message="Partitions should be empty when there are no event configs",
      ).toEqual([])
      t.expect(fetchState.buffer, ~message="Buffer should be empty initially").toEqual([])
      t.expect(fetchState.knownHeight, ~message="knownHeight should be 0 initially").toBe(0)
      t.expect(fetchState.onBlockConfigs, ~message="onBlockConfigs should be set").toEqual([
        onBlockConfig,
      ])

      // Test that getNextQuery returns WaitingForNewBlock when knownHeight is 0
      let nextQuery = fetchState->FetchState.getNextQuery(~concurrencyLimit=10)
      t.expect(
        nextQuery,
        ~message="Should return WaitingForNewBlock when knownHeight is 0",
      ).toEqual(WaitingForNewBlock)

      // Update known height to 20
      let updatedFetchState = fetchState->FetchState.updateKnownHeight(~knownHeight=20)

      // Verify buffer is now filled with block items
      t.expect(updatedFetchState.knownHeight, ~message="knownHeight should be updated to 20").toBe(
        20,
      )

      // Buffer should contain block items for blocks 0-9 (interval=1, startBlock=0, up to targetBufferSize limit)
      // Since latestFullyFetchedBlock is initially -1 and there are no partitions
      t.expect(
        updatedFetchState.latestOnBlockBlockNumber,
        ~message="latestOnBlockBlockNumber should be 10 since the onBlock config is interval=1 and startBlock=0",
      ).toBe(10)
      t.expect(updatedFetchState->FetchState.bufferBlockNumber).toBe(10)

      // Block items should be created from block 0 up to min(latestFullyFetchedBlock, targetBufferSize item)
      // With interval=1, startBlock=0, we expect blocks 0,1,2,3,4,5,6,7,8,9,10
      let blockNumbers =
        updatedFetchState.buffer->Array.map(item => item->Internal.getItemBlockNumber)

      t.expect(blockNumbers, ~message="Buffer should contain block items for blocks 0-10").toEqual([
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
      ])

      // Test that getNextQuery returns NothingToQuery (no partitions to query)
      let nextQuery2 = updatedFetchState->FetchState.getNextQuery(~concurrencyLimit=10)
      t.expect(
        nextQuery2,
        ~message="Should return NothingToQuery when there are no partitions to query",
      ).toEqual(NothingToQuery)
    },
  )
})

describe("Stale query response should not overwrite block range", () => {
  // The default configuration with ability to overwrite some values
  let getNextQuery = (fs, ~knownHeight=100000, ~concurrencyLimit=10) =>
    fs
    ->FetchState.updateKnownHeight(~knownHeight)
    ->FetchState.getNextQuery(~concurrencyLimit)

  it("Out-of-order parallel query responses should not degrade chunking heuristic", t => {
    let fetchState = makeInitial(~knownHeight=100000)

    // -- Query 1: uncapped query from block 0 --
    let q1 = switch fetchState->getNextQuery {
    | Ready([q]) => q
    | _ => JsError.throwWithMessage("Expected a single query")
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

    let p1 = fs1.optimizedPartitions.entities->Dict.getUnsafe("0")
    t.expect(p1.prevQueryRange, ~message="First query should set prevQueryRange=501").toBe(501)
    t.expect(
      p1.prevPrevQueryRange,
      ~message="First query prevPrevQueryRange should still be 0",
    ).toBe(0)
    t.expect(
      p1.latestBlockRangeUpdateBlock,
      ~message="latestBlockRangeUpdateBlock should be 500 after first query",
    ).toBe(500)

    // -- Query 2: uncapped query from block 501 --
    let q2 = switch fs1->getNextQuery {
    | Ready([q]) => q
    | _ => JsError.throwWithMessage("Expected a single query for second round")
    }
    fs1->FetchState.startFetchingQueries(~queries=[q2])

    // Response arrives at block 1000 (range = 500)
    // shouldUpdateBlockRange: None toBlock => 1000 < 99990 = true
    let fs2 =
      fs1->FetchState.handleQueryResult(
        ~query=q2,
        ~latestFetchedBlock={blockNumber: 1000, blockTimestamp: 1000 * 15},
        ~newItems=[],
      )

    let p2 = fs2.optimizedPartitions.entities->Dict.getUnsafe("0")
    t.expect(p2.prevQueryRange, ~message="Second query should set prevQueryRange=500").toBe(500)
    t.expect(
      p2.prevPrevQueryRange,
      ~message="Second query should shift prevPrevQueryRange=501",
    ).toBe(501)
    t.expect(p2.latestBlockRangeUpdateBlock).toBe(1000)

    // Now chunking is active: getMinHistoryRange = Some(min(500, 501)) = Some(500)
    // chunkSize = ceil(500 * 1.8) = 900
    // Chunks: [1001..1900] and [1901..2800]

    // -- Query 3: get two chunk queries in parallel --
    let (chunkA, chunkB) = switch fs2->getNextQuery(~concurrencyLimit=2) {
    | Ready([a, b]) => (a, b)
    | _ => JsError.throwWithMessage("Expected two chunk queries")
    }

    t.expect(chunkA.fromBlock, ~message="Chunk A should start at 1001").toBe(1001)
    t.expect(chunkB.fromBlock, ~message="Chunk B should start at 1901").toBe(1901)

    fs2->FetchState.startFetchingQueries(~queries=[chunkA, chunkB])

    // -- Respond to the LATER chunk (B) first --
    // Partial response: latestFetchedBlock=2500 < toBlock=2800
    // shouldUpdateBlockRange: 2500 > 1000 (latestBlockRangeUpdateBlock) = true,
    //   then 2500 < 2800 = true (partial response)
    // blockRange = 2500 - 1901 + 1 = 600
    let fs3 =
      fs2->FetchState.handleQueryResult(
        ~query=chunkB,
        ~latestFetchedBlock={blockNumber: 2500, blockTimestamp: 2500 * 15},
        ~newItems=[],
      )

    let p3 = fs3.optimizedPartitions.entities->Dict.getUnsafe("0")
    t.expect(
      p3.prevQueryRange,
      ~message="Chunk B response should update prevQueryRange to 600",
    ).toBe(600)
    t.expect(
      p3.prevPrevQueryRange,
      ~message="Chunk B response should shift prevPrevQueryRange to 500",
    ).toBe(500)
    t.expect(
      p3.latestBlockRangeUpdateBlock,
      ~message="latestBlockRangeUpdateBlock should update to 2500",
    ).toBe(2500)

    // -- Now respond to the EARLIER chunk (A) --
    // Partial response: latestFetchedBlock=1400 < toBlock=1900
    // shouldUpdateBlockRange: 1400 > 2500 (latestBlockRangeUpdateBlock) = FALSE
    // So prevQueryRange should NOT change
    let fs4 =
      fs3->FetchState.handleQueryResult(
        ~query=chunkA,
        ~latestFetchedBlock={blockNumber: 1400, blockTimestamp: 1400 * 15},
        ~newItems=[],
      )

    let p4 = fs4.optimizedPartitions.entities->Dict.getUnsafe("0")
    t.expect(
      p4.prevQueryRange,
      ~message="Earlier chunk A response should NOT overwrite prevQueryRange (still 600)",
    ).toBe(600)
    t.expect(
      p4.prevPrevQueryRange,
      ~message="Earlier chunk A response should NOT overwrite prevPrevQueryRange (still 500)",
    ).toBe(500)
    t.expect(
      p4.latestBlockRangeUpdateBlock,
      ~message="latestBlockRangeUpdateBlock should remain 2500 after stale response",
    ).toBe(2500)
  })
})
