open Vitest

let chainId = 0
let targetBufferSize = 5000
let knownHeight = 0

// Spread into expected query literals so the common fields don't have to be
// repeated everywhere. Every other field is overridden at the call site.
let defaultQuery: FetchState.query = {
  partitionId: "0",
  fromBlock: 0,
  toBlock: None,
  isChunk: false,
  itemsTarget: 0,
  itemsEst: 0,
  selection: {FetchState.dependsOnAddresses: false, onEventRegistrations: []},
  addressesByContractName: Dict.make(),
}

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
    Item(fetchState.buffer->Array.getUnsafe(0))
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
  chain: ChainMap.Chain.makeUnsafe(~chainId),
  blockNumber,
  onEventRegistration: Utils.magic("Mock onEventRegistration in fetchstate test"),
  logIndex,
  transactionIndex: 0,
  payload: "Mock event in fetchstate test"->(Utils.magic: string => Internal.eventPayload),
})

let dcToItem = (dc: Internal.indexingAddress) => {
  let item = mockEvent(~blockNumber=dc.registrationBlock)
  item->Internal.setItemDcs([dc])
  item
}

let baseEventConfig = (MockIndexer.evmOnEventRegistration(
  ~id="0",
  ~contractName="Gravatar",
) :> Internal.onEventRegistration)

let baseEventConfig2 = (MockIndexer.evmOnEventRegistration(
  ~id="0",
  ~contractName="NftFactory",
) :> Internal.onEventRegistration)

let makeInitial = (
  ~knownHeight=knownHeight,
  ~startBlock=0,
  ~blockLag=?,
  ~maxAddrInPartition=3,
  ~targetBufferSize=targetBufferSize,
) => {
  let onEventRegistrations = [baseEventConfig, baseEventConfig2]
  let addresses = [
    {
      Internal.address: mockAddress0,
      contractName: "Gravatar",
      registrationBlock: -1,
    },
  ]
  let contractConfigs = IndexingAddresses.makeContractConfigs(~onEventRegistrations)
  let indexingAddresses = IndexingAddresses.make(~contractConfigs, ~addresses)
  let fetchState = FetchState.make(
    ~onEventRegistrations,
    ~contractConfigs,
    ~addresses,
    ~startBlock,
    ~endBlock=None,
    ~maxAddrInPartition,
    ~maxOnBlockBufferSize=targetBufferSize,
    ~chainId,
    ~knownHeight,
    ~blockLag?,
  )
  (fetchState, indexingAddresses)
}

let makeInitialFs = (~knownHeight=?, ~startBlock=?, ~blockLag=?, ~maxAddrInPartition=?) => {
  let (fetchState, _indexingAddresses) = makeInitial(
    ~knownHeight?,
    ~startBlock?,
    ~blockLag?,
    ~maxAddrInPartition?,
  )
  fetchState
}

// Builds the address index alongside the fetch state, mirroring how ChainState
// owns it in production. Returns both so tests can thread the index through
// registerDynamicContracts/handleQueryResult/rollback.
let makeFs = (
  ~onEventRegistrations,
  ~addresses,
  ~startBlock,
  ~endBlock,
  ~maxAddrInPartition,
  ~chainId,
  ~maxOnBlockBufferSize,
  ~knownHeight,
  ~progressBlockNumber=?,
  ~onBlockRegistrations=?,
  ~blockLag=?,
  ~firstEventBlock=?,
) => {
  let contractConfigs = IndexingAddresses.makeContractConfigs(~onEventRegistrations)
  let indexingAddresses = IndexingAddresses.make(~contractConfigs, ~addresses)
  let fetchState = FetchState.make(
    ~onEventRegistrations,
    ~contractConfigs,
    ~addresses,
    ~startBlock,
    ~endBlock,
    ~maxAddrInPartition,
    ~chainId,
    ~maxOnBlockBufferSize,
    ~knownHeight,
    ~progressBlockNumber=?progressBlockNumber,
    ~onBlockRegistrations=?onBlockRegistrations,
    ~blockLag=?blockLag,
    ~firstEventBlock=?firstEventBlock,
  )
  (fetchState, indexingAddresses)
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
        effectiveStartBlock: IndexingAddresses.deriveEffectiveStartBlock(
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
    let (fetchState, _indexingAddresses) = makeInitial()

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
            prevRangeSize: 0,
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
      maxOnBlockBufferSize: 5000,
      buffer: [],
      normalSelection: fetchState.normalSelection,
      chainId: 0,
      contractConfigs: fetchState.contractConfigs,
      blockLag: 0,
      onBlockRegistrations: [],
      knownHeight,
      firstEventBlock: None,
    })
  })

  it("Panics with nothing to fetch", t => {
    t.expect(
      () => {
        makeFs(
          ~onEventRegistrations=[baseEventConfig],
          ~addresses=[],
          ~startBlock=0,
          ~endBlock=None,
          ~maxAddrInPartition=2,
          ~maxOnBlockBufferSize=targetBufferSize,
          ~chainId,
          ~knownHeight,
        )
      },
      ~message=`Should panic if there's nothing to fetch`,
    ).toThrowError("Invalid configuration: Nothing to fetch on chain")
  })

  it(
    "Keeps addresses without a matching contract on fetchState so they can be picked up after config changes",
    t => {
      let (fetchState, indexingAddresses) = makeFs(
        ~onEventRegistrations=[baseEventConfig],
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
        ~maxOnBlockBufferSize=targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      t.expect(
        (
          indexingAddresses->IndexingAddresses.size,
          indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString)
          ->Option.map(ia => ia.contractName),
          // No partition is created for the contract without events
          fetchState.optimizedPartitions.entities
          ->Dict.valuesToArray
          ->Array.every(
            p =>
              p.addressesByContractName
              ->Utils.Dict.dangerouslyGetNonOption("NftFactory")
              ->Option.isNone,
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
    let (fetchState, _indexingAddresses) = makeFs(
      ~onEventRegistrations=[baseEventConfig],
      ~addresses=[makeConfigContract("Gravatar", mockAddress1), dc],
      ~startBlock=0,
      ~endBlock=None,
      ~maxOnBlockBufferSize=targetBufferSize,
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
            prevRangeSize: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
          },
        ],
        ~nextPartitionIndex=1,
        ~maxAddrInPartition=2,
        ~dynamicContracts=Utils.Set.fromArray(["Gravatar"]),
      ),
      maxOnBlockBufferSize: targetBufferSize,
      latestOnBlockBlockNumber: -1,
      buffer: [],
      startBlock: 0,
      endBlock: None,
      normalSelection: fetchState.normalSelection,
      chainId,
      contractConfigs: fetchState.contractConfigs,
      blockLag: 0,
      onBlockRegistrations: [],
      knownHeight,
      firstEventBlock: None,
    })
  })

  it(
    "Creates FetchState with static addresses and dc addresses exceeding the maxAddrInPartition limit",
    t => {
      let dc = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress2)
      let (fetchState, _indexingAddresses) = makeFs(
        ~onEventRegistrations=[
          (MockIndexer.evmOnEventRegistration(~id="0", ~contractName="ContractA") :> Internal.onEventRegistration),
          baseEventConfig,
        ],
        ~addresses=[makeConfigContract("ContractA", mockAddress1), dc],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=1,
        ~maxOnBlockBufferSize=targetBufferSize,
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
              prevRangeSize: 0,
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
              prevRangeSize: 0,
              prevPrevQueryRange: 0,
              latestBlockRangeUpdateBlock: 0,
            },
          ],
          ~nextPartitionIndex=2,
          ~maxAddrInPartition=1,
          ~dynamicContracts=Utils.Set.fromArray(["Gravatar"]),
        ),
        maxOnBlockBufferSize: targetBufferSize,
        latestOnBlockBlockNumber: -1,
        buffer: [],
        startBlock: 0,
        endBlock: None,
        normalSelection: fetchState.normalSelection,
        chainId,
        contractConfigs: fetchState.contractConfigs,
        blockLag: 0,
        onBlockRegistrations: [],
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
      let (fetchState, _indexingAddresses) = makeFs(
        ~onEventRegistrations=[
          (MockIndexer.evmOnEventRegistration(~id="0", ~contractName="ContractA") :> Internal.onEventRegistration),
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
        ~maxOnBlockBufferSize=targetBufferSize,
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
              prevRangeSize: 0,
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
              prevRangeSize: 0,
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
              prevRangeSize: 0,
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
              prevRangeSize: 0,
              prevPrevQueryRange: 0,
              latestBlockRangeUpdateBlock: 0,
            },
          ],
          ~nextPartitionIndex=4,
          ~maxAddrInPartition=1,
          ~dynamicContracts=Utils.Set.fromArray(["Gravatar"]),
        ),
        maxOnBlockBufferSize: targetBufferSize,
        latestOnBlockBlockNumber: -1,
        buffer: [],
        startBlock: 0,
        endBlock: None,
        normalSelection: fetchState.normalSelection,
        chainId,
        contractConfigs: fetchState.contractConfigs,
        blockLag: 0,
        onBlockRegistrations: [],
        knownHeight,
        firstEventBlock: None,
      })
    },
  )

  it("Two static contracts with different names merge based on block distance", t => {
    let contractAEventConfig = (MockIndexer.evmOnEventRegistration(
      ~id="0",
      ~contractName="ContractA",
    ) :> Internal.onEventRegistration)
    let closeContractBEventConfig = (MockIndexer.evmOnEventRegistration(
      ~id="0",
      ~contractName="ContractB",
      ~startBlock=19_999,
    ) :> Internal.onEventRegistration)

    // --- Close startBlocks: direct push into current partition ---
    let (closeFetchState, _indexingAddresses) = makeFs(
      ~onEventRegistrations=[contractAEventConfig, closeContractBEventConfig],
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
      ~maxOnBlockBufferSize=targetBufferSize,
      ~chainId,
      ~knownHeight,
    )

    // Phase 1: ContractA partition (block -1), ContractB partition (block 19_998)
    // Phase 2: not too far -> push ContractB addresses into ContractA partition
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
    let farContractBEventConfig = (MockIndexer.evmOnEventRegistration(
      ~id="0",
      ~contractName="ContractB",
      ~startBlock=20_002,
    ) :> Internal.onEventRegistration)
    let (farFetchState, _indexingAddresses) = makeFs(
      ~onEventRegistrations=[contractAEventConfig, farContractBEventConfig],
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
      ~maxOnBlockBufferSize=targetBufferSize,
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
      let contractAEventConfig = (MockIndexer.evmOnEventRegistration(
        ~id="0",
        ~contractName="ContractA",
      ) :> Internal.onEventRegistration)
      let closeContractBEventConfig = (MockIndexer.evmOnEventRegistration(
        ~id="0",
        ~contractName="ContractB",
        ~startBlock=19_999,
      ) :> Internal.onEventRegistration)

      // --- Close startBlocks: direct push into current partition ---
      let (closeFetchState, _indexingAddresses) = makeFs(
        ~onEventRegistrations=[contractAEventConfig, closeContractBEventConfig],
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
        ~maxOnBlockBufferSize=targetBufferSize,
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
      ).toEqual(Dict.fromArray([("ContractA", [mockAddress0]), ("ContractB", [mockAddress1])]))
      t.expect(
        (closePartitions.entities->Dict.getUnsafe("0")).mergeBlock,
        ~message="Close startBlocks: no mergeBlock needed for single partition",
      ).toEqual(None)

      // --- Far startBlocks: mergeBlock on current, merge addresses into next ---
      let farContractBEventConfig = (MockIndexer.evmOnEventRegistration(
        ~id="0",
        ~contractName="ContractB",
        ~startBlock=20_002,
      ) :> Internal.onEventRegistration)
      let (farFetchState, _indexingAddresses) = makeFs(
        ~onEventRegistrations=[contractAEventConfig, farContractBEventConfig],
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
        ~maxOnBlockBufferSize=targetBufferSize,
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
      ).toEqual(Dict.fromArray([("ContractB", [mockAddress1]), ("ContractA", [mockAddress0])]))
      t.expect(
        (farPartitions.entities->Dict.getUnsafe("1")).mergeBlock,
        ~message="Far startBlocks: later partition has no mergeBlock",
      ).toEqual(None)
    },
  )

  it("Different contracts with filterByAddresses merge into a single partition", t => {
    let contractAEventConfig = (MockIndexer.evmOnEventRegistration(
      ~id="0",
      ~contractName="ContractA",
      ~filterByAddresses=true,
    ) :> Internal.onEventRegistration)
    let contractBEventConfig = (MockIndexer.evmOnEventRegistration(
      ~id="0",
      ~contractName="ContractB",
      ~filterByAddresses=true,
      ~startBlock=100,
    ) :> Internal.onEventRegistration)

    let (fetchState, _indexingAddresses) = makeFs(
      ~onEventRegistrations=[contractAEventConfig, contractBEventConfig],
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
      ~maxOnBlockBufferSize=targetBufferSize,
      ~chainId,
      ~knownHeight,
    )

    // filterByAddresses no longer forces a partition per startBlock: the two
    // contracts merge into one partition and the client-side address filter
    // drops events before each address's effectiveStartBlock.
    let partitions = fetchState.optimizedPartitions
    t.expect(
      partitions.idsInAscOrder,
      ~message="filterByAddresses: contracts merge into a single partition",
    ).toEqual(["0"])
    t.expect(
      (partitions.entities->Dict.getUnsafe("0")).addressesByContractName,
      ~message="filterByAddresses: single partition holds both contracts' addresses",
    ).toEqual(Dict.fromArray([("ContractB", [mockAddress1]), ("ContractA", [mockAddress0])]))
    t.expect(
      (partitions.entities->Dict.getUnsafe("0")).latestFetchedBlock.blockNumber,
      ~message="filterByAddresses: merged partition starts at the earliest block",
    ).toEqual(-1)
    t.expect(
      (partitions.entities->Dict.getUnsafe("0")).mergeBlock,
      ~message="filterByAddresses: merged partition has no mergeBlock",
    ).toEqual(None)
  })
})

describe("FetchState.deriveContractNameByAddress", () => {
  // The reverse index is derived lazily at routing time, not stored on the
  // partition. Memoization on the addressesByContractName object is what keeps a
  // factory with millions of addresses from rebuilding it on every one of a
  // partition's responses, so guard the cache: the same addresses object reuses
  // the same index, a different object derives its own, and both are correct.
  it("Memoizes the reverse index by addressesByContractName identity", t => {
    let addressesByContractName = Dict.fromArray([("Gravatar", [mockAddress0, mockAddress1])])
    let first = addressesByContractName->FetchState.deriveContractNameByAddress
    let again = addressesByContractName->FetchState.deriveContractNameByAddress
    let other =
      Dict.fromArray([("Gravatar", [mockAddress2])])->FetchState.deriveContractNameByAddress

    t.expect(
      (
        first === again,
        first === other,
        first->Dict.get(mockAddress0->Address.toString),
        other->Dict.get(mockAddress2->Address.toString),
      ),
      ~message="same addresses object reuses the cached index; a new object derives its own",
    ).toEqual((true, false, Some("Gravatar"), Some("Gravatar")))
  })
})

describe("FetchState.registerDynamicContracts", () => {
  // It shouldn't happen, but just in case
  it("Nothing breaks when provided an empty array", t => {
    let (fetchState, indexingAddresses) = makeInitial()

    t.expect(
      fetchState->FetchState.registerDynamicContracts(~indexingAddresses, []),
      ~message="Should return fetchState without updating it",
    ).toBe(fetchState)
  })

  it("Doesn't register a dc which is already registered in config", t => {
    let (fetchState, indexingAddresses) = makeInitial()

    t.expect(
      fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [
        makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress0)->dcToItem,
      ]),
      ~message="Should return fetchState without updating it",
    ).toBe(fetchState)
  })

  it(
    "Keeps dc for a contract with no events on the item (persisted to db) and tracks it on indexingAddresses without affecting partitions",
    t => {
      let (fetchState, indexingAddresses) = makeInitial()

      let dc = makeDynContractRegistration(
        ~blockNumber=10,
        ~contractAddress=mockAddress1,
        ~contractName="UnknownContract",
      )
      let item = dc->dcToItem

      let updatedFetchState =
        fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [item])

      t.expect(
        (
          // dc not spliced out of the item - will be saved to db by setBatchDcs
          item->Internal.getItemDcs,
          // tracked on indexingAddresses so later conflicting registrations
          // are detected, and so numAddresses reflects it
          indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString)
          ->Option.map(ia => ia.contractName),
          // partitions unchanged - no fetching for contracts without events
          updatedFetchState.optimizedPartitions === fetchState.optimizedPartitions,
          updatedFetchState.optimizedPartitions.entities,
        ),
        ~message=`dc stays on the item (persisted to db),
          is added to indexingAddresses under its contract name,
          and partitions are left untouched`,
      ).toEqual((
        Some([dc]),
        Some("UnknownContract"),
        true,
        fetchState.optimizedPartitions.entities,
      ))
    },
  )

  it(
    "Deduplicates a second registration for the same no-events address and warns on contract-name conflict",
    t => {
      let (fetchState, indexingAddresses) = makeInitial()

      // Register mockAddress1 for a contract without events - should persist
      // and land in indexingAddresses.
      let dc1 = makeDynContractRegistration(
        ~blockNumber=10,
        ~contractAddress=mockAddress1,
        ~contractName="UnknownContract",
      )
      let item1 = dc1->dcToItem
      let afterFirst = fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [item1])

      // Register the SAME address for a DIFFERENT contract name that also has
      // no events. This should be spliced out of the item (already tracked)
      // and warn about the contract-name conflict.
      let dc2 = makeDynContractRegistration(
        ~blockNumber=11,
        ~contractAddress=mockAddress1,
        ~contractName="AnotherUnknownContract",
      )
      let item2 = dc2->dcToItem
      let afterSecond = afterFirst->FetchState.registerDynamicContracts(~indexingAddresses, [item2])

      // Register the same address a third time for the same "UnknownContract"
      // - should dedup silently (no duplicate db write).
      let dc3 = makeDynContractRegistration(
        ~blockNumber=12,
        ~contractAddress=mockAddress1,
        ~contractName="UnknownContract",
      )
      let item3 = dc3->dcToItem
      let afterThird = afterSecond->FetchState.registerDynamicContracts(~indexingAddresses, [item3])

      t.expect(
        (
          item1->Internal.getItemDcs,
          // Second dc spliced out - already tracked.
          item2->Internal.getItemDcs,
          // Third dc also spliced out - same contract name, already tracked.
          item3->Internal.getItemDcs,
          // First registration is the tracked one (first wins).
          indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString)
          ->Option.map(ia => ia.contractName),
          // No new partition created across any of the registrations.
          afterThird.optimizedPartitions.entities === fetchState.optimizedPartitions.entities,
        ),
        ~message=`first dc kept, subsequent same-address dcs spliced out,
          fetchState still tracks the first contract name,
          and partitions are never affected`,
      ).toEqual((Some([dc1]), Some([]), Some([]), Some("UnknownContract"), true))
    },
  )

  it(
    "Registers a no-events address on indexingAddresses in the same batch as a has-events dc without affecting its partition",
    t => {
      let (fetchState, indexingAddresses) = makeInitial()

      let noEventsDc = makeDynContractRegistration(
        ~blockNumber=5,
        ~contractAddress=mockAddress2,
        ~contractName="UnknownContract",
      )
      let regularDc = makeDynContractRegistration(
        ~blockNumber=5,
        ~contractAddress=mockAddress1,
        ~contractName="Gravatar",
      )

      let updatedFetchState =
        fetchState->FetchState.registerDynamicContracts(
          ~indexingAddresses,
          [noEventsDc->dcToItem, regularDc->dcToItem],
        )

      t.expect(
        (
          indexingAddresses->IndexingAddresses.get(mockAddress2->Address.toString)
          ->Option.map(ia => ia.contractName),
          indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString)
          ->Option.map(ia => ia.contractName),
          // Only the Gravatar address lands in a partition.
          updatedFetchState.optimizedPartitions.entities
          ->Dict.valuesToArray
          ->Array.some(
            p =>
              p.addressesByContractName
              ->Utils.Dict.dangerouslyGetNonOption("Gravatar")
              ->Option.map(addrs => addrs->Array.includes(mockAddress1))
              ->Option.getOr(false),
          ),
          updatedFetchState.optimizedPartitions.entities
          ->Dict.valuesToArray
          ->Array.every(
            p =>
              p.addressesByContractName
              ->Utils.Dict.dangerouslyGetNonOption("UnknownContract")
              ->Option.isNone,
          ),
        ),
        ~message=`no-events dc tracked on indexingAddresses,
          has-events dc creates a partition as usual,
          and the no-events contract never enters any partition`,
      ).toEqual((Some("UnknownContract"), Some("Gravatar"), true, true))
    },
  )

  it(
    "Warns and skips a no-events dc when the address is already registered under a different contract name",
    t => {
      // makeInitial puts mockAddress0 in indexingAddresses under contractName
      // "Gravatar" (which has events). Now try to register the same address
      // for a contract without events and a different name - should trigger
      // warnDifferentContractType via the None-branch conflict path.
      let (fetchState, indexingAddresses) = makeInitial()

      let conflictingDc = makeDynContractRegistration(
        ~blockNumber=10,
        ~contractAddress=mockAddress0,
        ~contractName="UnknownContract",
      )
      let item = conflictingDc->dcToItem

      let updatedFetchState =
        fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [item])

      t.expect(
        (
          // dc spliced out - won't overwrite the existing Gravatar entry in db
          item->Internal.getItemDcs,
          // indexingAddresses still has the original contract name
          indexingAddresses->IndexingAddresses.get(mockAddress0->Address.toString)
          ->Option.map(ia => ia.contractName),
          // fetchState unchanged - nothing new registered
          updatedFetchState === fetchState,
        ),
        ~message=`conflicting no-events dc is spliced out,
          original Gravatar registration preserved,
          and fetchState is unchanged`,
      ).toEqual((Some([]), Some("Gravatar"), true))
    },
  )

  it("Warns and skips when two contracts register the same address within one batch", t => {
    let (fetchState, indexingAddresses) = makeInitial()

    let dc1 = makeDynContractRegistration(
      ~blockNumber=10,
      ~contractAddress=mockAddress1,
      ~contractName="Gravatar",
    )
    let dc2 = makeDynContractRegistration(
      ~blockNumber=10,
      ~contractAddress=mockAddress1,
      ~contractName="NftFactory",
    )
    let item2 = dc2->dcToItem

    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [dc1->dcToItem, item2])

    t.expect(
      (
        indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString)
        ->Option.map(ia => ia.contractName),
        // dc spliced out - won't be persisted to envio_addresses
        item2->Internal.getItemDcs,
        updatedFetchState.optimizedPartitions.entities
        ->Dict.valuesToArray
        ->Array.every(
          p =>
            p.addressesByContractName
            ->Utils.Dict.dangerouslyGetNonOption("NftFactory")
            ->Option.map(addrs => !(addrs->Array.includes(mockAddress1)))
            ->Option.getOr(true),
        ),
      ),
      ~message=`first registration wins,
          the conflicting dc is spliced out,
          and the address never enters the second contract's partitions`,
    ).toEqual((Some("Gravatar"), Some([]), true))
  })

  it(
    "Warns and skips a conflicting no-events dc registered after an events dc in the same batch",
    t => {
      let (fetchState, indexingAddresses) = makeInitial()

      let eventsDc = makeDynContractRegistration(
        ~blockNumber=10,
        ~contractAddress=mockAddress1,
        ~contractName="Gravatar",
      )
      let noEventsDc = makeDynContractRegistration(
        ~blockNumber=10,
        ~contractAddress=mockAddress1,
        ~contractName="UnknownContract",
      )
      let noEventsItem = noEventsDc->dcToItem

      let _updatedFetchState =
        fetchState->FetchState.registerDynamicContracts(
          ~indexingAddresses,
          [eventsDc->dcToItem, noEventsItem],
        )

      t.expect(
        (
          indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString)
          ->Option.map(ia => ia.contractName),
          noEventsItem->Internal.getItemDcs,
        ),
        ~message=`the events registration is preserved on indexingAddresses
          and the conflicting no-events dc is spliced out`,
      ).toEqual((Some("Gravatar"), Some([])))
    },
  )

  it(
    "Warns and skips a conflicting events dc registered after a no-events dc in the same batch",
    t => {
      let (fetchState, indexingAddresses) = makeInitial()

      let noEventsDc = makeDynContractRegistration(
        ~blockNumber=10,
        ~contractAddress=mockAddress1,
        ~contractName="UnknownContract",
      )
      let eventsDc = makeDynContractRegistration(
        ~blockNumber=10,
        ~contractAddress=mockAddress1,
        ~contractName="Gravatar",
      )
      let eventsItem = eventsDc->dcToItem

      let updatedFetchState =
        fetchState->FetchState.registerDynamicContracts(
          ~indexingAddresses,
          [noEventsDc->dcToItem, eventsItem],
        )

      t.expect(
        (
          indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString)
          ->Option.map(ia => ia.contractName),
          eventsItem->Internal.getItemDcs,
          updatedFetchState.optimizedPartitions.entities
          ->Dict.valuesToArray
          ->Array.every(
            p =>
              p.addressesByContractName
              ->Utils.Dict.dangerouslyGetNonOption("Gravatar")
              ->Option.map(addrs => !(addrs->Array.includes(mockAddress1)))
              ->Option.getOr(true),
          ),
        ),
        ~message=`the no-events registration wins,
          the conflicting events dc is spliced out,
          and the address never enters Gravatar partitions`,
      ).toEqual((Some("UnknownContract"), Some([]), true))
    },
  )

  it("Correctly registers all valid contracts even when some are skipped in the middle", t => {
    let (fetchState, indexingAddresses) = makeInitial()

    // Create a single event with 3 DCs:
    // - First DC should be skipped (already exists in config at mockAddress0)
    // - Second and third DCs should both be registered
    let dc1 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress0)
    let dc2 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress1)
    let dc3 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress2)

    let event = mockEvent(~blockNumber=10)
    event->Internal.setItemDcs([dc1, dc2, dc3])

    let _updatedFetchState =
      fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [event])

    // Verify that both DC2 and DC3 were registered correctly
    let hasAddress1 =
      indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString)->Option.isSome
    let hasAddress2 =
      indexingAddresses->IndexingAddresses.get(mockAddress2->Address.toString)->Option.isSome

    t.expect(hasAddress1, ~message="Address1 should be registered").toBe(true)
    t.expect(
      hasAddress2,
      ~message="Address2 should be registered even though Address1 (which came before it) was skipped",
    ).toBe(true)
  })

  it(
    "Should create a new partition for an already registered dc if it has an earlier start block",
    t => {
      let (fetchState, indexingAddresses) = makeInitial()

      let dc1 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress1)

      let fetchStateWithDc1 =
        fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [dc1->dcToItem])

      t.expect(
        (
          fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count,
          fetchStateWithDc1.optimizedPartitions->FetchState.OptimizedPartitions.count,
        ),
        ~message="Should have created a new partition for the dc",
      ).toEqual((1, 2))

      t.expect(
        fetchStateWithDc1->FetchState.registerDynamicContracts(~indexingAddresses, [dc1->dcToItem]),
        ~message="Calling it with the same dc for the second time shouldn't change anything",
      ).toBe(fetchStateWithDc1)

      // This is an edge case we currently don't cover
      // But show a warning in the logs
      t.expect(
        fetchStateWithDc1->FetchState.registerDynamicContracts(~indexingAddresses, [
          makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress1)->dcToItem,
        ]),
        ~message=`BROKEN: Calling it with the same dc
          but earlier block number should create a new short lived partition
          for the specific contract from block 0 to 1. And update the dc in db`,
      ).toBe(fetchStateWithDc1)
    },
  )

  it("Should split dcs into multiple partitions if they exceed maxAddrInPartition", t => {
    let (fetchState, indexingAddresses) = makeInitial()

    let dc1 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress1)
    let dc2 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)
    let dc3 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress3)
    let dc4 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress4)

    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [
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
        prevRangeSize: 0,
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
        prevRangeSize: 0,
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
    // Independent scenario from the same pristine base: the address index is
    // mutated in place, so re-derive a fresh base + index rather than reusing
    // the one already populated by the registration above.
    let (fetchState, indexingAddresses) = makeInitial()
    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [
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
        prevRangeSize: 0,
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
        prevRangeSize: 0,
        prevPrevQueryRange: 0,
        latestBlockRangeUpdateBlock: 0,
      },
    ])
  })

  it(
    "Dcs for a contract with event filtering by addresses are grouped like any other contract",
    // The client-side address filter drops events before each dc's registration
    // block, so these no longer need a partition per registration block.
    t => {
      let (fetchState, indexingAddresses) = makeFs(
        ~onEventRegistrations=[
          baseEventConfig,
          (MockIndexer.evmOnEventRegistration(~id="0", ~contractName="NftFactory") :> Internal.onEventRegistration),
          // An event from another contract
          // which has an event filter by addresses
          (MockIndexer.evmOnEventRegistration(
            ~id="0",
            ~contractName="SimpleNft",
            ~isWildcard=false,
            ~filterByAddresses=true,
          ) :> Internal.onEventRegistration),
        ],
        ~addresses=[makeConfigContract("Gravatar", mockAddress0)],
        ~startBlock=10,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~maxOnBlockBufferSize=targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      t.expect(fetchState.contractConfigs).toEqual(
        Dict.fromArray([
          ("Gravatar", {IndexingAddresses.startBlock: None}),
          ("NftFactory", {IndexingAddresses.startBlock: None}),
          ("SimpleNft", {IndexingAddresses.startBlock: None}),
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
        fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [
          dc1->dcToItem,
          dc2->dcToItem,
          dc3->dcToItem,
          dc4->dcToItem,
          dc5->dcToItem,
        ])

      t.expect(
        updatedFetchState.optimizedPartitions.entities
        ->Dict.valuesToArray
        ->Array.map(
          p => (
            p.id,
            p.dynamicContract,
            p.addressesByContractName,
            p.mergeBlock,
            p.latestFetchedBlock.blockNumber,
          ),
        ),
        ~message="SimpleNft (filterByAddresses) dcs group into a single partition like Gravatar/NftFactory; per-block splitting is no longer needed",
      ).toEqual([
        (
          "0",
          Some("Gravatar"),
          Dict.fromArray([("Gravatar", [mockAddress0, mockAddress1])]),
          None,
          9,
        ),
        ("1", Some("Gravatar"), Dict.fromArray([("Gravatar", [mockAddress1])]), Some(9), 2),
        (
          "2",
          Some("SimpleNft"),
          Dict.fromArray([("SimpleNft", [mockAddress2, mockAddress3, mockAddress4])]),
          None,
          2,
        ),
        ("3", Some("NftFactory"), Dict.fromArray([("NftFactory", [mockAddress5])]), None, 5),
      ])
    },
  )

  it("Choose the earliest dc from the batch when there are two with the same address", t => {
    let (fetchState, indexingAddresses) = makeInitial()

    let dc1 = makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress1)
    let dc2 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress1)
    let dcItem1 = dc1->dcToItem
    let dcItem2 = dc2->dcToItem

    let updatedFetchState = fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [dcItem2, dcItem1])

    t.expect(
      (dcItem1->Internal.getItemDcs, dcItem2->Internal.getItemDcs),
      ~message=`Should choose the earliest dc from the batch
  And remove the dc from the later one, so they are not duplicated in the db`,
    ).toEqual((Some([]), Some([dc2])))
    let expected = makeIndexingContractsWithDynamics([dc2], ~static=[mockAddress0])
    t.expect(
      (
        indexingAddresses->IndexingAddresses.size,
        indexingAddresses->IndexingAddresses.get(mockAddress0->Address.toString),
        indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString),
      ),
      ~message="Should choose the earliest dc from the batch",
    ).toEqual((
      expected->Utils.Dict.size,
      expected->Dict.get(mockAddress0->Address.toString),
      expected->Dict.get(mockAddress1->Address.toString),
    ))
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
        prevRangeSize: 0,
        prevPrevQueryRange: 0,
        latestBlockRangeUpdateBlock: 0,
      },
    ])
  })

  it("All dcs are grouped in a single partition, but don't merged with an existing one", t => {
    let (fetchState, indexingAddresses) = makeInitial()

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
      fetchState->FetchState.registerDynamicContracts(~indexingAddresses, // Order of dcs doesn't matter
      // but they are not sorted in fetch state
      [dc1->dcToItem, dc3->dcToItem, dc2->dcToItem])
    t.expect(indexingAddresses->IndexingAddresses.size).toBe(4)
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
        prevRangeSize: 0,
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
        prevRangeSize: 0,
        prevPrevQueryRange: 0,
        latestBlockRangeUpdateBlock: 0,
      },
    ])
  })

  it(
    "Creates FetchState with wildcard and normal events. Addresses not belonging to event configs should be skipped (pre-registration case)",
    t => {
      let wildcard1 = (MockIndexer.evmOnEventRegistration(
        ~id="wildcard1",
        ~contractName="Gravatar",
        ~isWildcard=true,
      ) :> Internal.onEventRegistration)
      let wildcard2 = (MockIndexer.evmOnEventRegistration(
        ~id="wildcard2",
        ~contractName="Gravatar",
        ~isWildcard=true,
      ) :> Internal.onEventRegistration)
      let normal1 = (MockIndexer.evmOnEventRegistration(
        ~id="normal1",
        ~contractName="NftFactory",
      ) :> Internal.onEventRegistration)
      let normal2 = (MockIndexer.evmOnEventRegistration(
        ~id="normal2",
        ~contractName="NftFactory",
        ~isWildcard=true,
        ~dependsOnAddresses=true,
      ) :> Internal.onEventRegistration)

      let (fetchState, _indexingAddresses) = makeFs(
        ~onEventRegistrations=[wildcard1, wildcard2, normal1, normal2],
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
        ~maxOnBlockBufferSize=targetBufferSize,
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
                onEventRegistrations: [wildcard1, wildcard2],
              },
              addressesByContractName: Dict.make(),
              mergeBlock: None,
              dynamicContract: None,
              mutPendingQueries: [],
              prevQueryRange: 0,
              prevRangeSize: 0,
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
                onEventRegistrations: [normal1, normal2],
              },
              addressesByContractName: Dict.fromArray([
                ("NftFactory", [mockAddress0, mockAddress1, mockAddress5]),
              ]),
              mergeBlock: None,
              dynamicContract: Some("NftFactory"),
              mutPendingQueries: [],
              prevQueryRange: 0,
              prevRangeSize: 0,
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
        maxOnBlockBufferSize: targetBufferSize,
        buffer: [],
        normalSelection: fetchState.normalSelection,
        chainId,
        contractConfigs: fetchState.contractConfigs,
        blockLag: 0,
        onBlockRegistrations: [],
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

  // The address index matching makeIntermidiateDcMerge's hand-built state: the
  // static address plus dc1/dc2/dc3 with their registration blocks, so rollback
  // prunes by block exactly as in production.
  let makeIntermidiateIndex = () => {
    let (fs, indexingAddresses) = makeInitial()
    let _ =
      fs->FetchState.registerDynamicContracts(
        ~indexingAddresses,
        [dc1->dcToItem, dc2->dcToItem, dc3->dcToItem],
      )
    indexingAddresses
  }

  let makeAfterFirstStaticAddressesQuery = (): FetchState.t => {
    let normalSelection = makeInitialFs().normalSelection
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
            prevRangeSize: 0,
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
      maxOnBlockBufferSize: targetBufferSize,
      buffer: [mockEvent(~blockNumber=1), mockEvent(~blockNumber=2)],
      startBlock: 0,
      endBlock: None,
      blockLag: 0,
      normalSelection,
      chainId,
      contractConfigs: makeInitialFs().contractConfigs,
      onBlockRegistrations: [],
      knownHeight,
      firstEventBlock: None,
    }
  }

  let makeIntermidiateDcMerge = (~maxAddrInPartition=3, ~knownHeight=knownHeight): FetchState.t => {
    let normalSelection = makeInitialFs().normalSelection
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
            prevRangeSize: 0,
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
            prevRangeSize: 0,
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
      maxOnBlockBufferSize: targetBufferSize,
      buffer: [mockEvent(~blockNumber=1), mockEvent(~blockNumber=2)],
      startBlock: 0,
      endBlock: None,
      normalSelection,
      chainId,
      contractConfigs: makeInitialFs().contractConfigs,
      blockLag: 0,
      onBlockRegistrations: [],
      knownHeight,
      firstEventBlock: None,
    }
  }

  // The default configuration with ability to overwrite some values.
  // Partitions here have no response yet, so query sizing is a share of
  // rangeBudget split across the partitions with unknown density (see
  // FetchState.getNextQuery) — with the defaults below, a single unknown
  // partition gets the whole 10_000., N of them split it evenly (rounded up).
  //
  // chainTargetBlock is derived from the fetchState's actual (post-update)
  // knownHeight rather than the ~knownHeight param directly, since
  // updateKnownHeight never downgrades — passing a knownHeight lower than the
  // fetchState already has would otherwise desync chainTargetBlock from the
  // real frontier, same as ChainState.getNextQuery derives it in production.
  let getNextQuery = (fs, ~endBlock=None, ~knownHeight=10, ~chainTargetItems=10_000.) => {
    let updated =
      switch endBlock {
      | Some(_) => {...fs, endBlock}
      | None => fs
      }->FetchState.updateKnownHeight(~knownHeight)
    updated->FetchState.getNextQuery(~chainTargetBlock=updated.knownHeight, ~chainTargetItems)
  }

  it("Emulate first indexer queries with a static event", t => {
    let (fetchState, indexingAddresses) = makeInitial()

    t.expect(fetchState->getNextQuery(~knownHeight=0)).toEqual(WaitingForNewBlock)

    let nextQuery = fetchState->getNextQuery

    t.expect(nextQuery).toEqual(
      Ready([
        {
          ...defaultQuery,
          partitionId: "0",
          itemsTarget: 10000,
          itemsEst: 10000,
          fromBlock: 0,
          toBlock: None,
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
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
        itemsTarget: 10000,
        itemsEst: 10000,
        fetchedBlock: None,
      },
    ])

    let repeatedNextQuery = fetchState->getNextQuery

    t.expect(repeatedNextQuery, ~message="Shouldn't double fetch the same partition").toEqual(
      NothingToQuery,
    )

    let updatedFetchState = fetchState->FetchState.handleQueryResult(
      ~indexingAddresses,
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
      updatedFetchState->getNextQuery,
      ~message=`Should wait for new block even if partitions have nothing to query`,
    ).toEqual(WaitingForNewBlock)
    t.expect(
      updatedFetchState->getNextQuery(~knownHeight=11),
      ~message=`Should fetch the head block once the partition is behind the head`,
    ).toEqual(
      Ready([
        {
          ...defaultQuery,
          partitionId: "0",
          itemsTarget: 10000,
          itemsEst: 10000,
          fromBlock: 11,
          toBlock: None,
          selection: updatedFetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
          isChunk: false,
        },
      ]),
    )

    updatedFetchState->FetchState.startFetchingQueries(~queries=[query])
    t.expect(
      updatedFetchState->getNextQuery,
      ~message=`Test that even if all partitions reached the current block height,
      we won't wait for new block while even one partition is fetching.
      It might return an updated knownHeight in response and we won't need to poll for new block`,
    ).toEqual(NothingToQuery)
  })

  it("Emulate first indexer queries with block lag configured", t => {
    let (fetchState, indexingAddresses) = makeInitial(~blockLag=2)

    t.expect(fetchState->getNextQuery(~knownHeight=0)).toEqual(WaitingForNewBlock)

    t.expect(
      fetchState->getNextQuery(~knownHeight=1),
      ~message="Should wait for new block when current block height - block lag is less than 0",
    ).toEqual(WaitingForNewBlock)

    let nextQuery = fetchState->getNextQuery(~endBlock=Some(8), ~knownHeight=10)
    t.expect(nextQuery, ~message="No block lag when we are close to the end block").toEqual(
      Ready([
        {
          ...defaultQuery,
          partitionId: "0",
          itemsTarget: 10000,
          itemsEst: 10000,
          toBlock: Some(8),
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
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
          ...defaultQuery,
          partitionId: "0",
          itemsTarget: 10000,
          itemsEst: 10000,
          toBlock: Some(8),
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
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
      ~indexingAddresses,
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
    let (_, indexingAddresses) = makeInitial()

    let fetchStateWithDcs =
      fetchState
      ->FetchState.registerDynamicContracts(~indexingAddresses, [dc2->dcToItem, dc1->dcToItem])
      ->FetchState.registerDynamicContracts(~indexingAddresses, [dc3->dcToItem])

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
        prevRangeSize: 0,
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
        prevRangeSize: 0,
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
          ...defaultQuery,
          partitionId: "1",
          itemsTarget: 5000,
          itemsEst: 5000,
          toBlock: Some(10),
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress1, mockAddress2])]),
          fromBlock: 1,
        },
        {
          ...defaultQuery,
          partitionId: "2",
          itemsTarget: 5000,
          itemsEst: 5000,
          fromBlock: 2,
          toBlock: None,
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
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
        ~indexingAddresses,
        ~query=queries->Array.getUnsafe(0),
        ~latestFetchedBlock={
          blockNumber: 10,
          blockTimestamp: 10,
        },
        ~newItems=[],
      )
      ->FetchState.handleQueryResult(
        ~indexingAddresses,
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

    let makePartition2Query = (~itemsTarget): FetchState.query => {
      ...defaultQuery,
      partitionId: "2",
      itemsTarget,
      itemsEst: itemsTarget,
      fromBlock: 3,
      toBlock: None,
      selection: fetchState.normalSelection,
      addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
      isChunk: false,
    }
    let makePartition0Query = (~itemsTarget): FetchState.query => {
      ...defaultQuery,
      partitionId: "0",
      itemsTarget,
      itemsEst: itemsTarget,
      toBlock: None,
      selection: fetchState.normalSelection,
      addressesByContractName: Dict.fromArray([
        ("Gravatar", [mockAddress0, mockAddress1, mockAddress2]),
      ]),
      fromBlock: 11,
      isChunk: false,
    }

    t.expect(
      updatedFetchState->getNextQuery(~knownHeight=11),
      ~message=`Since the partition "0" reached the maxAddrNumber,
      there's no point to continue merging partitions,
      so we have two queries concurrently`,
    ).toEqual(
      Ready([makePartition2Query(~itemsTarget=5000), makePartition0Query(~itemsTarget=5000)]),
    )
    // Partition "0" is above the target block, so it's the only eligible
    // unknown-density partition here and gets the whole budget.
    let partition2QuerySolo = makePartition2Query(~itemsTarget=10000)
    t.expect(
      updatedFetchState->getNextQuery(~knownHeight=10),
      ~message=`Even if a single partition reached block height,
      we finish fetching other partitions until waiting for the new block first`,
    ).toEqual(Ready([partition2QuerySolo]))

    updatedFetchState->FetchState.startFetchingQueries(~queries=[partition2QuerySolo])
    // Partition "2" is now fully reserved at 10_000 (its own pending query);
    // chainTargetItems must cover that existing reservation plus fresh room
    // for partition "0" — in production this is automatic, since
    // CrossChainState always credits a chain's own pendingBudget back into
    // chainTargetItems (see CrossChainState.checkAndFetch).
    t.expect(
      updatedFetchState->getNextQuery(~knownHeight=11, ~chainTargetItems=20_000.),
      ~message=`Should skip fetching queries`,
    ).toEqual(Ready([makePartition0Query(~itemsTarget=10000)]))
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
          ...defaultQuery,
          partitionId: "2",
          itemsTarget: 5000,
          itemsEst: 5000,
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
          fromBlock: 3,
          isChunk: false,
        },
        {
          ...defaultQuery,
          FetchState.partitionId: "0",
          itemsTarget: 5000,
          itemsEst: 5000,
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addressesByContractName: Dict.fromArray([
            ("Gravatar", [mockAddress0, mockAddress1, mockAddress2]),
          ]),
          fromBlock: 11,
          isChunk: false,
        },
      ]),
    )

    // Continue with the state from previous test
    // But increase the maxAddrInPartition up to 4
    let fetchState = makeIntermidiateDcMerge(~maxAddrInPartition=4, ~knownHeight=11)
    let indexingAddresses = makeIntermidiateIndex()
    t.expect(
      fetchState->getNextQuery,
      ~message="Although, if we pass it through partition optimization, it should merge partitions now",
    ).toEqual(
      Ready([
        {
          ...defaultQuery,
          partitionId: "2",
          itemsTarget: 5000,
          itemsEst: 5000,
          toBlock: Some(10),
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
          fromBlock: 3,
          isChunk: false,
        },
        {
          ...defaultQuery,
          FetchState.partitionId: "0",
          itemsTarget: 5000,
          itemsEst: 5000,
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addressesByContractName: Dict.fromArray([
            ("Gravatar", [mockAddress0, mockAddress1, mockAddress2, mockAddress3]),
          ]),
          fromBlock: 11,
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
      ~indexingAddresses,
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

    let queries = switch fetchStateWithResponse1->getNextQuery {
    | Ready(queries) => queries
    | _ =>
      JsError.throwWithMessage("Failed to extract query. The getNextQuery should be idempotent")
    }
    fetchStateWithResponse1->FetchState.startFetchingQueries(~queries)

    let fetchStateWithResponse2 = fetchStateWithResponse1->FetchState.handleQueryResult(
      ~indexingAddresses,
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
                itemsTarget: 5000,
                itemsEst: 5000,
                fetchedBlock: None,
              },
            ],
            prevQueryRange: 0,
            prevRangeSize: 0,
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
    let wildcard = (MockIndexer.evmOnEventRegistration(
      ~id="wildcard",
      ~contractName="ContractA",
      ~isWildcard=true,
    ) :> Internal.onEventRegistration)
    let (fetchState, indexingAddresses) = makeFs(
      ~onEventRegistrations=[
        (MockIndexer.evmOnEventRegistration(~id="0", ~contractName="Gravatar") :> Internal.onEventRegistration),
        (MockIndexer.evmOnEventRegistration(~id="0", ~contractName="ContractA") :> Internal.onEventRegistration),
        wildcard,
      ],
      ~addresses=[makeConfigContract("ContractA", mockAddress1)],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=2,
      ~maxOnBlockBufferSize=10,
      ~chainId,
      ~knownHeight,
    )
    let fetchState =
      fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [
        makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)->dcToItem,
      ])

    t.expect(fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count).toEqual(3)

    let nextQuery =
      {...fetchState, knownHeight: 10}->FetchState.getNextQuery(
        ~chainTargetBlock=10,
        ~chainTargetItems=10_000.,
      )

    t.expect(
      nextQuery,
      ~message=`Wildcard partition "0" is untouched.
      Partitions "1" and "2" split in optimized way for further dynamic contract registrations.
      All queries performed in parallel without locking.`,
    ).toEqual(
      Ready([
        {
          ...defaultQuery,
          partitionId: "0",
          itemsTarget: 3333,
          itemsEst: 3333,
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          selection: {
            dependsOnAddresses: false,
            onEventRegistrations: [wildcard],
          },
          addressesByContractName: Dict.make(),
        },
        {
          ...defaultQuery,
          partitionId: "1",
          itemsTarget: 3333,
          itemsEst: 3333,
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("ContractA", [mockAddress1])]),
        },
        {
          ...defaultQuery,
          partitionId: "2",
          itemsTarget: 3333,
          itemsEst: 3333,
          fromBlock: 2,
          toBlock: None,
          isChunk: false,
          selection: fetchState.normalSelection,
          addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress2])]),
        },
      ]),
    )
  })

  it("Correctly rollbacks fetch state", t => {
    let fetchState = makeIntermidiateDcMerge()
    let indexingAddresses = makeIntermidiateIndex()

    // Rollback to block 2: both DCs survive (regBlock <= 2)
    // Partition "0" (lfb=10 > 2) -> DELETED, addresses recreated as partition "1"
    // Partition "2" (lfb=2 <= 2) -> KEPT as partition "0" (IDs reset)
    let fetchStateAfterRollback1 = fetchState->FetchState.rollback(~indexingAddresses, ~targetBlockNumber=2)
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
            prevRangeSize: 0,
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
            prevRangeSize: 0,
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
    let fetchStateAfterRollback2 = fetchState->FetchState.rollback(~indexingAddresses, ~targetBlockNumber=1)
    t.expect(
      fetchStateAfterRollback2,
      ~message=`Both partitions deleted, surviving addresses recreated as partition "0"`,
    ).toEqual({
      ...fetchState,
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
            prevRangeSize: 0,
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
    let fetchStateAfterRollback3 = fetchState->FetchState.rollback(~indexingAddresses, ~targetBlockNumber=-1)
    t.expect(
      fetchStateAfterRollback3,
      ~message=`All DCs removed, only static addr0 recreated as partition "0"`,
    ).toEqual({
      ...fetchState,
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
            prevRangeSize: 0,
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
      (MockIndexer.evmOnEventRegistration(
        ~id="wildcard",
        ~contractName="ContractA",
        ~isWildcard=true,
      ) :> Internal.onEventRegistration),
    ]
    let onEventRegistrations = [
      ...wildcardEventConfigs,
      (MockIndexer.evmOnEventRegistration(~id="0", ~contractName="Gravatar") :> Internal.onEventRegistration),
    ]
    let (fetchState, indexingAddresses) = makeFs(
      ~onEventRegistrations,
      ~addresses=[],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~maxOnBlockBufferSize=10,
      ~chainId,
      ~knownHeight,
    )
    let fetchState =
      fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [
        makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)->dcToItem,
      ])

    // Additionally test that state being reset
    fetchState->FetchState.startFetchingQueries(
      ~queries=[
        {
          ...defaultQuery,
          partitionId: "0",
          itemsTarget: 5000,
          itemsEst: 5000,
          toBlock: None,
          selection: {
            dependsOnAddresses: false,
            onEventRegistrations: wildcardEventConfigs,
          },
          addressesByContractName: Dict.make(),
          fromBlock: 0,
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
    let fetchStateAfterRollback = fetchStateReset->FetchState.rollback(~indexingAddresses, ~targetBlockNumber=1)

    t.expect(
      fetchStateAfterRollback,
      ~message=`Should keep Wildcard partition even if it's empty`,
    ).toEqual({
      ...fetchState,
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
            prevRangeSize: 0,
            prevPrevQueryRange: 0,
            latestBlockRangeUpdateBlock: 0,
            selection: {
              dependsOnAddresses: false,
              onEventRegistrations: wildcardEventConfigs,
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
    let (base, indexingAddresses) = makeInitial()
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
            prevRangeSize: 0,
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
            prevRangeSize: 0,
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
      ...defaultQuery,
      partitionId: "1",
      itemsTarget: 5000,
      itemsEst: 5000,
      fromBlock: 1,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Dict.make(),
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState = fetchState->FetchState.handleQueryResult(
      ~indexingAddresses,
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
    let (base, indexingAddresses) = makeInitial()
    let fetchState = base

    let unsorted = [
      mockEvent(~blockNumber=5, ~logIndex=1),
      mockEvent(~blockNumber=6, ~logIndex=0),
      mockEvent(~blockNumber=6, ~logIndex=2),
      mockEvent(~blockNumber=5, ~logIndex=0),
    ]

    let query: FetchState.query = {
      ...defaultQuery,
      partitionId: "0",
      itemsTarget: 5000,
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Dict.make(),
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
        ~indexingAddresses,
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
    let wildcard = (MockIndexer.evmOnEventRegistration(
      ~id="wildcard",
      ~contractName="ContractA",
      ~isWildcard=true,
    ) :> Internal.onEventRegistration)
    // FetchState with 2 partitions,
    // one of them reached the head
    // another reached max queue size
    let (fetchState, indexingAddresses) = makeFs(
      ~onEventRegistrations=[
        (MockIndexer.evmOnEventRegistration(~id="0", ~contractName="ContractA") :> Internal.onEventRegistration),
        wildcard,
      ],
      ~addresses=[makeConfigContract("ContractA", mockAddress0)],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=2,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~chainId,
      ~knownHeight,
    )

    let query0: FetchState.query = {
      ...defaultQuery,
      partitionId: "0",
      itemsTarget: 5000,
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: {
        dependsOnAddresses: false,
        onEventRegistrations: [wildcard],
      },
      addressesByContractName: Dict.make(),
    }
    let query1: FetchState.query = {
      ...defaultQuery,
      partitionId: "1",
      itemsTarget: 5000,
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Dict.make(),
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query0, query1])
    let fetchState =
      fetchState
      ->FetchState.handleQueryResult(
        ~indexingAddresses,
        ~query=query0,
        ~latestFetchedBlock=getBlockData(~blockNumber=1),
        ~newItems=[mockEvent(~blockNumber=1), mockEvent(~blockNumber=0)],
      )
      ->FetchState.handleQueryResult(
        ~indexingAddresses,
        ~query=query1,
        ~latestFetchedBlock=getBlockData(~blockNumber=2),
        ~newItems=[],
      )

    t.expect(
      {...fetchState, knownHeight: 2}->FetchState.getNextQuery(
        ~chainTargetBlock=2,
        ~chainTargetItems=10_000.,
      ),
      ~message=`Should be possible to query wildcard partition,
      if it didn't reach max queue size limit`,
    ).toEqual(
      Ready([
        {
          ...defaultQuery,
          partitionId: "0",
          itemsTarget: 10000,
          itemsEst: 10000,
          fromBlock: 2,
          toBlock: None,
          isChunk: false,
          selection: {
            dependsOnAddresses: false,
            onEventRegistrations: [wildcard],
          },
          addressesByContractName: Dict.make(),
        },
      ]),
    )
  })

  it("Allows to get event one block earlier than the dc registring event", t => {
    let (fetchState, indexingAddresses) = makeInitial(~knownHeight=10)

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
      ...defaultQuery,
      partitionId: "0",
      itemsTarget: 5000,
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Dict.make(),
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let fetchStateWithEvents =
      fetchState->FetchState.handleQueryResult(
        ~indexingAddresses,
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
      fetchStateWithEvents->FetchState.registerDynamicContracts(~indexingAddresses, [
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
    let (fetchState, indexingAddresses) = makeFs(
      ~onEventRegistrations=[
        (MockIndexer.evmOnEventRegistration(~id="0", ~contractName="ContractA") :> Internal.onEventRegistration),
      ],
      ~addresses=[
        makeConfigContract("ContractA", mockAddress1),
        makeConfigContract("ContractA", mockAddress2),
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=1,
      ~maxOnBlockBufferSize=targetBufferSize,
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
      ...defaultQuery,
      partitionId: "0",
      itemsTarget: 5000,
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Dict.make(),
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
        ~indexingAddresses,
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
    let (base, indexingAddresses) = makeInitial()
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
            prevRangeSize: 0,
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
            prevRangeSize: 0,
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
      ->FetchState.registerDynamicContracts(~indexingAddresses, [
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
      makeInitialFs()->FetchState.isActivelyIndexing,
      ~message=`Should be actively indexing with initial state`,
    ).toEqual(true)
    t.expect(
      {...makeInitialFs(), endBlock: Some(10)}->FetchState.isActivelyIndexing,
      ~message=`Should be actively indexing with initial state, even if there's an endBlock`,
    ).toEqual(true)
    t.expect(
      {...makeInitialFs(), endBlock: Some(0)}->FetchState.isActivelyIndexing,
      ~message=`Should be active if endBlock is equal to the startBlock`,
    ).toEqual(true)
    t.expect(
      {...makeInitialFs(~startBlock=10), endBlock: Some(9)}->FetchState.isActivelyIndexing,
      ~message=`Shouldn't be active if endBlock is less than the startBlock`,
    ).toEqual(false)
    let (_, indexingAddresses) = makeInitial()
    let fetchState = {
      ...makeInitialFs(),
      endBlock: Some(0),
    }
    let query: FetchState.query = {
      ...defaultQuery,
      partitionId: "0",
      itemsTarget: 5000,
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: Some(0),
      isChunk: false,
      selection: makeInitialFs().normalSelection,
      addressesByContractName: Dict.make(),
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    t.expect(
      fetchState
      ->FetchState.handleQueryResult(
        ~indexingAddresses,
        ~query,
        ~newItems=[mockEvent(~blockNumber=0)],
        ~latestFetchedBlock={blockNumber: -1, blockTimestamp: 0},
      )
      ->FetchState.isActivelyIndexing,
      ~message=`Although, with items in the queue it should be considered active`,
    ).toEqual(true)
  })

  it("isFetchingAtHead", t => {
    let (_, indexingAddresses) = makeInitial()
    let fetchToHead = (fetchState: FetchState.t, ~latestFetchedBlockNumber) => {
      let query: FetchState.query = {
        ...defaultQuery,
        partitionId: "0",
        itemsTarget: 5000,
        itemsEst: 5000,
        fromBlock: 0,
        toBlock: None,
        isChunk: false,
        selection: fetchState.normalSelection,
        addressesByContractName: Dict.make(),
      }
      fetchState->FetchState.startFetchingQueries(~queries=[query])
      fetchState->FetchState.handleQueryResult(
        ~indexingAddresses,
        ~query,
        ~newItems=[],
        ~latestFetchedBlock={blockNumber: latestFetchedBlockNumber, blockTimestamp: 0},
      )
    }

    let atHead = makeInitialFs(~knownHeight=10)->fetchToHead(~latestFetchedBlockNumber=10)
    let endBlockReached =
      {...makeInitialFs(~knownHeight=100), endBlock: Some(5)}->fetchToHead(
        ~latestFetchedBlockNumber=5,
      )

    t.expect(
      {
        "knownHeightZero": makeInitialFs()->FetchState.isFetchingAtHead,
        "belowHead": makeInitialFs(~knownHeight=10)->FetchState.isFetchingAtHead,
        "atHead": atHead->FetchState.isFetchingAtHead,
        "endBlockReachedBelowHead": endBlockReached->FetchState.isFetchingAtHead,
      },
      ~message="true once the fetch frontier reaches the head or endBlock, false before",
    ).toEqual({
      "knownHeightZero": false,
      "belowHead": false,
      "atHead": true,
      "endBlockReachedBelowHead": true,
    })
  })

  it(
    "Adding dc between two partitions while query is mid flight does no result in early merged partitinons",
    t => {
      let knownHeight = 600

      let (fetchState, indexingAddresses) = makeFs(
        ~onEventRegistrations=[baseEventConfig],
        ~addresses=[makeConfigContract("Gravatar", mockAddress1)],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=2,
        ~maxOnBlockBufferSize=targetBufferSize,
        ~chainId,
        ~knownHeight,
      )

      let query: FetchState.query = {
        ...defaultQuery,
        partitionId: "0",
        itemsTarget: 5000,
        itemsEst: 5000,
        selection: fetchState.normalSelection,
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress1])]),
        fromBlock: 0,
        toBlock: None,
        isChunk: false,
      }
      fetchState->FetchState.startFetchingQueries(~queries=[query])
      let fetchState =
        fetchState->FetchState.handleQueryResult(
          ~indexingAddresses,
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
      let fetchStateWithDcA = fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [dcA->dcToItem])

      let queries = switch fetchStateWithDcA->FetchState.getNextQuery(
        ~chainTargetBlock=knownHeight,
        ~chainTargetItems=10_000.,
      ) {
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
        fetchStateWithDcA->FetchState.registerDynamicContracts(~indexingAddresses, [dc3->dcToItem])

      let queries = switch fetchStateWithDcB->FetchState.getNextQuery(
        ~chainTargetBlock=knownHeight,
        ~chainTargetItems=10_000.,
      ) {
      | Ready(queries) => queries
      | _ => JsError.throwWithMessage("Expected Ready queries")
      }
      let partition2Query = {
        ...queries->Array.getUnsafe(0),
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress3])]),
        partitionId: "2",
        toBlock: None, // Didn't merge because reached max addresses in partition
        fromBlock: 200,
      }
      t.expect(
        fetchStateWithDcB->FetchState.getNextQuery(~chainTargetBlock=knownHeight, ~chainTargetItems=10_000.),
        ~message=`Create a new partition for the newly registered contract`,
      ).toEqual(Ready([partition2Query, queries->Array.getUnsafe(1)]))

      //Response with updated fetch state
      let fetchStateWithBothDcsAndQueryAResponse =
        fetchStateWithDcB->FetchState.handleQueryResult(
          ~indexingAddresses,
          ~query=queryA,
          ~latestFetchedBlock=getBlockData(~blockNumber=400),
          ~newItems=[],
        )

      t.expect(
        fetchStateWithBothDcsAndQueryAResponse->FetchState.getNextQuery(
          ~chainTargetBlock=knownHeight,
          ~chainTargetItems=10_000.,
        ),
        ~message=`We don't merge partition 2 to partition 1, since it already has end block`,
      ).toEqual(
        Ready([
          {
            // Partition "1" is back in range now that its query resolved, so
            // the even split is now 3-way instead of 2-way.
            ...partition2Query,
            itemsTarget: 3333,
            itemsEst: 3333,
          },
          {
            // Partition responded with no items, so it still has only one
            // response (not two) — density isn't trusted yet, so it's sized
            // as an even 3-way split like the others, not real (zero) density.
            ...queryA,
            partitionId: "1",
            itemsTarget: 3333,
            itemsEst: 3333,
            toBlock: Some(500),
            fromBlock: 401,
          },
          {
            // Partition "0" also still has only one response, so it's also
            // an even 3-way split here vs. the 2-way split it got above.
            ...queries->Array.getUnsafe(1),
            itemsTarget: 3333,
            itemsEst: 3333,
          },
        ]),
      )
    },
  )
})

describe("FetchState.sortForBatch", () => {
  let mkQuery = (fetchState: FetchState.t) => {
    {
      ...defaultQuery,
      FetchState.partitionId: "0",
      itemsTarget: 5000,
      itemsEst: 5000,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addressesByContractName: Dict.make(),
      fromBlock: 0,
    }
  }

  // Helper: create a fetch state with desired latestFetchedBlock and queue items via public API
  let makeFsWith = (~latestBlock: int, ~queueBlocks: array<int>): FetchState.t => {
    let (fs0, indexingAddresses) = makeInitial(~knownHeight=10)
    let query = mkQuery(fs0)
    fs0->FetchState.startFetchingQueries(~queries=[query])
    let fs =
      fs0->FetchState.handleQueryResult(
        ~indexingAddresses,
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

    let prepared = FetchState.sortForBatch([fsHigh, fsLow, fsMid], ~batchSizeTarget=3)

    t.expect(
      prepared->Array.map(fs => fs.buffer->Array.getUnsafe(0)->Internal.getItemBlockNumber),
    ).toEqual([1, 5, 8])
  })

  it("Prioritizes full batches over half full ones", t => {
    // Full batch (>= maxBatchSize items). Make it later (earliest item at block 7)
    let fsFullLater = makeFsWith(~latestBlock=10, ~queueBlocks=[9, 8, 7])
    // Half-full batch (1 item) but earlier earliest item (block 1)
    let fsHalfEarlier = makeFsWith(~latestBlock=10, ~queueBlocks=[1])

    let prepared = FetchState.sortForBatch([fsHalfEarlier, fsFullLater], ~batchSizeTarget=2)

    t.expect(
      prepared->Array.map(fs => fs.buffer->Array.getUnsafe(0)->Internal.getItemBlockNumber),
    ).toEqual([7, 1])
  })

  it("Treats exactly-full batches as full", t => {
    // Exactly full (== maxBatchSize items)
    let fsExactFull = makeFsWith(~latestBlock=10, ~queueBlocks=[3, 2])
    // Half-full (1 item) but earlier earliest item
    let fsHalfEarlier = makeFsWith(~latestBlock=10, ~queueBlocks=[1])

    let prepared = FetchState.sortForBatch([fsHalfEarlier, fsExactFull], ~batchSizeTarget=2)

    // Full batch should take priority regardless of earlier timestamp of half batch
    t.expect(
      prepared->Array.map(fs => fs.buffer->Array.getUnsafe(0)->Internal.getItemBlockNumber),
    ).toEqual([2, 1])
  })
})

describe("FetchState.isReadyToEnterReorgThreshold", () => {
  it("Returns false when we just started the indexer and it has knownHeight=0", t => {
    let (fetchState, _indexingAddresses) = makeInitial()
    t.expect({...fetchState, knownHeight: 0}->FetchState.isReadyToEnterReorgThreshold).toBe(false)
  })

  it(
    "Returns false when we just started the indexer and it has knownHeight=0, while start block is more than 0 + reorg threshold",
    t => {
      let (fetchState, _indexingAddresses) = makeInitial(~startBlock=6000)
      t.expect({...fetchState, knownHeight: 0}->FetchState.isReadyToEnterReorgThreshold).toBe(false)
    },
  )

  it("Returns true when endBlock is reached and queue is empty", t => {
    // latestFullyFetchedBlock = startBlock - 1 = 5, endBlock = 5
    let (fs, _indexingAddresses) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
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
      ~maxOnBlockBufferSize=targetBufferSize,
      ~chainId,
      ~blockLag=0,
      ~knownHeight=10,
    )
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(true)
  })

  it("Returns false when endBlock not reached and below head - blockLag", t => {
    // latestFullyFetchedBlock = 49, endBlock = 100, head - lag = 50
    let (fs, _indexingAddresses) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
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
      ~maxOnBlockBufferSize=targetBufferSize,
      ~chainId,
      ~blockLag=10,
      ~knownHeight=60,
    )
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(false)
  })

  it("Returns true when endBlock not reached but latest >= head - blockLag", t => {
    // latestFullyFetchedBlock = 49, head - lag = 49
    let (fs, _indexingAddresses) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
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
      ~maxOnBlockBufferSize=targetBufferSize,
      ~chainId,
      ~blockLag=10,
      ~knownHeight=59,
    )
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(true)
  })

  it("Returns true when no endBlock and latest >= head - blockLag (boundary)", t => {
    // latestFullyFetchedBlock = 50, head - lag = 50
    let (fs, _indexingAddresses) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
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
      ~maxOnBlockBufferSize=targetBufferSize,
      ~chainId,
      ~blockLag=10,
      ~knownHeight=60,
    )
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(true)
  })

  it("Returns false when no endBlock and latest < head - blockLag", t => {
    // latestFullyFetchedBlock = 49, head - lag = 50
    let (fs, _indexingAddresses) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
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
      ~maxOnBlockBufferSize=targetBufferSize,
      ~chainId,
      ~blockLag=10,
      ~knownHeight=60,
    )
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(false)
  })

  it("Returns false when queue is not empty even if thresholds are met", t => {
    // EndBlock reached but queue has items
    let (fs, _indexingAddresses) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
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
      ~maxOnBlockBufferSize=targetBufferSize,
      ~chainId,
      ~blockLag=0,
      ~knownHeight=10,
    )
    let fsWithQueue = fs->FetchState.updateInternal(~mutItems=[mockEvent(~blockNumber=6)])
    t.expect(fsWithQueue->FetchState.isReadyToEnterReorgThreshold).toBe(false)
  })

  it("Returns true when the queue is empty and threshold is more than current block height", t => {
    let (fs, _indexingAddresses) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
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
      ~maxOnBlockBufferSize=targetBufferSize,
      ~chainId,
      ~blockLag=200,
      ~knownHeight=10,
    )
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold).toBe(true)
  })
})

describe("Dynamic contracts with start blocks", () => {
  it("Should respect dynamic contract startBlock even when registered earlier", t => {
    let (fetchState, indexingAddresses) = makeInitial()

    // Register a dynamic contract with startBlock=200
    let dynamicContract = makeDynContractRegistration(
      ~contractAddress=mockAddress1, // Use a different address from static contracts
      ~blockNumber=200, // This is the startBlock - when indexing should actually begin
      ~contractName="Gravatar", // Use Gravatar which has event configs in makeInitial
    )

    // Register the contract at block 100 (before its startBlock)
    let _ =
      fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [dynamicContract->dcToItem])

    // The contract should be registered in indexingAddresses
    t.expect(
      indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString)->Option.isSome,
      ~message="Dynamic contract should be registered in indexingAddresses",
    ).toBeTruthy()

    // Verify the startBlock is set correctly
    let registeredContract =
      indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString)
      ->Option.getOrThrow

    t.expect(
      registeredContract.effectiveStartBlock,
      ~message="Dynamic contract should have correct effectiveStartBlock",
    ).toBe(200)
  })

  it("Should handle dynamic contract registration with different startBlocks", t => {
    let (fetchState, indexingAddresses) = makeInitial()

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

    let _ =
      fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [contract1->dcToItem, contract2->dcToItem])

    // Verify both contracts are registered with correct startBlocks
    let contract1Registered =
      indexingAddresses->IndexingAddresses.get(mockAddress1->Address.toString)
      ->Option.getOrThrow

    let contract2Registered =
      indexingAddresses->IndexingAddresses.get(mockAddress2->Address.toString)
      ->Option.getOrThrow

    t.expect(
      contract1Registered.effectiveStartBlock,
      ~message="Contract1 should have startBlock=150",
    ).toBe(150)

    t.expect(
      contract2Registered.effectiveStartBlock,
      ~message="Contract2 should have startBlock=300",
    ).toBe(300)
  })
})

describe("FetchState progress tracking", () => {
  let makeFetchStateWith = (~latestBlock: int, ~queueBlocks: array<(int, int)>): FetchState.t => {
    let (fs0, indexingAddresses) = makeInitial(~knownHeight=1000)
    let query = {
      ...defaultQuery,
      FetchState.partitionId: "0",
      itemsTarget: 5000,
      itemsEst: 5000,
      toBlock: None,
      isChunk: false,
      selection: fs0.normalSelection,
      addressesByContractName: Dict.make(),
      fromBlock: 0,
    }
    fs0->FetchState.startFetchingQueries(~queries=[query])
    fs0->FetchState.handleQueryResult(
      ~indexingAddresses,
      ~query,
      ~latestFetchedBlock={blockNumber: latestBlock, blockTimestamp: latestBlock},
      ~newItems=queueBlocks->Array.map(((b, l)) => mockEvent(~blockNumber=b, ~logIndex=l)),
    )
  }

  it("When queue is empty", t => {
    let fetchStateEmpty = makeFetchStateWith(~latestBlock=100, ~queueBlocks=[])

    t.expect(
      fetchStateEmpty->FetchState.getProgressBlockNumberAt(~index=0),
      ~message="Should return latestFullyFetchedBlock.blockNumber when queue is empty",
    ).toBe(100)
  })

  it("When queue has a single item with log index 0", t => {
    let fetchStateSingleItem = makeFetchStateWith(~latestBlock=55, ~queueBlocks=[(55, 0)])

    t.expect(
      fetchStateSingleItem->FetchState.getProgressBlockNumberAt(~index=0),
      ~message="Should return single queue item blockNumber - 1",
    ).toBe(54)
  })

  it("When queue has a single item with non 0 log index", t => {
    let fetchStateSingleItem = makeFetchStateWith(~latestBlock=55, ~queueBlocks=[(55, 5)])

    t.expect(
      fetchStateSingleItem->FetchState.getProgressBlockNumberAt(~index=0),
      ~message="Should return single queue item blockNumber - 1",
    ).toBe(54)
  })

  it("When queue items are later than latest fetched block", t => {
    let fetchStateWithQueue = makeFetchStateWith(
      ~latestBlock=90,
      ~queueBlocks=[(105, 2), (103, 1), (101, 2)], // Last item has blockNumber=101
    )

    t.expect(
      fetchStateWithQueue->FetchState.getProgressBlockNumberAt(~index=0),
      ~message="Should return latest fetched block number",
    ).toBe(90)
  })
})

describe("FetchState proposes queries against the natural ceiling", () => {
  it(
    "Should not cap a query below endBlock/knownHeight just because the buffer is already large",
    t => {
      let (fetchState, indexingAddresses) = makeInitial(~maxAddrInPartition=1, ~targetBufferSize=10)

      // Create a second partition to make sure a large buffer elsewhere doesn't
      // affect this partition's own proposal.
      let dc = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress1)
      let fetchStateWithTwoPartitions =
        fetchState->FetchState.registerDynamicContracts(~indexingAddresses, [dc->dcToItem])

      // Buffer 15 items (blocks 6..20), far more than targetBufferSize=10. Admission
      // against the shared budget happens in CrossChainState, not here — getNextQuery
      // proposes against the natural ceiling regardless of how full the buffer is.
      let largeQueueEvents = Array.fromInitializer(~length=15, i => mockEvent(~blockNumber=20 - i))

      let query0 = {
        ...defaultQuery,
        FetchState.partitionId: "0",
        itemsTarget: 5000,
        itemsEst: 5000,
        toBlock: None,
        isChunk: false,
        selection: fetchStateWithTwoPartitions.normalSelection,
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
        fromBlock: 0,
      }

      fetchStateWithTwoPartitions->FetchState.startFetchingQueries(~queries=[query0])
      let fetchStateWithLargeQueue =
        fetchStateWithTwoPartitions->FetchState.handleQueryResult(
          ~indexingAddresses,
          ~query=query0,
          ~latestFetchedBlock={blockNumber: 30, blockTimestamp: 30 * 15},
          ~newItems=largeQueueEvents,
        )

      // Test case 1: With endBlock set, should propose all the way to endBlock
      let fetchStateWithEndBlock = {
        ...fetchStateWithLargeQueue,
        endBlock: Some(25),
        knownHeight: 30,
      }

      switch fetchStateWithEndBlock->FetchState.getNextQuery(
        ~chainTargetBlock=30,
        ~chainTargetItems=10_000.,
      ) {
      | Ready([q]) =>
        t.expect(
          q.toBlock,
          ~message="Should propose up to endBlock, unconstrained by the buffer's current size",
        ).toBe(Some(25))
      | _ => JsError.throwWithMessage("Expected Ready query")
      }

      // Test case 2: endBlock=None -> Should use the open-ended head target
      let fetchStateNoEndBlock = {...fetchStateWithLargeQueue, endBlock: None, knownHeight: 30}
      switch fetchStateNoEndBlock->FetchState.getNextQuery(
        ~chainTargetBlock=30,
        ~chainTargetItems=10_000.,
      ) {
      | Ready([q]) =>
        t.expect(
          q.toBlock,
          ~message="Should use None (fetch to head), unconstrained by the buffer's current size",
        ).toBe(None)
      | _ => JsError.throwWithMessage("Expected Ready query")
      }

      // Test case 3: Small queue -> Should also use the open-ended head target
      let query3 = {
        ...defaultQuery,
        FetchState.partitionId: "0",
        itemsTarget: 5000,
        itemsEst: 5000,
        toBlock: None,
        isChunk: false,
        selection: fetchState.normalSelection,
        addressesByContractName: Dict.fromArray([("Gravatar", [mockAddress0])]),
        fromBlock: 0,
      }
      fetchState->FetchState.startFetchingQueries(~queries=[query3])
      let fetchStateSmallQueue =
        fetchState
        ->FetchState.handleQueryResult(
          ~indexingAddresses,
          ~query=query3,
          ~latestFetchedBlock={blockNumber: 10, blockTimestamp: 10 * 15},
          ~newItems=[mockEvent(~blockNumber=5)],
        )
        ->FetchState.updateKnownHeight(~knownHeight=30)

      switch fetchStateSmallQueue->FetchState.getNextQuery(
        ~chainTargetBlock=30,
        ~chainTargetItems=10_000.,
      ) {
      | Ready([q]) => t.expect(q.toBlock, ~message="Should use None (fetch to head)").toBe(None)
      | _ => JsError.throwWithMessage("Expected Ready query")
      }
    },
  )
})

describe("FetchState with onBlockRegistration only (no events)", () => {
  let makeOnBlockRegistration = (
    ~name="testOnBlock",
    ~index=0,
    ~startBlock=None,
    ~endBlock=None,
    ~interval=1,
  ): Internal.onBlockRegistration => {
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
      let onBlockRegistration = makeOnBlockRegistration(~interval=1, ~startBlock=Some(0))

      // Create FetchState with no event configs but with onBlockRegistration
      let (fetchState, _indexingAddresses) = makeFs(
        ~onEventRegistrations=[],
        ~addresses=[],
        ~startBlock=0,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~maxOnBlockBufferSize=10,
        ~chainId,
        ~knownHeight=0,
        ~onBlockRegistrations=[onBlockRegistration],
      )

      // Verify initial state
      t.expect(
        fetchState.optimizedPartitions.idsInAscOrder,
        ~message="Partitions should be empty when there are no event configs",
      ).toEqual([])
      t.expect(fetchState.buffer, ~message="Buffer should be empty initially").toEqual([])
      t.expect(fetchState.knownHeight, ~message="knownHeight should be 0 initially").toBe(0)
      t.expect(
        fetchState.onBlockRegistrations,
        ~message="onBlockRegistrations should be set",
      ).toEqual([onBlockRegistration])

      // Test that getNextQuery returns WaitingForNewBlock when knownHeight is 0
      let nextQuery =
        fetchState->FetchState.getNextQuery(~chainTargetBlock=0, ~chainTargetItems=10_000.)
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
      let nextQuery2 =
        updatedFetchState->FetchState.getNextQuery(~chainTargetBlock=20, ~chainTargetItems=10_000.)
      t.expect(
        nextQuery2,
        ~message="Should return NothingToQuery when there are no partitions to query",
      ).toEqual(NothingToQuery)
    },
  )
})

describe("Stale query response should not overwrite block range", () => {
  // The default configuration with ability to overwrite some values.
  // chainTargetBlock is derived from the post-update knownHeight (see the
  // other getNextQuery helper above for why).
  let getNextQuery = (fs, ~knownHeight=100000, ~chainTargetItems=10_000.) => {
    let updated = fs->FetchState.updateKnownHeight(~knownHeight)
    updated->FetchState.getNextQuery(~chainTargetBlock=updated.knownHeight, ~chainTargetItems)
  }

  it("Out-of-order parallel query responses should not degrade chunking heuristic", t => {
    let (fetchState, indexingAddresses) = makeInitial(~knownHeight=100000)

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
        ~indexingAddresses,
        ~query=q1,
        ~latestFetchedBlock={blockNumber: 500, blockTimestamp: 500 * 15},
        ~newItems=[mockEvent(~blockNumber=100)],
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
        ~indexingAddresses,
        ~query=q2,
        ~latestFetchedBlock={blockNumber: 1000, blockTimestamp: 1000 * 15},
        ~newItems=[mockEvent(~blockNumber=600)],
      )

    let p2 = fs2.optimizedPartitions.entities->Dict.getUnsafe("0")
    t.expect(p2.prevQueryRange, ~message="Second query should set prevQueryRange=500").toBe(500)
    t.expect(
      p2.prevPrevQueryRange,
      ~message="Second query should shift prevPrevQueryRange=501",
    ).toBe(501)
    t.expect(p2.latestBlockRangeUpdateBlock).toBe(1000)

    // Now chunking is active: getMinHistoryRange = Some(min(500, 501)) = Some(500)
    // chunkSize = ceil(500 * 1.8) = 900. Chunks: [1001..1900], [1901..2800], ...

    // -- Query 3: get the first two chunk queries from the parallel set --
    let (chunkA, chunkB) = switch fs2->getNextQuery {
    | Ready(qs) if qs->Array.length >= 2 => (qs->Array.getUnsafe(0), qs->Array.getUnsafe(1))
    | _ => JsError.throwWithMessage("Expected at least two chunk queries")
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
        ~indexingAddresses,
        ~query=chunkB,
        ~latestFetchedBlock={blockNumber: 2500, blockTimestamp: 2500 * 15},
        ~newItems=[],
      )

    let p3 = fs3.optimizedPartitions.entities->Dict.getUnsafe("0")
    t.expect(
      (p3.prevQueryRange, p3.prevPrevQueryRange, p3.latestBlockRangeUpdateBlock),
      ~message="Chunk B response should set prevQueryRange=600, shift prevPrevQueryRange=500, update latestBlockRangeUpdateBlock=2500",
    ).toEqual((600, 500, 2500))

    // -- Now respond to the EARLIER chunk (A) --
    // Partial response: latestFetchedBlock=1500 < toBlock=1900
    // shouldUpdateBlockRange: 1500 > 2500 (latestBlockRangeUpdateBlock) = FALSE
    // So prevQueryRange should NOT change
    let fs4 =
      fs3->FetchState.handleQueryResult(
        ~indexingAddresses,
        ~query=chunkA,
        ~latestFetchedBlock={blockNumber: 1500, blockTimestamp: 1500 * 15},
        ~newItems=[],
      )

    let p4 = fs4.optimizedPartitions.entities->Dict.getUnsafe("0")
    t.expect(
      (p4.prevQueryRange, p4.prevPrevQueryRange, p4.latestBlockRangeUpdateBlock),
      ~message="Earlier chunk A stale response should not overwrite range bookkeeping (still 600, 500, 2500)",
    ).toEqual((600, 500, 2500))
  })
})

describe("FetchState.getNextQuery water-fill round is order-independent", () => {
  // Partition "0" has a trusted density (2 responses) with a chunk cost
  // (1800) that overshoots its round share (ipb=1000): forced to take at
  // least one full chunk, it overshoots regardless of who's processed
  // before/after it. Partition "1" has no signal, so it sizes exactly to
  // whatever share it's given. Before the round-share fix, an earlier
  // partition's overshoot shrank a shared running counter that capped
  // whoever came after it in the same round — so which partition ran first
  // changed the result (and could even push total consumption above
  // rangeBudget). With the fix, every partition's share is ipb - reserved,
  // fixed for the whole round, so the outcome doesn't depend on order.
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}

  let makeTwoPartitionFetchState = (~order: array<string>): FetchState.t => {
    let overshootPartition: FetchState.partition = {
      id: "overshoot",
      latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
      selection: normalSelection,
      addressesByContractName: Dict.fromArray([("MockContract", [mockAddress0])]),
      mergeBlock: None,
      dynamicContract: None,
      mutPendingQueries: [],
      prevQueryRange: 10,
      prevPrevQueryRange: 10,
      prevRangeSize: 1000, // density = 1000 / 10 = 100 items/block
      latestBlockRangeUpdateBlock: 0,
    }
    let unknownPartition: FetchState.partition = {
      id: "unknown",
      latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
      selection: normalSelection,
      addressesByContractName: Dict.fromArray([("MockContract", [mockAddress1])]),
      mergeBlock: None,
      dynamicContract: None,
      mutPendingQueries: [],
      prevQueryRange: 0,
      prevPrevQueryRange: 0,
      prevRangeSize: 0,
      latestBlockRangeUpdateBlock: 0,
    }
    let byId = Dict.fromArray([
      ("overshoot", overshootPartition),
      ("unknown", unknownPartition),
    ])
    let partitions = order->Array.map(id => byId->Dict.getUnsafe(id))
    {
      optimizedPartitions: FetchState.OptimizedPartitions.make(
        ~partitions,
        ~maxAddrInPartition=2,
        ~nextPartitionIndex=2,
        ~dynamicContracts=Utils.Set.make(),
      ),
      startBlock: 0,
      endBlock: None,
      buffer: [],
      normalSelection,
      latestOnBlockBlockNumber: 0,
      maxOnBlockBufferSize: 10000,
      chainId,
      contractConfigs: Dict.make(),
      blockLag: 0,
      onBlockRegistrations: [],
      knownHeight: 10000,
      firstEventBlock: Some(0),
    }
  }

  let getItemsTargetByPartition = nextQuery =>
    switch nextQuery {
    | FetchState.Ready(queries) =>
      queries->Array.map((q: FetchState.query) => (q.partitionId, q.itemsTarget))
    | _ => []
    }

  it("gives the same per-partition totals regardless of which partition is processed first", t => {
    let resultA =
      makeTwoPartitionFetchState(~order=["overshoot", "unknown"])
      ->FetchState.getNextQuery(~chainTargetBlock=10000, ~chainTargetItems=2000.)
      ->getItemsTargetByPartition
      ->Dict.fromArray

    let resultB =
      makeTwoPartitionFetchState(~order=["unknown", "overshoot"])
      ->FetchState.getNextQuery(~chainTargetBlock=10000, ~chainTargetItems=2000.)
      ->getItemsTargetByPartition
      ->Dict.fromArray

    t.expect(
      (resultA, resultB),
      ~message="Same totals whichever partition the round processes first",
    ).toEqual((
      Dict.fromArray([("overshoot", 1800), ("unknown", 1000)]),
      Dict.fromArray([("overshoot", 1800), ("unknown", 1000)]),
    ))
  })
})

describe("FetchState.getNextQuery greedy budget pass fills partitions toward the target", () => {
  // Two equal-density partitions, chunk cost 180 (density 10 × chunkSize 18).
  // "capped" can only fetch one chunk (mergeBlock caps its range); "deep" has
  // unbounded range but stops at the shared target. The greedy pass walks both,
  // spending budget as it fills each toward the target and its range end.
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}

  let makeChunkPartition = (~id, ~address, ~mergeBlock): FetchState.partition => {
    id,
    latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
    selection: normalSelection,
    addressesByContractName: Dict.fromArray([("MockContract", [address])]),
    mergeBlock,
    dynamicContract: None,
    mutPendingQueries: [],
    prevQueryRange: 10,
    prevPrevQueryRange: 10,
    prevRangeSize: 100, // density = 100 / 10 = 10 items/block
    latestBlockRangeUpdateBlock: 0,
  }

  let fetchState: FetchState.t = {
    optimizedPartitions: FetchState.OptimizedPartitions.make(
      ~partitions=[
        makeChunkPartition(~id="deep", ~address=mockAddress0, ~mergeBlock=None),
        makeChunkPartition(~id="capped", ~address=mockAddress1, ~mergeBlock=Some(18)),
      ],
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=2,
      ~dynamicContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock: None,
    buffer: [],
    normalSelection,
    latestOnBlockBlockNumber: 0,
    maxOnBlockBufferSize: 10000,
    chainId,
    contractConfigs: Dict.make(),
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight: 100000,
    firstEventBlock: Some(0),
  }

  it("fills each partition toward the shared target, then stops at its range end", t => {
    let byPartition = Dict.make()
    // Target block 45 is reachable within the 900 budget, so "deep" stops at 45
    // (last chunk trimmed to blocks 37-45 = 90 items) and "capped" fills its
    // single chunk — both served, unlike an unreachable far target where the
    // first partition would spend the whole budget alone.
    switch fetchState->FetchState.getNextQuery(~chainTargetBlock=45, ~chainTargetItems=900.) {
    | Ready(queries) =>
      queries->Array.forEach((q: FetchState.query) =>
        switch byPartition->Dict.get(q.partitionId) {
        | Some(arr) => arr->Array.push((q.fromBlock, q.itemsTarget))->ignore
        | None => byPartition->Dict.set(q.partitionId, [(q.fromBlock, q.itemsTarget)])
        }
      )
    | _ => ()
    }

    t.expect(byPartition).toEqual(
      Dict.fromArray([
        ("deep", [(1, 180), (19, 180), (37, 90)]),
        ("capped", [(1, 180)]),
      ]),
    )
  })
})

describe("FetchState.getNextQuery with uneven in-flight reservations", () => {
  // Partition "1" already holds a 1500-item in-flight chunk, so the fresh
  // budget is only chainTargetItems minus that reservation — new queries draw
  // from what's left, not the full target.
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}

  let makePartition = (~id, ~address, ~knownDensity, ~pendingItemsTarget): FetchState.partition => {
    id,
    latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
    selection: normalSelection,
    addressesByContractName: Dict.fromArray([("MockContract", [address])]),
    mergeBlock: None,
    dynamicContract: None,
    mutPendingQueries: switch pendingItemsTarget {
    | Some(itemsTarget) => [
        {
          fromBlock: 1,
          toBlock: Some(100),
          isChunk: true,
          itemsTarget,
          itemsEst: itemsTarget,
          fetchedBlock: None,
        },
      ]
    | None => []
    },
    prevQueryRange: knownDensity ? 10 : 0,
    prevPrevQueryRange: knownDensity ? 10 : 0,
    prevRangeSize: knownDensity ? 100 : 0, // density = 100 / 10 = 10 items/block
    latestBlockRangeUpdateBlock: 0,
  }

  let makeFetchState = (partitions): FetchState.t => {
    optimizedPartitions: FetchState.OptimizedPartitions.make(
      ~partitions,
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=2,
      ~dynamicContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock: None,
    buffer: [],
    normalSelection,
    latestOnBlockBlockNumber: 0,
    maxOnBlockBufferSize: 10000,
    chainId,
    contractConfigs: Dict.make(),
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight: 10000,
    firstEventBlock: Some(0),
  }

  it("hands a known-density partition only the fresh budget, not the mean footprint", t => {
    let fetchState = makeFetchState([
      makePartition(~id="0", ~address=mockAddress0, ~knownDensity=true, ~pendingItemsTarget=None),
      makePartition(
        ~id="1",
        ~address=mockAddress1,
        ~knownDensity=true,
        ~pendingItemsTarget=Some(1500),
      ),
    ])
    let byPartition = Dict.make()
    switch fetchState->FetchState.getNextQuery(~chainTargetBlock=10000, ~chainTargetItems=2000.) {
    | Ready(queries) =>
      queries->Array.forEach((q: FetchState.query) =>
        switch byPartition->Dict.get(q.partitionId) {
        | Some(arr) => arr->Array.push((q.fromBlock, q.itemsTarget))->ignore
        | None => byPartition->Dict.set(q.partitionId, [(q.fromBlock, q.itemsTarget)])
        }
      )
    | _ => ()
    }

    // Fresh budget = 2000 - 1500 reserved = 500. Level = 500 (partition "1"
    // sits above it). Partition "0": 2 chunks fit the 500 budget + 1 forced
    // chunk for the 140-item leftover — the only overshoot is the
    // min-one-chunk quantization, not the reservation-inflated mean.
    t.expect(byPartition).toEqual(Dict.fromArray([("0", [(1, 180), (19, 180), (37, 180)])]))
  })

  it(
    "sizes an unknown-density probe to its even budget share, then fills chunks by fromBlock until the budget is spent",
    t => {
      let fetchState = makeFetchState([
        makePartition(~id="0", ~address=mockAddress0, ~knownDensity=false, ~pendingItemsTarget=None),
        makePartition(
          ~id="1",
          ~address=mockAddress1,
          ~knownDensity=true,
          ~pendingItemsTarget=Some(1500),
        ),
      ])

      // Fresh budget = 2000 - 1500 reserved = 500, split across the 2 in-range
      // partitions -> probe share 250. Candidates sort by fromBlock: partition
      // "0"'s probe (block 1) is accepted first, then partition "1"'s chunks
      // from block 101 — the second chunk tips the budget negative and ends the
      // pass.
      t.expect(
        fetchState->FetchState.getNextQuery(~chainTargetBlock=10000, ~chainTargetItems=2000.),
      ).toEqual(
        FetchState.Ready([
          {
            partitionId: "0",
            fromBlock: 1,
            toBlock: None,
            isChunk: false,
            itemsTarget: 250,
            itemsEst: 250,
            selection: normalSelection,
            addressesByContractName: Dict.fromArray([("MockContract", [mockAddress0])]),
          },
          {
            partitionId: "1",
            fromBlock: 101,
            toBlock: Some(118),
            isChunk: true,
            itemsTarget: 180,
            itemsEst: 180,
            selection: normalSelection,
            addressesByContractName: Dict.fromArray([("MockContract", [mockAddress1])]),
          },
          {
            partitionId: "1",
            fromBlock: 119,
            toBlock: Some(136),
            isChunk: true,
            itemsTarget: 180,
            itemsEst: 180,
            selection: normalSelection,
            addressesByContractName: Dict.fromArray([("MockContract", [mockAddress1])]),
          },
        ]),
      )
    },
  )

  it("spreads a thin budget across unknown-density partitions as equal parallel probes", t => {
    let fetchState = makeFetchState(
      [mockAddress0, mockAddress1, mockAddress2]->Array.mapWithIndex((address, i) =>
        makePartition(~id=i->Int.toString, ~address, ~knownDensity=false, ~pendingItemsTarget=None)
      ),
    )

    // Fresh budget 300 across 3 unknown-density partitions -> each probes with
    // its even share (100), all three in parallel this tick.
    let makeProbe = (~id, ~address): FetchState.query => {
      partitionId: id,
      fromBlock: 1,
      toBlock: None,
      isChunk: false,
      itemsTarget: 100,
      itemsEst: 100,
      selection: normalSelection,
      addressesByContractName: Dict.fromArray([("MockContract", [address])]),
    }
    t.expect(
      fetchState->FetchState.getNextQuery(~chainTargetBlock=10000, ~chainTargetItems=300.),
    ).toEqual(
      FetchState.Ready([
        makeProbe(~id="0", ~address=mockAddress0),
        makeProbe(~id="1", ~address=mockAddress1),
        makeProbe(~id="2", ~address=mockAddress2),
      ]),
    )
  })

  it("sizes an open-ended probe by chain density over its range to the target", t => {
    let fetchState = makeFetchState([
      makePartition(~id="0", ~address=mockAddress0, ~knownDensity=false, ~pendingItemsTarget=None),
    ])

    // Given a chain density, the probe is sized to the events its range holds:
    // density 10 × (100 - 1 + 1) blocks / 1 partition = 1000 items — instead of
    // the whole 5000 budget share.
    t.expect(
      fetchState->FetchState.getNextQuery(
        ~chainTargetBlock=100,
        ~chainTargetItems=5000.,
        ~chainDensity=10.,
      ),
    ).toEqual(
      FetchState.Ready([
        {
          partitionId: "0",
          fromBlock: 1,
          toBlock: None,
          isChunk: false,
          itemsTarget: 1000,
          itemsEst: 1000,
          selection: normalSelection,
          addressesByContractName: Dict.fromArray([("MockContract", [mockAddress0])]),
        },
      ]),
    )
  })
})

describe("FetchState.getNextQuery target containment", () => {
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}

  let makePartition = (
    ~latestFetchedBlock,
    ~knownDensity,
    ~mergeBlock=None,
    ~mutPendingQueries=[],
  ): FetchState.partition => {
    id: "0",
    latestFetchedBlock: {blockNumber: latestFetchedBlock, blockTimestamp: 0},
    selection: normalSelection,
    addressesByContractName: Dict.fromArray([("MockContract", [mockAddress0])]),
    mergeBlock,
    dynamicContract: None,
    mutPendingQueries,
    prevQueryRange: knownDensity ? 10 : 0,
    prevPrevQueryRange: knownDensity ? 10 : 0,
    prevRangeSize: knownDensity ? 100 : 0, // density = 100 / 10 = 10 items/block
    latestBlockRangeUpdateBlock: 0,
  }

  let makeFetchState = (partition): FetchState.t => {
    optimizedPartitions: FetchState.OptimizedPartitions.make(
      ~partitions=[partition],
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=1,
      ~dynamicContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock: None,
    buffer: [],
    normalSelection,
    latestOnBlockBlockNumber: partition.latestFetchedBlock.blockNumber,
    maxOnBlockBufferSize: 10000,
    chainId,
    contractConfigs: Dict.make(),
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight: 10000,
    firstEventBlock: Some(0),
  }

  it("gates chunk starts at the target block even when a far mergeBlock allows more", t => {
    // mergeBlock=1000 gives the partition a 1000-block hard range; the budget
    // affords 10 chunks. Only chunks STARTING at or below chainTargetBlock=50
    // may be emitted (chunkSize = ceil(10 * 1.8) = 18 -> starts 1, 19, 37);
    // the last chunk keeps its full span past the target.
    let fetchState = makeFetchState(
      makePartition(~latestFetchedBlock=0, ~knownDensity=true, ~mergeBlock=Some(1000)),
    )
    let emitted = switch fetchState->FetchState.getNextQuery(
      ~chainTargetBlock=50,
      ~chainTargetItems=10_000.,
    ) {
    | Ready(queries) => queries->Array.map((q: FetchState.query) => (q.fromBlock, q.toBlock))
    | _ => []
    }
    t.expect(emitted).toEqual([(1, Some(18)), (19, Some(36)), (37, Some(54))])
  })

  it("defers a gap past the target block, then fills it once the target reaches it", t => {
    // Gap [101, 199] sits between the fetched frontier (100) and a pending
    // chunk starting at 200.
    let makeGappedFetchState = () =>
      makeFetchState(
        makePartition(
          ~latestFetchedBlock=100,
          ~knownDensity=false,
          ~mutPendingQueries=[
            {fromBlock: 200, toBlock: Some(219), isChunk: true, itemsTarget: 100, itemsEst: 100, fetchedBlock: None},
          ],
        ),
      )
    let emitted = (~chainTargetBlock) =>
      switch makeGappedFetchState()->FetchState.getNextQuery(
        ~chainTargetBlock,
        ~chainTargetItems=10_000.,
      ) {
      | Ready(queries) =>
        Some(queries->Array.map((q: FetchState.query) => (q.fromBlock, q.toBlock)))
      | NothingToQuery => None
      | WaitingForNewBlock => Some([(-1, None)])
      }
    t.expect(
      (emitted(~chainTargetBlock=50), emitted(~chainTargetBlock=150)),
      ~message="Target below the gap defers it; target inside the gap fills it",
    ).toEqual((None, Some([(101, Some(199))])))
  })
})

describe("FetchState.getNextQuery chunk headroom and budget-driven emit", () => {
  // Single partition with density 10 items/block and chunk history 10 ->
  // chunkSize = ceil(10 * 1.8) = 18, so a chunk costs 180 items at multiplier
  // 1, 270 at the 1.5x backfill headroom, 540 at the 3x realtime headroom.
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}

  let makeFetchState = (): FetchState.t => {
    optimizedPartitions: FetchState.OptimizedPartitions.make(
      ~partitions=[
        {
          id: "0",
          latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
          selection: normalSelection,
          addressesByContractName: Dict.fromArray([("MockContract", [mockAddress0])]),
          mergeBlock: None,
          dynamicContract: None,
          mutPendingQueries: [],
          prevQueryRange: 10,
          prevPrevQueryRange: 10,
          prevRangeSize: 100, // density = 100 / 10 = 10 items/block
          latestBlockRangeUpdateBlock: 0,
        },
      ],
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=1,
      ~dynamicContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock: None,
    buffer: [],
    normalSelection,
    latestOnBlockBlockNumber: 0,
    maxOnBlockBufferSize: 10000,
    chainId,
    contractConfigs: Dict.make(),
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight: 100000,
    firstEventBlock: Some(0),
  }

  let getChunks = (fetchState: FetchState.t, ~chainTargetItems, ~chunkItemsMultiplier=?) =>
    switch fetchState->FetchState.getNextQuery(
      ~chainTargetBlock=100000,
      ~chainTargetItems,
      ~chunkItemsMultiplier?,
    ) {
    | Ready(queries) => queries->Array.map((q: FetchState.query) => (q.fromBlock, q.itemsTarget))
    | _ => []
    }

  it("sizes chunk itemsTarget with the chunk headroom multiplier", t => {
    t.expect({
      "backfill1_5x": makeFetchState()->getChunks(~chainTargetItems=270., ~chunkItemsMultiplier=1.5),
      "realtime3x": makeFetchState()->getChunks(~chainTargetItems=270., ~chunkItemsMultiplier=3.),
    }).toEqual({
      // The 270-item budget is consumed in honest 180-item estimates: the
      // first chunk leaves 90, which re-pours and forces a second full chunk.
      // ceil(1.5 * 10 * 18) = 270 per chunk.
      "backfill1_5x": [(1, 270), (19, 270)],
      // ceil(3 * 10 * 18) = 540 per chunk.
      "realtime3x": [(1, 540), (19, 540)],
    })
  })

  it("emits chunks while the budget lasts, min one chunk per water-fill round", t => {
    t.expect({
      "budget400": makeFetchState()->getChunks(~chainTargetItems=400.),
      "budget50": makeFetchState()->getChunks(~chainTargetItems=50.),
    }).toEqual({
      // 180 + 180 = 360 <= 400 in the first round; the 40-item leftover
      // re-pours and forces one more full chunk, so no budget strands.
      "budget400": [(1, 180), (19, 180), (37, 180)],
      // The first chunk emits full-size regardless of budget (overshoot allowed).
      "budget50": [(1, 180)],
    })
  })
})

describe("Cap-hit truncation does not update chunk history", () => {
  // Chunk history 300 with a pending chunk truncated at block 90: when the
  // truncation was caused by our own itemsTarget cap it says nothing about
  // server capacity, so the 300 history must survive. A sub-cap partial is
  // real capacity evidence and shrinks it to 90.
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}
  let addressesByContractName = Dict.fromArray([("MockContract", [mockAddress0])])

  let makeFetchState = (): FetchState.t => {
    optimizedPartitions: FetchState.OptimizedPartitions.make(
      ~partitions=[
        {
          id: "0",
          latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
          selection: normalSelection,
          addressesByContractName,
          mergeBlock: None,
          dynamicContract: None,
          mutPendingQueries: [],
          prevQueryRange: 300,
          prevPrevQueryRange: 300,
          prevRangeSize: 300,
          latestBlockRangeUpdateBlock: 0,
        },
      ],
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=1,
      ~dynamicContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock: None,
    buffer: [],
    normalSelection,
    latestOnBlockBlockNumber: 0,
    maxOnBlockBufferSize: 10000,
    chainId,
    contractConfigs: Dict.make(),
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight: 100000,
    firstEventBlock: Some(0),
  }

  let chunkQuery: FetchState.query = {
    partitionId: "0",
    fromBlock: 1,
    toBlock: Some(540),
    isChunk: true,
    itemsTarget: 3,
    itemsEst: 3,
    selection: normalSelection,
    addressesByContractName,
  }

  let runPartialResponse = (~itemsCount) => {
    let (_, indexingAddresses) = makeInitial()
    let fetchState = makeFetchState()
    fetchState->FetchState.startFetchingQueries(~queries=[chunkQuery])
    let updated =
      fetchState->FetchState.handleQueryResult(
        ~indexingAddresses,
        ~query=chunkQuery,
        ~latestFetchedBlock={blockNumber: 90, blockTimestamp: 90 * 15},
        ~newItems=Array.fromInitializer(~length=itemsCount, i =>
          mockEvent(~blockNumber=10, ~logIndex=i)
        ),
      )
    updated.optimizedPartitions.entities
    ->Dict.getUnsafe("0")
    ->FetchState.getMinHistoryRange
  }

  it("keeps history on a cap-hit partial and updates it on a sub-cap partial", t => {
    t.expect({
      "capHit": runPartialResponse(~itemsCount=3),
      "subCap": runPartialResponse(~itemsCount=2),
    }).toEqual({
      "capHit": Some(300),
      "subCap": Some(90),
    })
  })
})
