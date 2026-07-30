open Vitest

let chainId = 0->ChainId.fromInt
let targetBufferSize = 5000
let knownHeight = 0

// Spread into expected query literals so the common fields don't have to be
// repeated everywhere. Every other field is overridden at the call site.
let defaultQuery: FetchState.query = {
  partitionId: "0",
  fromBlock: 0,
  toBlock: None,
  isChunk: false,
  itemsTarget: Some(0),
  itemsEst: 0,
  selection: {FetchState.dependsOnAddresses: false, onEventRegistrations: []},
  addresses: TestAddresses.setOf([]),
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

// Same derivation the address store applies: a config address (registration
// block -1) starts at its contract's start block, a dynamic one no earlier than
// the block that registered it.
let deriveEffectiveStartBlock = (~registrationBlock, ~contractStartBlock) =>
  Pervasives.max(Pervasives.max(registrationBlock, 0), contractStartBlock->Option.getOr(0))

let mockEvent = (
  ~blockNumber,
  ~logIndex=0,
  ~chainId=1->ChainId.fromInt,
  ~registrationIndex=0,
): Internal.item =>
  Internal.Event({
    chainId: chainId,
    blockNumber,
    // Carries an `index` so the buffer's dedup key (blockNumber, logIndex, index)
    // resolves; the rest of the registration is unused by these tests.
    onEventRegistration: Utils.magic({"index": registrationIndex}),
    logIndex,
    transactionIndex: 0,
    payload: "Mock event in fetchstate test"->(Utils.magic: string => Internal.eventPayload),
  })

let dcToRegistration = (dc: Internal.indexingAddress): AddressStore.registration => {
  address: dc.address,
  contractName: dc.contractName,
  registrationBlock: dc.registrationBlock,
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
  let addressStore = TestAddresses.makeStore(
    ~onEventRegistrations,
    ~addresses,
    // Config contracts this chain has no events for.
    ~configContractNames=["UnknownContract", "AnotherUnknownContract"],
  )
  let fetchState = FetchState.make(
    ~onEventRegistrations,
    ~addressStore,
    ~addresses,
    ~startBlock,
    ~endBlock=None,
    ~maxAddrInPartition,
    ~maxOnBlockBufferSize=targetBufferSize,
    ~chainId,
    ~knownHeight,
    ~blockLag?,
  )
  (fetchState, addressStore)
}

let makeInitialFs = (~knownHeight=?, ~startBlock=?, ~blockLag=?, ~maxAddrInPartition=?) => {
  let (fetchState, _addressStore) = makeInitial(
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
  ~clientFilterAddressThreshold=?,
  ~configContractNames=?,
) => {
  let addressStore = TestAddresses.makeStore(~onEventRegistrations, ~addresses, ~configContractNames?)
  let fetchState = FetchState.make(
    ~onEventRegistrations,
    ~addressStore,
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
    ~clientFilterAddressThreshold=?clientFilterAddressThreshold,
  )
  (fetchState, addressStore)
}

// Helper to build addressStore dict for test expectations
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
        effectiveStartBlock: deriveEffectiveStartBlock(
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
    let (fetchState, _addressStore) = makeInitial()

    t.expect((fetchState)->TestAddresses.fetchState).toEqual(({
      optimizedPartitions: FetchState.OptimizedPartitions.make(
        ~partitions=[
          {
            id: "0",
            latestFetchedBlock: {
              blockNumber: -1,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            addresses: TestAddresses.setOf([mockAddress0]),
            mergeBlock: None,
            dynamicContract: None,
            mutPendingQueries: [],
            sourceRangeCapacity: 0,
            eventDensity: None,
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
          },
        ],
        ~nextPartitionIndex=1,
        ~maxAddrInPartition=3,
        ~dynamicContracts=Utils.Set.make(),
      ~clientFilteredContracts=Utils.Set.make(),
      ),
      startBlock: 0,
      endBlock: None,
      latestOnBlockBlockNumber: -1,
      maxOnBlockBufferSize: 5000,
      buffer: [],
      normalSelection: fetchState.normalSelection,
      chainId: 0->ChainId.fromInt,
      blockLag: 0,
      onBlockRegistrations: [],
      knownHeight,
      firstEventBlock: None,
      clientFilterAddressThreshold: None,
    })->TestAddresses.fetchState)
  })

  it("Panics with nothing to fetch", t => {
    t->toThrowErrorEqual(
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
     
      "Invalid configuration: Nothing to fetch on chain 0. addresses=0, onEventRegistrations=1, normalRegistrations=1. Make sure that you provided at least one contract address to index, or have events with Wildcard mode enabled, or have onBlock handlers.",
    )
  })

  it(
    "Keeps addresses without a matching contract on fetchState so they can be picked up after config changes",
    t => {
      let (fetchState, addressStore) = makeFs(
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
        ~configContractNames=["NftFactory"],
      )

      t.expect(
        (
          addressStore->AddressStore.size,
          addressStore->AddressStore.get(mockAddress1)
          ->Option.map(ia => ia.contractName),
          // No partition is created for the contract without events
          fetchState.optimizedPartitions.entities
          ->Dict.valuesToArray
          ->Array.every(
            p =>
              p.addresses->AddressSet.countFor("NftFactory") === 0,
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
    let (fetchState, _addressStore) = makeFs(
      ~onEventRegistrations=[baseEventConfig],
      ~addresses=[makeConfigContract("Gravatar", mockAddress1), dc],
      ~startBlock=0,
      ~endBlock=None,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~maxAddrInPartition=2,
      ~chainId,
      ~knownHeight,
    )

    t.expect((fetchState)->TestAddresses.fetchState, ~message=`Should create only one partition`).toEqual(({
      optimizedPartitions: FetchState.OptimizedPartitions.make(
        ~partitions=[
          {
            id: "0",
            latestFetchedBlock: {
              blockNumber: -1,
              blockTimestamp: 0,
            },
            selection: fetchState.normalSelection,
            addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress1, mockAddress2]),
            mergeBlock: None,
            dynamicContract: Some("Gravatar"),
            mutPendingQueries: [],
            sourceRangeCapacity: 0,
            eventDensity: None,
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
          },
        ],
        ~nextPartitionIndex=1,
        ~maxAddrInPartition=2,
        ~dynamicContracts=Utils.Set.fromArray(["Gravatar"]),
        ~clientFilteredContracts=Utils.Set.make(),
      ),
      maxOnBlockBufferSize: targetBufferSize,
      latestOnBlockBlockNumber: -1,
      buffer: [],
      startBlock: 0,
      endBlock: None,
      normalSelection: fetchState.normalSelection,
      chainId,
      blockLag: 0,
      onBlockRegistrations: [],
      knownHeight,
      firstEventBlock: None,
      clientFilterAddressThreshold: None,
    })->TestAddresses.fetchState)
  })

  it(
    "Creates FetchState with static addresses and dc addresses exceeding the maxAddrInPartition limit",
    t => {
      let dc = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress2)
      let (fetchState, _addressStore) = makeFs(
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

      t.expect((fetchState)->TestAddresses.fetchState).toEqual(({
        optimizedPartitions: FetchState.OptimizedPartitions.make(
          ~partitions=[
            {
              id: "0",
              latestFetchedBlock: {
                blockNumber: -1,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              addresses: TestAddresses.setOf([mockAddress1]),
              mergeBlock: None,
              dynamicContract: None,
              mutPendingQueries: [],
              sourceRangeCapacity: 0,
              eventDensity: None,
              prevSourceRangeCapacity: 0,
              latestSourceRangeCapacityUpdateBlock: 0,
            },
            {
              id: "1",
              latestFetchedBlock: {
                blockNumber: -1,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress2]),
              mergeBlock: None,
              dynamicContract: Some("Gravatar"),
              mutPendingQueries: [],
              sourceRangeCapacity: 0,
              eventDensity: None,
              prevSourceRangeCapacity: 0,
              latestSourceRangeCapacityUpdateBlock: 0,
            },
          ],
          ~nextPartitionIndex=2,
          ~maxAddrInPartition=1,
          ~dynamicContracts=Utils.Set.fromArray(["Gravatar"]),
          ~clientFilteredContracts=Utils.Set.make(),
        ),
        maxOnBlockBufferSize: targetBufferSize,
        latestOnBlockBlockNumber: -1,
        buffer: [],
        startBlock: 0,
        endBlock: None,
        normalSelection: fetchState.normalSelection,
        chainId,
        blockLag: 0,
        onBlockRegistrations: [],
        knownHeight,
        firstEventBlock: None,
        clientFilterAddressThreshold: None,
      })->TestAddresses.fetchState)

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
      let (fetchState, _addressStore) = makeFs(
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

      t.expect((fetchState)->TestAddresses.fetchState).toEqual(({
        optimizedPartitions: FetchState.OptimizedPartitions.make(
          ~partitions=[
            {
              id: "0",
              latestFetchedBlock: {
                blockNumber: -1,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              addresses: TestAddresses.setOf([mockAddress2]),
              mergeBlock: None,
              dynamicContract: None,
              mutPendingQueries: [],
              sourceRangeCapacity: 0,
              eventDensity: None,
              prevSourceRangeCapacity: 0,
              latestSourceRangeCapacityUpdateBlock: 0,
            },
            {
              id: "1",
              latestFetchedBlock: {
                blockNumber: -1,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              addresses: TestAddresses.setOf([mockAddress1]),
              mergeBlock: None,
              dynamicContract: None,
              mutPendingQueries: [],
              sourceRangeCapacity: 0,
              eventDensity: None,
              prevSourceRangeCapacity: 0,
              latestSourceRangeCapacityUpdateBlock: 0,
            },
            {
              id: "2",
              latestFetchedBlock: {
                blockNumber: -1,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress4]),
              mergeBlock: None,
              dynamicContract: Some("Gravatar"),
              mutPendingQueries: [],
              sourceRangeCapacity: 0,
              eventDensity: None,
              prevSourceRangeCapacity: 0,
              latestSourceRangeCapacityUpdateBlock: 0,
            },
            {
              id: "3",
              latestFetchedBlock: {
                blockNumber: -1,
                blockTimestamp: 0,
              },
              selection: fetchState.normalSelection,
              addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress3]),
              mergeBlock: None,
              dynamicContract: Some("Gravatar"),
              mutPendingQueries: [],
              sourceRangeCapacity: 0,
              eventDensity: None,
              prevSourceRangeCapacity: 0,
              latestSourceRangeCapacityUpdateBlock: 0,
            },
          ],
          ~nextPartitionIndex=4,
          ~maxAddrInPartition=1,
          ~dynamicContracts=Utils.Set.fromArray(["Gravatar"]),
          ~clientFilteredContracts=Utils.Set.make(),
        ),
        maxOnBlockBufferSize: targetBufferSize,
        latestOnBlockBlockNumber: -1,
        buffer: [],
        startBlock: 0,
        endBlock: None,
        normalSelection: fetchState.normalSelection,
        chainId,
        blockLag: 0,
        onBlockRegistrations: [],
        knownHeight,
        firstEventBlock: None,
        clientFilterAddressThreshold: None,
      })->TestAddresses.fetchState)
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
    let (closeFetchState, _addressStore) = makeFs(
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
      (closePartitions.entities->Dict.getUnsafe("0")).addresses->AddressSet.addresses,
      ~message="Close startBlocks: single partition has both contracts' addresses",
    ).toEqual([mockAddress0, mockAddress1])
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
    let (farFetchState, _addressStore) = makeFs(
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
      (farPartitions.entities->Dict.getUnsafe("1")).addresses->AddressSet.addresses,
      ~message="Far startBlocks: later partition has merged addresses from both contracts",
    ).toEqual([mockAddress0, mockAddress1])
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
      let (closeFetchState, _addressStore) = makeFs(
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
        (closePartitions.entities->Dict.getUnsafe("0")).addresses->AddressSet.addresses,
        ~message="Close startBlocks: single partition has both addresses",
      ).toEqual([mockAddress0, mockAddress1])
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
      let (farFetchState, _addressStore) = makeFs(
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
        (farPartitions.entities->Dict.getUnsafe("1")).addresses->AddressSet.addresses,
        ~message="Far startBlocks: later partition has merged addresses",
      ).toEqual([mockAddress0, mockAddress1])
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

    let (fetchState, _addressStore) = makeFs(
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
      (partitions.entities->Dict.getUnsafe("0")).addresses->AddressSet.addresses,
      ~message="filterByAddresses: single partition holds both contracts' addresses",
    ).toEqual([mockAddress0, mockAddress1])
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


describe("FetchState.registerDynamicContracts", () => {
  // It shouldn't happen, but just in case
  it("Nothing breaks when provided an empty array", t => {
    let (fetchState, addressStore) = makeInitial()

    t.expect(
      fetchState->FetchState.registerDynamicContracts(~addressStore, []),
      ~message="Should return fetchState without updating it",
    ).toBe(fetchState)
  })

  it("Doesn't register a dc which is already registered in config", t => {
    let (fetchState, addressStore) = makeInitial()

    t.expect(
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress0)->dcToRegistration,
      ]),
      ~message="Should return fetchState without updating it",
    ).toBe(fetchState)
  })

  it(
    "Stores a dc for a contract with no events, pending persistence, without affecting partitions",
    t => {
      let (fetchState, addressStore) = makeInitial()

      let dc = makeDynContractRegistration(
        ~blockNumber=10,
        ~contractAddress=mockAddress1,
        ~contractName="UnknownContract",
      )

      let updatedFetchState =
        fetchState->FetchState.registerDynamicContracts(~addressStore, [dc->dcToRegistration])

      t.expect(
        (
          // tracked on addressStore so later conflicting registrations
          // are detected, and so numAddresses reflects it
          addressStore->AddressStore.get(mockAddress1)
          ->Option.map(ia => ia.contractName),
          // still written to the db, so a config that later adds events for
          // the contract picks the address up on restart
          addressStore
          ->AddressStore.pendingEntries
          ->Array.map(ia => ia.address),
          // partitions unchanged - no fetching for contracts without events
          updatedFetchState.optimizedPartitions === fetchState.optimizedPartitions,
          updatedFetchState.optimizedPartitions.entities,
        ),
        ~message=`dc is added to addressStore under its contract name,
          stays pending persistence,
          and partitions are left untouched`,
      ).toEqual((
        Some("UnknownContract"),
        [mockAddress1],
        true,
        fetchState.optimizedPartitions.entities,
      ))
    },
  )

  it(
    "Deduplicates a second registration for the same no-events address and warns on contract-name conflict",
    t => {
      let (fetchState, addressStore) = makeInitial()

      // Register mockAddress1 for a contract without events - should persist
      // and land in addressStore.
      let dc1 = makeDynContractRegistration(
        ~blockNumber=10,
        ~contractAddress=mockAddress1,
        ~contractName="UnknownContract",
      )
      let afterFirst =
        fetchState->FetchState.registerDynamicContracts(~addressStore, [dc1->dcToRegistration])

      // Register the SAME address for a DIFFERENT contract name that also has
      // no events. Already tracked, so it's rejected with a contract-name
      // conflict warning.
      let dc2 = makeDynContractRegistration(
        ~blockNumber=11,
        ~contractAddress=mockAddress1,
        ~contractName="AnotherUnknownContract",
      )
      let afterSecond =
        afterFirst->FetchState.registerDynamicContracts(~addressStore, [dc2->dcToRegistration])

      // Register the same address a third time for the same "UnknownContract"
      // - should dedup silently (no duplicate db write).
      let dc3 = makeDynContractRegistration(
        ~blockNumber=12,
        ~contractAddress=mockAddress1,
        ~contractName="UnknownContract",
      )
      let afterThird =
        afterSecond->FetchState.registerDynamicContracts(~addressStore, [dc3->dcToRegistration])

      t.expect(
        (
          // Only the first registration is ever written.
          addressStore
          ->AddressStore.pendingEntries
          ->Array.map(ia => (ia.address, ia.contractName, ia.registrationBlock)),
          // First registration is the tracked one (first wins).
          addressStore->AddressStore.get(mockAddress1)
          ->Option.map(ia => ia.contractName),
          // No new partition created across any of the registrations.
          afterThird.optimizedPartitions.entities === fetchState.optimizedPartitions.entities,
        ),
        ~message=`first dc kept, subsequent same-address dcs rejected,
          fetchState still tracks the first contract name,
          and partitions are never affected`,
      ).toEqual(([(mockAddress1, "UnknownContract", 10)], Some("UnknownContract"), true))
    },
  )

  it(
    "Registers a no-events address on addressStore in the same batch as a has-events dc without affecting its partition",
    t => {
      let (fetchState, addressStore) = makeInitial()

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
          ~addressStore,
          [noEventsDc->dcToRegistration, regularDc->dcToRegistration],
        )

      t.expect(
        (
          addressStore->AddressStore.get(mockAddress2)
          ->Option.map(ia => ia.contractName),
          addressStore->AddressStore.get(mockAddress1)
          ->Option.map(ia => ia.contractName),
          // Only the Gravatar address lands in a partition.
          updatedFetchState.optimizedPartitions.entities
          ->Dict.valuesToArray
          ->Array.some(
            p =>
              p.addresses
              ->AddressSet.filterByContracts(["Gravatar"])
              ->AddressSet.addresses
              ->Array.includes(mockAddress1),
          ),
          updatedFetchState.optimizedPartitions.entities
          ->Dict.valuesToArray
          ->Array.every(
            p =>
              p.addresses->AddressSet.countFor("UnknownContract") === 0,
          ),
        ),
        ~message=`no-events dc tracked on addressStore,
          has-events dc creates a partition as usual,
          and the no-events contract never enters any partition`,
      ).toEqual((Some("UnknownContract"), Some("Gravatar"), true, true))
    },
  )

  it(
    "Warns and skips a no-events dc when the address is already registered under a different contract name",
    t => {
      // makeInitial puts mockAddress0 in addressStore under contractName
      // "Gravatar" (which has events). Now try to register the same address
      // for a contract without events and a different name - should trigger
      // warnDifferentContractType via the None-branch conflict path.
      let (fetchState, addressStore) = makeInitial()

      let conflictingDc = makeDynContractRegistration(
        ~blockNumber=10,
        ~contractAddress=mockAddress0,
        ~contractName="UnknownContract",
      )

      let updatedFetchState =
        fetchState->FetchState.registerDynamicContracts(
          ~addressStore,
          [conflictingDc->dcToRegistration],
        )

      t.expect(
        (
          // rejected, so it never reaches the db and can't overwrite the
          // existing Gravatar entry
          addressStore->AddressStore.pendingEntries,
          // addressStore still has the original contract name
          addressStore->AddressStore.get(mockAddress0)
          ->Option.map(ia => ia.contractName),
          // fetchState unchanged - nothing new registered
          updatedFetchState === fetchState,
        ),
        ~message=`conflicting no-events dc is rejected,
          original Gravatar registration preserved,
          and fetchState is unchanged`,
      ).toEqual(([], Some("Gravatar"), true))
    },
  )

  it("Warns and skips when two contracts register the same address within one batch", t => {
    let (fetchState, addressStore) = makeInitial()

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
    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts(
        ~addressStore,
        [dc1->dcToRegistration, dc2->dcToRegistration],
      )

    t.expect(
      (
        addressStore->AddressStore.get(mockAddress1)
        ->Option.map(ia => ia.contractName),
        // the rejected dc is never persisted to envio_addresses
        addressStore
        ->AddressStore.pendingEntries
        ->Array.map(ia => (ia.address, ia.contractName)),
        updatedFetchState.optimizedPartitions.entities
        ->Dict.valuesToArray
        ->Array.every(
          p =>
            !(
              p.addresses
              ->AddressSet.filterByContracts(["NftFactory"])
              ->AddressSet.addresses
              ->Array.includes(mockAddress1)
            ),
        ),
      ),
      ~message=`first registration wins,
          the conflicting dc is rejected,
          and the address never enters the second contract's partitions`,
    ).toEqual((Some("Gravatar"), [(mockAddress1, "Gravatar")], true))
  })

  it(
    "Warns and skips a conflicting no-events dc registered after an events dc in the same batch",
    t => {
      let (fetchState, addressStore) = makeInitial()

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
      let _updatedFetchState =
        fetchState->FetchState.registerDynamicContracts(
          ~addressStore,
          [eventsDc->dcToRegistration, noEventsDc->dcToRegistration],
        )

      t.expect(
        (
          addressStore->AddressStore.get(mockAddress1)
          ->Option.map(ia => ia.contractName),
          // one row for the address, under the contract that claimed it first
          addressStore
          ->AddressStore.pendingEntries
          ->Array.map(ia => (ia.address, ia.contractName)),
        ),
        ~message=`the events registration is preserved on addressStore
          and the conflicting no-events dc is rejected`,
      ).toEqual((Some("Gravatar"), [(mockAddress1, "Gravatar")]))
    },
  )

  it(
    "Warns and skips a conflicting events dc registered after a no-events dc in the same batch",
    t => {
      let (fetchState, addressStore) = makeInitial()

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
      let updatedFetchState =
        fetchState->FetchState.registerDynamicContracts(
          ~addressStore,
          [noEventsDc->dcToRegistration, eventsDc->dcToRegistration],
        )

      t.expect(
        (
          addressStore->AddressStore.get(mockAddress1)
          ->Option.map(ia => ia.contractName),
          addressStore
          ->AddressStore.pendingEntries
          ->Array.map(ia => (ia.address, ia.contractName)),
          updatedFetchState.optimizedPartitions.entities
          ->Dict.valuesToArray
          ->Array.every(
            p =>
              !(
                p.addresses
                ->AddressSet.filterByContracts(["Gravatar"])
                ->AddressSet.addresses
                ->Array.includes(mockAddress1)
              ),
          ),
        ),
        ~message=`the no-events registration wins,
          the conflicting events dc is rejected,
          and the address never enters Gravatar partitions`,
      ).toEqual((Some("UnknownContract"), [(mockAddress1, "UnknownContract")], true))
    },
  )

  it("Correctly registers all valid contracts even when some are skipped in the middle", t => {
    let (fetchState, addressStore) = makeInitial()

    // Create a single event with 3 DCs:
    // - First DC should be skipped (already exists in config at mockAddress0)
    // - Second and third DCs should both be registered
    let dc1 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress0)
    let dc2 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress1)
    let dc3 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress2)

    let _updatedFetchState =
      fetchState->FetchState.registerDynamicContracts(
        ~addressStore,
        [dc1, dc2, dc3]->Array.map(dcToRegistration),
      )

    // Verify that both DC2 and DC3 were registered correctly
    let hasAddress1 =
      addressStore->AddressStore.get(mockAddress1)->Option.isSome
    let hasAddress2 =
      addressStore->AddressStore.get(mockAddress2)->Option.isSome

    t.expect(hasAddress1, ~message="Address1 should be registered").toBe(true)
    t.expect(
      hasAddress2,
      ~message="Address2 should be registered even though Address1 (which came before it) was skipped",
    ).toBe(true)
  })

  it(
    "Should create a new partition for an already registered dc if it has an earlier start block",
    t => {
      let (fetchState, addressStore) = makeInitial()

      let dc1 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress1)

      let fetchStateWithDc1 =
        fetchState->FetchState.registerDynamicContracts(~addressStore, [dc1->dcToRegistration])

      t.expect(
        (
          fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count,
          fetchStateWithDc1.optimizedPartitions->FetchState.OptimizedPartitions.count,
        ),
        ~message="Should have created a new partition for the dc",
      ).toEqual((1, 2))

      t.expect(
        fetchStateWithDc1->FetchState.registerDynamicContracts(~addressStore, [dc1->dcToRegistration]),
        ~message="Calling it with the same dc for the second time shouldn't change anything",
      ).toBe(fetchStateWithDc1)

      // This is an edge case we currently don't cover
      // But show a warning in the logs
      t.expect(
        fetchStateWithDc1->FetchState.registerDynamicContracts(~addressStore, [
          makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress1)->dcToRegistration,
        ]),
        ~message=`BROKEN: Calling it with the same dc
          but earlier block number should create a new short lived partition
          for the specific contract from block 0 to 1. And update the dc in db`,
      ).toBe(fetchStateWithDc1)
    },
  )

  it("Should split dcs into multiple partitions if they exceed maxAddrInPartition", t => {
    let (fetchState, addressStore) = makeInitial()

    let dc1 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress1)
    let dc2 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)
    let dc3 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress3)
    let dc4 = makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress4)

    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        dc1->dcToRegistration,
        dc2->dcToRegistration,
        dc3->dcToRegistration,
        dc4->dcToRegistration,
      ])

    t.expect((updatedFetchState.optimizedPartitions.entities->Dict.valuesToArray)->Array.map(TestAddresses.partition),
      ~message=`Should add 2 new partitions + optimize the original partition to merge without blocking`,
    ).toEqual(([
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
        addresses: TestAddresses.setOf(
          ~contractName="Gravatar",
          [mockAddress4, mockAddress2, mockAddress1],
        ),
        mergeBlock: None,
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        sourceRangeCapacity: 0,
        eventDensity: None,
        prevSourceRangeCapacity: 0,
        latestSourceRangeCapacityUpdateBlock: 0,
      },
      {
        id: "2",
        latestFetchedBlock: {
          blockNumber: 1,
          blockTimestamp: 0,
        },
        selection: fetchState.normalSelection,
        addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress3, mockAddress0]),
        mergeBlock: None,
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        sourceRangeCapacity: 0,
        eventDensity: None,
        prevSourceRangeCapacity: 0,
        latestSourceRangeCapacityUpdateBlock: 0,
      },
    ])->Array.map(TestAddresses.partition))

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
    let (fetchState, addressStore) = makeInitial()
    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        dc1FromAnotherContract->dcToRegistration,
        dc2->dcToRegistration,
        dc3->dcToRegistration,
        dc4FromAnotherContract->dcToRegistration,
      ])

    t.expect((updatedFetchState.optimizedPartitions.entities->Dict.valuesToArray)->Array.map(TestAddresses.partition),
      ~message=`Should add 2 new partitions
+ optimize the original partition to merge without blocking
+ dynamic contracts don't share partitions`,
    ).toEqual(([
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
        addresses: TestAddresses.setOf(~contractName="NftFactory", [mockAddress1, mockAddress4]),
        mergeBlock: None,
        dynamicContract: Some("NftFactory"),
        mutPendingQueries: [],
        sourceRangeCapacity: 0,
        eventDensity: None,
        prevSourceRangeCapacity: 0,
        latestSourceRangeCapacityUpdateBlock: 0,
      },
      {
        id: "2",
        latestFetchedBlock: {
          blockNumber: 1,
          blockTimestamp: 0,
        },
        selection: fetchState.normalSelection,
        addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress2, mockAddress3, mockAddress0]),
        mergeBlock: None,
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        sourceRangeCapacity: 0,
        eventDensity: None,
        prevSourceRangeCapacity: 0,
        latestSourceRangeCapacityUpdateBlock: 0,
      },
    ])->Array.map(TestAddresses.partition))
  })

  it(
    "Dcs for a contract with event filtering by addresses are grouped like any other contract",
    // The client-side address filter drops events before each dc's registration
    // block, so these no longer need a partition per registration block.
    t => {
      let (fetchState, addressStore) = makeFs(
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
        fetchState->FetchState.registerDynamicContracts(~addressStore, [
          dc1->dcToRegistration,
          dc2->dcToRegistration,
          dc3->dcToRegistration,
          dc4->dcToRegistration,
          dc5->dcToRegistration,
        ])

      t.expect((updatedFetchState.optimizedPartitions.entities
        ->Dict.valuesToArray
        ->Array.map(
          p => (
            p.id,
            p.dynamicContract,
            p.addresses->AddressSet.addresses,
            p.mergeBlock,
            p.latestFetchedBlock.blockNumber,
          ),
        )),
        ~message="SimpleNft (filterByAddresses) dcs group into a single partition like Gravatar/NftFactory; per-block splitting is no longer needed",
      ).toEqual(([
        (
          "0",
          Some("Gravatar"),
          [mockAddress0, mockAddress1],
          None,
          9,
        ),
        ("1", Some("Gravatar"), [mockAddress1], Some(9), 2),
        (
          "2",
          Some("SimpleNft"),
          [mockAddress2, mockAddress3, mockAddress4],
          None,
          2,
        ),
        ("3", Some("NftFactory"), [mockAddress5], None, 5),
      ]))
    },
  )

  it("Choose the earliest dc from the batch when there are two with the same address", t => {
    let (fetchState, addressStore) = makeInitial()

    let dc1 = makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress1)
    let dc2 = makeDynContractRegistration(~blockNumber=10, ~contractAddress=mockAddress1)
    let updatedFetchState =
      fetchState->FetchState.registerDynamicContracts(
        ~addressStore,
        [dc2->dcToRegistration, dc1->dcToRegistration],
      )

    t.expect(
      addressStore
      ->AddressStore.pendingEntries
      ->Array.map(ia => (ia.address, ia.registrationBlock)),
      ~message=`Should choose the earliest dc from the batch
  And drop the later one, so they are not duplicated in the db`,
    ).toEqual([(mockAddress1, 10)])
    let expected = makeIndexingContractsWithDynamics([dc2], ~static=[mockAddress0])
    t.expect(
      (
        addressStore->AddressStore.size,
        addressStore->AddressStore.get(mockAddress0),
        addressStore->AddressStore.get(mockAddress1),
      ),
      ~message="Should choose the earliest dc from the batch",
    ).toEqual((
      expected->Utils.Dict.size,
      expected->Dict.get(mockAddress0->Address.toString),
      expected->Dict.get(mockAddress1->Address.toString),
    ))
    t.expect((updatedFetchState.optimizedPartitions.entities->Dict.valuesToArray)->Array.map(TestAddresses.partition),
      ~message="Adds dc and optimizes partitions",
    ).toEqual(([
      {
        ...fetchState.optimizedPartitions.entities->Dict.getUnsafe("0"),
        addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress0]),
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
        addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress1, mockAddress0]),
        mergeBlock: None,
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        sourceRangeCapacity: 0,
        eventDensity: None,
        prevSourceRangeCapacity: 0,
        latestSourceRangeCapacityUpdateBlock: 0,
      },
    ])->Array.map(TestAddresses.partition))
  })

  it("All dcs are grouped in a single partition, but don't merged with an existing one", t => {
    let (fetchState, addressStore) = makeInitial()

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
      fetchState->FetchState.registerDynamicContracts(~addressStore, // Order of dcs doesn't matter
      // but they are not sorted in fetch state
      [dc1->dcToRegistration, dc3->dcToRegistration, dc2->dcToRegistration])
    t.expect(addressStore->AddressStore.size).toBe(4)
    t.expect((updatedFetchState.optimizedPartitions.entities->Dict.valuesToArray)->Array.map(TestAddresses.partition)).toEqual(([
      {
        ...fetchState.optimizedPartitions.entities->Dict.getUnsafe("0"),
        addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress0]),
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
        addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress1, mockAddress2, mockAddress0]),
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        sourceRangeCapacity: 0,
        eventDensity: None,
        prevSourceRangeCapacity: 0,
        latestSourceRangeCapacityUpdateBlock: 0,
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
        addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress3]),
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        sourceRangeCapacity: 0,
        eventDensity: None,
        prevSourceRangeCapacity: 0,
        latestSourceRangeCapacityUpdateBlock: 0,
      },
    ])->Array.map(TestAddresses.partition))
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

      let (fetchState, _addressStore) = makeFs(
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

      t.expect((fetchState)->TestAddresses.fetchState,
        ~message=`The static addresses for the Gravatar contract should be skipped, since they don't have non-wildcard event configs`,
      ).toEqual(({
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
              addresses: TestAddresses.setOf([]),
              mergeBlock: None,
              dynamicContract: None,
              mutPendingQueries: [],
              sourceRangeCapacity: 0,
              eventDensity: None,
              prevSourceRangeCapacity: 0,
              latestSourceRangeCapacityUpdateBlock: 0,
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
              addresses: TestAddresses.setOf(~contractName="NftFactory", [mockAddress0, mockAddress1, mockAddress5]),
              mergeBlock: None,
              dynamicContract: Some("NftFactory"),
              mutPendingQueries: [],
              sourceRangeCapacity: 0,
              eventDensity: None,
              prevSourceRangeCapacity: 0,
              latestSourceRangeCapacityUpdateBlock: 0,
            },
          ],
          ~nextPartitionIndex=2,
          ~maxAddrInPartition=1000,
          ~dynamicContracts=Utils.Set.fromArray(["NftFactory"]),
          ~clientFilteredContracts=Utils.Set.make(),
        ),
        startBlock: 0,
        endBlock: None,
        latestOnBlockBlockNumber: -1,
        maxOnBlockBufferSize: targetBufferSize,
        buffer: [],
        normalSelection: fetchState.normalSelection,
        chainId,
        blockLag: 0,
        onBlockRegistrations: [],
        knownHeight,
        firstEventBlock: None,
        clientFilterAddressThreshold: None,
      })->TestAddresses.fetchState)
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
    let (fs, addressStore) = makeInitial()
    let _ =
      fs->FetchState.registerDynamicContracts(
        ~addressStore,
        [dc1->dcToRegistration, dc2->dcToRegistration, dc3->dcToRegistration],
      )
    addressStore
  }

  // `~addressStore` makes the fixture's partitions carry real sets of that
  // store, which is what a fixture used as the state *under test* needs: merging
  // and rollback resolve addresses through their owning store.
  let makeAfterFirstStaticAddressesQuery = (~addressStore=?): FetchState.t => {
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
            sourceRangeCapacity: 0,
            eventDensity: Some(2. /. 11.),
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: normalSelection,
            addresses: TestAddresses.setOf(~store=?addressStore, [mockAddress0]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=1,
        ~maxAddrInPartition=3,
        ~dynamicContracts=Utils.Set.make(),
      ~clientFilteredContracts=Utils.Set.make(),
      ),
      latestOnBlockBlockNumber: knownHeight,
      maxOnBlockBufferSize: targetBufferSize,
      buffer: [mockEvent(~blockNumber=1), mockEvent(~blockNumber=2)],
      startBlock: 0,
      endBlock: None,
      blockLag: 0,
      normalSelection,
      chainId,
      onBlockRegistrations: [],
      knownHeight,
      firstEventBlock: None,
      clientFilterAddressThreshold: None,
    }
  }

  let makeIntermidiateDcMerge = (
    ~maxAddrInPartition=3,
    ~knownHeight=knownHeight,
    ~addressStore=?,
  ): FetchState.t => {
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
            sourceRangeCapacity: 0,
            eventDensity: Some(2. /. 11.),
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: normalSelection,
            addresses: TestAddresses.setOf(
              ~store=?addressStore,
              [mockAddress0, mockAddress1, mockAddress2],
            ),
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
            sourceRangeCapacity: 0,
            // This partition already returned an empty response over block 2.
            eventDensity: Some(0.),
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: normalSelection,
            addresses: TestAddresses.setOf(~store=?addressStore, [mockAddress3]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=3,
        ~maxAddrInPartition,
        ~dynamicContracts=Utils.Set.fromArray(["Gravatar"]),
        ~clientFilteredContracts=Utils.Set.make(),
      ),
      latestOnBlockBlockNumber: knownHeight,
      maxOnBlockBufferSize: targetBufferSize,
      buffer: [mockEvent(~blockNumber=1), mockEvent(~blockNumber=2)],
      startBlock: 0,
      endBlock: None,
      normalSelection,
      chainId,
      blockLag: 0,
      onBlockRegistrations: [],
      knownHeight,
      firstEventBlock: None,
      clientFilterAddressThreshold: None,
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
    let (fetchState, _) = makeInitial()

    t.expect(fetchState->getNextQuery(~knownHeight=0)).toEqual(WaitingForNewBlock)
    t.expect(
      fetchState->getNextQuery(~chainTargetItems=0.),
      ~message="A zero admission budget must not generate a query while the chain is behind",
    ).toEqual(NothingToQuery)

    let nextQuery = fetchState->getNextQuery

    t.expect((nextQuery)->TestAddresses.nextQuery).toEqual((Ready([
        {
          partitionId: "0",
          itemsTarget: Some(10000),
          itemsEst: 10000,
          fromBlock: 0,
          toBlock: None,
          selection: fetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress0]),
          isChunk: false,
        },
      ]))->TestAddresses.nextQuery)

    let query = switch nextQuery {
    | Ready([q]) => q
    | _ => JsError.throwWithMessage("Failed to extract query")
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])

    t.expect((fetchState.optimizedPartitions.entities->Dict.getUnsafe("0")).mutPendingQueries,
      ~message="The startFetchingQueries should mutate mutPendingQueries",
    ).toEqual(([
      {
        fromBlock: 0,
        toBlock: None,
        isChunk: false,
        itemsTarget: Some(10000),
        itemsEst: 10000,
        fetchedBlock: None,
      },
    ]))

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

    t.expect(
      updatedFetchState->TestAddresses.fetchState,
      ~message="Should be equal to the initial state",
    ).toEqual(makeAfterFirstStaticAddressesQuery()->TestAddresses.fetchState)

    t.expect(updatedFetchState->getNextQuery, ~message="Should wait for new block").toEqual(
      WaitingForNewBlock,
    )
    t.expect(
      updatedFetchState->getNextQuery(~chainTargetItems=0.),
      ~message="A zero admission budget must preserve WaitingForNewBlock",
    ).toEqual(WaitingForNewBlock)
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
    t.expect((updatedFetchState->getNextQuery(~knownHeight=11))->TestAddresses.nextQuery,
      ~message=`Should fetch the head block once the partition is behind the head`,
    ).toEqual((Ready([
        {
          partitionId: "0",
          itemsTarget: Some(10000),
          itemsEst: 10000,
          fromBlock: 11,
          toBlock: None,
          selection: updatedFetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress0]),
          isChunk: false,
        },
      ]))->TestAddresses.nextQuery)

    updatedFetchState->FetchState.startFetchingQueries(~queries=[query])
    t.expect(
      updatedFetchState->getNextQuery,
      ~message=`Test that even if all partitions reached the current block height,
      we won't wait for new block while even one partition is fetching.
      It might return an updated knownHeight in response and we won't need to poll for new block`,
    ).toEqual(NothingToQuery)
  })

  it("Emulate first indexer queries with block lag configured", t => {
    let (fetchState, _) = makeInitial(~blockLag=2)

    t.expect(fetchState->getNextQuery(~knownHeight=0)).toEqual(WaitingForNewBlock)

    t.expect(
      fetchState->getNextQuery(~knownHeight=1),
      ~message="Should wait for new block when current block height - block lag is less than 0",
    ).toEqual(WaitingForNewBlock)

    let nextQuery = fetchState->getNextQuery(~endBlock=Some(8), ~knownHeight=10)
    t.expect((nextQuery)->TestAddresses.nextQuery, ~message="No block lag when we are close to the end block").toEqual((Ready([
        {
          partitionId: "0",
          itemsTarget: Some(10000),
          itemsEst: 10000,
          toBlock: Some(8),
          selection: fetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress0]),
          fromBlock: 0,
          isChunk: false,
        },
      ]))->TestAddresses.nextQuery)

    let nextQuery = fetchState->getNextQuery(~endBlock=Some(10), ~knownHeight=10)
    t.expect((nextQuery)->TestAddresses.nextQuery,
      ~message="Should apply block lag even when there's an upcoming end block",
    ).toEqual((Ready([
        {
          partitionId: "0",
          itemsTarget: Some(10000),
          itemsEst: 10000,
          toBlock: Some(8),
          selection: fetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress0]),
          fromBlock: 0,
          isChunk: false,
        },
      ]))->TestAddresses.nextQuery)

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
    let (_, addressStore) = makeInitial()
    let fetchState = makeAfterFirstStaticAddressesQuery(~addressStore)

    let fetchStateWithDcs =
      fetchState
      ->FetchState.registerDynamicContracts(~addressStore, [dc2->dcToRegistration, dc1->dcToRegistration])
      ->FetchState.registerDynamicContracts(~addressStore, [dc3->dcToRegistration])

    t.expect((fetchStateWithDcs.optimizedPartitions.entities->Dict.valuesToArray)->Array.map(TestAddresses.partition),
      ~message="Assert internal representation of the fetch state",
    ).toEqual(([
      {
        ...fetchState.optimizedPartitions.entities->Dict.getUnsafe("0"),
        dynamicContract: Some("Gravatar"),
        addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress0, mockAddress1, mockAddress2]),
      },
      {
        id: "1",
        latestFetchedBlock: {
          blockNumber: 0,
          blockTimestamp: 0,
        },
        selection: fetchState.normalSelection,
        addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress1, mockAddress2]),
        mergeBlock: Some(10),
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        sourceRangeCapacity: 0,
        eventDensity: None,
        prevSourceRangeCapacity: 0,
        latestSourceRangeCapacityUpdateBlock: 0,
      },
      // Creates a new partition for this without merging, since 0 is full and 1 has mergeBlock
      {
        FetchState.id: "2",
        latestFetchedBlock: {
          blockNumber: 1,
          blockTimestamp: 0,
        },
        selection: fetchState.normalSelection,
        addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress3]),
        mergeBlock: None,
        dynamicContract: Some("Gravatar"),
        mutPendingQueries: [],
        sourceRangeCapacity: 0,
        eventDensity: None,
        prevSourceRangeCapacity: 0,
        latestSourceRangeCapacityUpdateBlock: 0,
      },
    ])->Array.map(TestAddresses.partition))

    t.expect((fetchStateWithDcs->getNextQuery)->TestAddresses.nextQuery,
      ~message="Merge DC partition into the later one + query other partitions in parallel",
    ).toEqual((Ready([
        {
          partitionId: "1",
          itemsTarget: Some(5000),
          itemsEst: 5000,
          toBlock: Some(10),
          isChunk: false,
          selection: fetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress1, mockAddress2]),
          fromBlock: 1,
        },
        {
          partitionId: "2",
          // Sits one block ahead of partition "1", so 9/10 of the range to the
          // target -> 4500 vs 5000.
          itemsTarget: Some(4500),
          itemsEst: 4500,
          fromBlock: 2,
          toBlock: None,
          isChunk: false,
          selection: fetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress3]),
        },
        // Partition 0 is not included since it's below knownHeight
      ]))->TestAddresses.nextQuery)

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

    t.expect(
      updatedFetchState->TestAddresses.fetchState,
      ~message="Should be equal to intermidiate state",
    ).toEqual(makeIntermidiateDcMerge()->TestAddresses.fetchState)

    let makePartition2Query = (~itemsEst): FetchState.query => {
      partitionId: "2",
      itemsTarget: Some(itemsEst),
      itemsEst,
      fromBlock: 3,
      toBlock: None,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([mockAddress3]),
      isChunk: false,
    }
    let makePartition0Query = (~itemsEst): FetchState.query => {
      partitionId: "0",
      itemsTarget: Some(itemsEst),
      itemsEst,
      toBlock: None,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([mockAddress0, mockAddress1, mockAddress2]),
      fromBlock: 11,
      isChunk: false,
    }

    t.expect(
      (updatedFetchState->getNextQuery(~knownHeight=11))->TestAddresses.nextQuery,
      ~message=`Since the partition "0" reached the maxAddrNumber,
      there's no point to continue merging partitions,
      so we have two queries concurrently`,
    ).toEqual(
      // Partition "0" sits at block 11 (the head), covering only the last block
      // of the range to the target -> a small probe next to "2"'s 5000.
      Ready([
        makePartition2Query(~itemsEst=5000),
        makePartition0Query(~itemsEst=556),
      ])->TestAddresses.nextQuery,
    )
    // Partition "0" is above the target block, so it's the only eligible
    // unknown-density partition here and gets the whole budget.
    let partition2QuerySolo = makePartition2Query(~itemsEst=10000)
    t.expect((updatedFetchState->getNextQuery(~knownHeight=10))->TestAddresses.nextQuery,
      ~message=`Even if a single partition reached block height,
      we finish fetching other partitions until waiting for the new block first`,
    ).toEqual((Ready([partition2QuerySolo]))->TestAddresses.nextQuery)

    updatedFetchState->FetchState.startFetchingQueries(~queries=[partition2QuerySolo])
    // Partition "2" is now fully reserved at 10_000 (its own pending query);
    // chainTargetItems must cover that existing reservation plus fresh room
    // for partition "0" — in production this is automatic, since
    // CrossChainState always credits a chain's own pendingBudget back into
    // chainTargetItems (see CrossChainState.checkAndFetch).
    t.expect((updatedFetchState->getNextQuery(~knownHeight=11, ~chainTargetItems=20_000.))->TestAddresses.nextQuery,
      ~message=`Should skip fetching queries`,
    ).toEqual((Ready([makePartition0Query(~itemsEst=10000)]))->TestAddresses.nextQuery)
  })

  it("Emulate partition merging cases", t => {
    let originalFetchState = makeIntermidiateDcMerge(~addressStore=makeIntermidiateIndex())
    let originalFetchState = {
      ...originalFetchState,
      optimizedPartitions: {
        ...originalFetchState.optimizedPartitions,
        maxAddrInPartition: 4,
      },
    }
    t.expect((originalFetchState->getNextQuery(~knownHeight=11))->TestAddresses.nextQuery,
      ~message="Until we optimize partitions - on handle query, we don't need to merge partitions",
    ).toEqual((Ready([
        {
          partitionId: "2",
          itemsTarget: Some(5000),
          itemsEst: 5000,
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress3]),
          fromBlock: 3,
          isChunk: false,
        },
        {
          FetchState.partitionId: "0",
          // At block 11 (the head), it covers only the last block of the range
          // to the target, so a small probe next to partition "2"'s 5000.
          itemsTarget: Some(556),
          itemsEst: 556,
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress0, mockAddress1, mockAddress2]),
          fromBlock: 11,
          isChunk: false,
        },
      ]))->TestAddresses.nextQuery)

    // Continue with the state from previous test
    // But increase the maxAddrInPartition up to 4
    let fetchState = makeIntermidiateDcMerge(
      ~maxAddrInPartition=4,
      ~knownHeight=11,
      ~addressStore=makeIntermidiateIndex(),
    )
    t.expect((fetchState->getNextQuery)->TestAddresses.nextQuery,
      ~message="Although, if we pass it through partition optimization, it should merge partitions now",
    ).toEqual((Ready([
        {
          partitionId: "2",
          itemsTarget: Some(5000),
          itemsEst: 5000,
          toBlock: Some(10),
          selection: fetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress3]),
          fromBlock: 3,
          isChunk: false,
        },
        {
          FetchState.partitionId: "0",
          itemsTarget: Some(556),
          itemsEst: 556,
          toBlock: None,
          selection: originalFetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress0, mockAddress1, mockAddress2, mockAddress3]),
          fromBlock: 11,
          isChunk: false,
        },
      ]))->TestAddresses.nextQuery)

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

    t.expect((fetchStateWithResponse2)->TestAddresses.fetchState,
      ~message="Partition 2 should come to mergeBlock and be removed",
    ).toEqual(({
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
                itemsTarget: Some(2500),
                itemsEst: 2500,
                fetchedBlock: None,
              },
            ],
            sourceRangeCapacity: 0,
            eventDensity: Some(2. /. 11.),
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            latestFetchedBlock: {
              blockNumber: 10,
              blockTimestamp: 10,
            },
            selection: fetchState.normalSelection,
            addresses: TestAddresses.setOf([mockAddress0, mockAddress1, mockAddress2, mockAddress3]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=fetchStateWithResponse1.optimizedPartitions.nextPartitionIndex,
        ~maxAddrInPartition=fetchStateWithResponse1.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=fetchStateWithResponse1.optimizedPartitions.dynamicContracts,
        ~clientFilteredContracts=fetchStateWithResponse1.optimizedPartitions.clientFilteredContracts,
      ),
    })->TestAddresses.fetchState)
  })

  it("Skips the blocks below a partition's earliest registration start block", t => {
    let makeWildcard = (~id, ~startBlock=?) =>
      (MockIndexer.evmOnEventRegistration(
        ~id,
        ~contractName="Gravatar",
        ~isWildcard=true,
        ~startBlock?,
      ) :> Internal.onEventRegistration)

    // The address-free partition is the only one here, so its query is the
    // whole story.
    let fromBlockOf = (~knownHeight, ~endBlock=None, onEventRegistrations) => {
      let (fetchState, _) = makeFs(
        ~onEventRegistrations,
        ~addresses=[],
        ~startBlock=0,
        ~endBlock,
        ~maxAddrInPartition=10,
        ~maxOnBlockBufferSize=10,
        ~chainId,
        ~knownHeight,
      )
      switch fetchState->FetchState.getNextQuery(
        ~chainTargetBlock=knownHeight,
        ~chainTargetItems=10_000.,
      ) {
      | Ready(queries) => queries->Array.map(q => q.fromBlock)
      | WaitingForNewBlock => ["WaitingForNewBlock"]->Obj.magic
      | NothingToQuery => ["NothingToQuery"]->Obj.magic
      }
    }

    t.expect({
      // Nothing below 500 can match, and the head is past it, so the scan
      // starts there instead of at the chain start.
      "restricted": fromBlockOf(~knownHeight=1000, [makeWildcard(~id="a", ~startBlock=500)]),
      // The earliest of several still bounds the skip.
      "twoRestricted": fromBlockOf(
        ~knownHeight=1000,
        [makeWildcard(~id="a", ~startBlock=900), makeWildcard(~id="b", ~startBlock=500)],
      ),
      // An unrestricted sibling can fire from the chain start, so nothing is
      // skipped.
      "mixed": fromBlockOf(
        ~knownHeight=1000,
        [makeWildcard(~id="a", ~startBlock=500), makeWildcard(~id="b")],
      ),
      // Start block past the head: skipping there would leave the partition
      // with no query at all, so it fetches as before until the chain catches
      // up. Same when the chain's endBlock is below it.
      "beyondHead": fromBlockOf(~knownHeight=100, [makeWildcard(~id="a", ~startBlock=500)]),
      "beyondEndBlock": fromBlockOf(
        ~knownHeight=1000,
        ~endBlock=Some(200),
        [makeWildcard(~id="a", ~startBlock=500)],
      ),
    }).toEqual({
      "restricted": [500],
      "twoRestricted": [500],
      "mixed": [0],
      "beyondHead": [0],
      "beyondEndBlock": [0],
    })
  })

  it("Narrows a query's selection to the registrations its range can match", t => {
    let makeReg = (~id, ~startBlock=?) =>
      (MockIndexer.evmOnEventRegistration(
        ~id,
        ~contractName="Gravatar",
        ~isWildcard=true,
        ~startBlock?,
      ) :> Internal.onEventRegistration)
    let open_ = makeReg(~id="open")
    let restricted = makeReg(~id="restricted", ~startBlock=100)
    let selection: FetchState.selection = {
      dependsOnAddresses: false,
      onEventRegistrations: [open_, restricted],
    }
    let registrationIds = (selection: FetchState.selection) =>
      selection.onEventRegistrations->Array.map(reg => reg.eventConfig.id)

    t.expect({
      // Whole range sits below the restricted registration's start block.
      "below": (selection->FetchState.narrowSelectionToRange(~toBlock=Some(99)))->registrationIds,
      // The range reaches it, so its logs are worth asking for.
      "reaches": (selection->FetchState.narrowSelectionToRange(~toBlock=Some(100)))->registrationIds,
      // Open-ended queries can't exclude anything.
      "openEnded": (selection->FetchState.narrowSelectionToRange(~toBlock=None))->registrationIds,
      // Narrowing to nothing would leave a query no source can build, so the
      // selection stands as-is.
      "allBelow": ({
        FetchState.dependsOnAddresses: false,
        onEventRegistrations: [restricted],
      }->FetchState.narrowSelectionToRange(~toBlock=Some(99)))->registrationIds,
    }).toEqual({
      "below": ["open"],
      "reaches": ["open", "restricted"],
      "openEnded": ["open", "restricted"],
      "allBelow": ["restricted"],
    })
  })

  it("Wildcard partition never merges to another one", t => {
    let wildcard = (MockIndexer.evmOnEventRegistration(
      ~id="wildcard",
      ~contractName="ContractA",
      ~isWildcard=true,
    ) :> Internal.onEventRegistration)
    let (fetchState, addressStore) = makeFs(
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
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)->dcToRegistration,
      ])

    t.expect(fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count).toEqual(3)

    let nextQuery =
      {...fetchState, knownHeight: 10}->FetchState.getNextQuery(
        ~chainTargetBlock=10,
        ~chainTargetItems=10_000.,
      )

    t.expect((nextQuery)->TestAddresses.nextQuery,
      ~message=`Wildcard partition "0" is untouched.
      Partitions "1" and "2" split in optimized way for further dynamic contract registrations.
      All queries performed in parallel without locking.`,
    ).toEqual((Ready([
        {
          partitionId: "0",
          itemsTarget: Some(3333),
          itemsEst: 3333,
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          selection: {
            dependsOnAddresses: false,
            onEventRegistrations: [wildcard],
          },
          addresses: TestAddresses.setOf([]),
        },
        {
          partitionId: "1",
          itemsTarget: Some(3333),
          itemsEst: 3333,
          fromBlock: 0,
          toBlock: None,
          isChunk: false,
          selection: fetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress1]),
        },
        {
          partitionId: "2",
          // Starts at block 2, so 9 of the 11-block range to the target -> 2727.
          itemsTarget: Some(2727),
          itemsEst: 2727,
          fromBlock: 2,
          toBlock: None,
          isChunk: false,
          selection: fetchState.normalSelection,
          addresses: TestAddresses.setOf([mockAddress2]),
        },
      ]))->TestAddresses.nextQuery)
  })

  it("Correctly rollbacks fetch state", t => {
    let addressStore = makeIntermidiateIndex()
    let fetchState = makeIntermidiateDcMerge(~addressStore)

    // Rollback to block 2: both DCs survive (regBlock <= 2)
    // Partition "0" (lfb=10 > 2) -> DELETED, addresses recreated as partition "1"
    // Partition "2" (lfb=2 <= 2) -> KEPT as partition "0" (IDs reset)
    let fetchStateAfterRollback1 = fetchState->FetchState.rollback(~addressStore, ~targetBlockNumber=2)
    t.expect((fetchStateAfterRollback1)->TestAddresses.fetchState,
      ~message=`Rollbacks partitions: kept "0", recreated "1" from deleted`,
    ).toEqual(({
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
            sourceRangeCapacity: 0,
            // Kept partition preserves its observed empty-response density.
            eventDensity: Some(0.),
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: fetchState.normalSelection,
            addresses: TestAddresses.setOf(~contractName="Gravatar", [mockAddress3]),
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
            sourceRangeCapacity: 0,
            eventDensity: None,
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: fetchState.normalSelection,
            addresses: TestAddresses.setOf([mockAddress0, mockAddress1, mockAddress2]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=2,
        ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
        ~clientFilteredContracts=fetchState.optimizedPartitions.clientFilteredContracts,
      ),
    })->TestAddresses.fetchState)

    // Rollback to block 1: dc2 and dc3 removed (regBlock=2 > 1)
    // Both partitions deleted (lfb > 1), surviving addresses [addr0, addr1] recreated
    let fetchStateAfterRollback2 = fetchState->FetchState.rollback(~addressStore, ~targetBlockNumber=1)
    t.expect((fetchStateAfterRollback2)->TestAddresses.fetchState,
      ~message=`Both partitions deleted, surviving addresses recreated as partition "0"`,
    ).toEqual(({
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
            sourceRangeCapacity: 0,
            eventDensity: None,
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: fetchState.normalSelection,
            // Removed dc2 and dc3, even though the latestFetchedBlock is not exceeding the lastScannedBlock
            addresses: TestAddresses.setOf([mockAddress0, mockAddress1]),
            mergeBlock: None,
          },
          // Removed partition "2"
        ],
        ~nextPartitionIndex=1,
        ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
        ~clientFilteredContracts=fetchState.optimizedPartitions.clientFilteredContracts,
      ),
      // Removed an item here

      buffer: [mockEvent(~blockNumber=1)],
    })->TestAddresses.fetchState)

    // Rollback to block -1: all DCs removed, only static addr0 survives
    let fetchStateAfterRollback3 = fetchState->FetchState.rollback(~addressStore, ~targetBlockNumber=-1)
    t.expect((fetchStateAfterRollback3)->TestAddresses.fetchState,
      ~message=`All DCs removed, only static addr0 recreated as partition "0"`,
    ).toEqual(({
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
            sourceRangeCapacity: 0,
            eventDensity: None,
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: fetchState.normalSelection,
            addresses: TestAddresses.setOf([mockAddress0]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=1,
        ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
        ~clientFilteredContracts=fetchState.optimizedPartitions.clientFilteredContracts,
      ),
      buffer: [],
    })->TestAddresses.fetchState)
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
    let (fetchState, addressStore) = makeFs(
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
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=2, ~contractAddress=mockAddress2)->dcToRegistration,
      ])

    // Additionally test that state being reset
    fetchState->FetchState.startFetchingQueries(
      ~queries=[
        {
          partitionId: "0",
          itemsTarget: Some(5000),
          itemsEst: 5000,
          toBlock: None,
          selection: {
            dependsOnAddresses: false,
            onEventRegistrations: wildcardEventConfigs,
          },
          addresses: TestAddresses.setOf([]),
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
    let fetchStateAfterRollback = fetchStateReset->FetchState.rollback(~addressStore, ~targetBlockNumber=1)

    t.expect((fetchStateAfterRollback)->TestAddresses.fetchState,
      ~message=`Should keep Wildcard partition even if it's empty`,
    ).toEqual(({
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
            sourceRangeCapacity: 0,
            eventDensity: None,
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: {
              dependsOnAddresses: false,
              onEventRegistrations: wildcardEventConfigs,
            },
            addresses: TestAddresses.setOf([]),
            mergeBlock: None,
          },
        ],
        // IDs reset on rollback
        ~nextPartitionIndex=1,
        ~maxAddrInPartition=fetchState.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=fetchState.optimizedPartitions.dynamicContracts,
        ~clientFilteredContracts=fetchState.optimizedPartitions.clientFilteredContracts,
      ),
      buffer: [],
    })->TestAddresses.fetchState)
  })
})

describe("FetchState unit tests for specific cases", () => {
  it("Should merge events in correct order on merging", t => {
    let (base, _) = makeInitial()
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
            sourceRangeCapacity: 0,
            eventDensity: None,
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: normalSelection,
            addresses: TestAddresses.setOf([]),
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
            sourceRangeCapacity: 0,
            eventDensity: None,
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: normalSelection,
            addresses: TestAddresses.setOf([]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=2,
        ~maxAddrInPartition=base.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=base.optimizedPartitions.dynamicContracts,
        ~clientFilteredContracts=base.optimizedPartitions.clientFilteredContracts,
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
      itemsTarget: Some(5000),
      itemsEst: 5000,
      fromBlock: 1,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([]),
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState = fetchState->FetchState.handleQueryResult(
      ~query,
      ~latestFetchedBlock={
        blockNumber: 10,
        blockTimestamp: 10,
      },
      ~newItems=[
        mockEvent(~blockNumber=4, ~logIndex=1, ~registrationIndex=0),
        mockEvent(~blockNumber=4, ~logIndex=1, ~registrationIndex=1),
      ],
    )

    t.expect(updatedFetchState.buffer, ~message="Should merge events in correct order").toEqual(([
      mockEvent(~blockNumber=1),
      mockEvent(~blockNumber=2),
      mockEvent(~blockNumber=3),
      mockEvent(~blockNumber=4),
      mockEvent(~blockNumber=4, ~logIndex=1, ~registrationIndex=0),
      mockEvent(~blockNumber=4, ~logIndex=1, ~registrationIndex=1),
      mockEvent(~blockNumber=4, ~logIndex=2),
    ]))
  })

  it("Sorts newItems when source returns them unsorted", t => {
    let (base, _) = makeInitial()
    let fetchState = base

    let unsorted = [
      mockEvent(~blockNumber=5, ~logIndex=1),
      mockEvent(~blockNumber=6, ~logIndex=0),
      mockEvent(~blockNumber=6, ~logIndex=2),
      mockEvent(~blockNumber=5, ~logIndex=0),
    ]

    let query: FetchState.query = {
      partitionId: "0",
      itemsTarget: Some(5000),
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([]),
    }

    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock=getBlockData(~blockNumber=10),
        ~newItems=unsorted,
      )

    t.expect(updatedFetchState.buffer,
      ~message="Queue must be sorted DESC by (blockNumber, logIndex) regardless of input order",
    ).toEqual(([
      mockEvent(~blockNumber=5, ~logIndex=0),
      mockEvent(~blockNumber=5, ~logIndex=1),
      mockEvent(~blockNumber=6, ~logIndex=0),
      mockEvent(~blockNumber=6, ~logIndex=2),
    ]))
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
    let (fetchState, _) = makeFs(
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
      partitionId: "0",
      itemsTarget: Some(5000),
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: {
        dependsOnAddresses: false,
        onEventRegistrations: [wildcard],
      },
      addresses: TestAddresses.setOf([]),
    }
    let query1: FetchState.query = {
      partitionId: "1",
      itemsTarget: Some(5000),
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([]),
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

    t.expect(({...fetchState, knownHeight: 2}->FetchState.getNextQuery(
        ~chainTargetBlock=2,
        ~chainTargetItems=10_000.,
      ))->TestAddresses.nextQuery,
      ~message=`Should be possible to query wildcard partition,
      if it didn't reach max queue size limit`,
    ).toEqual((Ready([
        {
          partitionId: "0",
          itemsTarget: Some(10000),
          itemsEst: 10000,
          fromBlock: 2,
          toBlock: None,
          isChunk: false,
          selection: {
            dependsOnAddresses: false,
            onEventRegistrations: [wildcard],
          },
          addresses: TestAddresses.setOf([]),
        },
      ]))->TestAddresses.nextQuery)
  })

  it("Allows to get event one block earlier than the dc registring event", t => {
    let (fetchState, addressStore) = makeInitial(~knownHeight=10)

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
      itemsTarget: Some(5000),
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([]),
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
      fetchStateWithEvents->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(
          ~contractAddress=mockAddress1,
          ~blockNumber=registeringBlockNumber,
        )->dcToRegistration,
      ])

    t.expect(
      fetchStateWithDc->getEarliestEvent->getItem,
      ~message=`Should allow to get event before the dc registration`,
    ).toEqual(Some(mockEvent(~blockNumber=2, ~logIndex=1)))
  })

  it("Returns NoItem when there is an empty partition at block 0", t => {
    let (fetchState, _) = makeFs(
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
      partitionId: "0",
      itemsTarget: Some(5000),
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([]),
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
    let (base, addressStore) = makeInitial()
    let normalSelection = base.normalSelection
    let fetchState = base->FetchState.updateInternal(
      ~optimizedPartitions=FetchState.OptimizedPartitions.make(
        ~partitions=[
          {
            id: "0",
            latestFetchedBlock,
            dynamicContract: None,
            mutPendingQueries: [],
            sourceRangeCapacity: 0,
            eventDensity: None,
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: normalSelection,
            addresses: TestAddresses.setOf([]),
            mergeBlock: None,
          },
          {
            id: "1",
            latestFetchedBlock,
            dynamicContract: None,
            mutPendingQueries: [],
            sourceRangeCapacity: 0,
            eventDensity: None,
            prevSourceRangeCapacity: 0,
            latestSourceRangeCapacityUpdateBlock: 0,
            selection: normalSelection,
            addresses: TestAddresses.setOf([]),
            mergeBlock: None,
          },
        ],
        ~nextPartitionIndex=2,
        ~maxAddrInPartition=base.optimizedPartitions.maxAddrInPartition,
        ~dynamicContracts=base.optimizedPartitions.dynamicContracts,
        ~clientFilteredContracts=base.optimizedPartitions.clientFilteredContracts,
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
      ->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~contractAddress=mockAddress1, ~blockNumber=2)->dcToRegistration,
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
    let fetchState = {
      ...makeInitialFs(),
      endBlock: Some(0),
    }
    let query: FetchState.query = {
      partitionId: "0",
      itemsTarget: Some(5000),
      itemsEst: 5000,
      fromBlock: 0,
      toBlock: Some(0),
      isChunk: false,
      selection: makeInitialFs().normalSelection,
      addresses: TestAddresses.setOf([]),
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

  it("isFetchingAtHead", t => {
    let fetchToHead = (fetchState: FetchState.t, ~latestFetchedBlockNumber) => {
      let query: FetchState.query = {
        partitionId: "0",
        itemsTarget: Some(5000),
        itemsEst: 5000,
        fromBlock: 0,
        toBlock: None,
        isChunk: false,
        selection: fetchState.normalSelection,
        addresses: TestAddresses.setOf([]),
      }
      fetchState->FetchState.startFetchingQueries(~queries=[query])
      fetchState->FetchState.handleQueryResult(
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

      let (fetchState, addressStore) = makeFs(
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
        partitionId: "0",
        itemsTarget: Some(5000),
        itemsEst: 5000,
        selection: fetchState.normalSelection,
        addresses: TestAddresses.setOf([mockAddress1]),
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
      let fetchStateWithDcA = fetchState->FetchState.registerDynamicContracts(~addressStore, [dcA->dcToRegistration])

      let queries = switch fetchStateWithDcA->FetchState.getNextQuery(
        ~chainTargetBlock=knownHeight,
        ~chainTargetItems=10_000.,
      ) {
      | Ready(queries) => queries
      | _ => JsError.throwWithMessage("Expected Ready queries")
      }

      t.expect(queries->TestAddresses.queries).toEqual(([
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
      ]->TestAddresses.queries))

      let queryA = queries->Array.getUnsafe(0)

      // Emulate that we started fetching the first query
      fetchStateWithDcA->FetchState.startFetchingQueries(~queries=[queryA])

      //Next registration happens at block 200, between the first register and the upperbound of it's query
      let dc3 = makeDynContractRegistration(~contractAddress=mockAddress3, ~blockNumber=200)
      let fetchStateWithDcB =
        fetchStateWithDcA->FetchState.registerDynamicContracts(~addressStore, [dc3->dcToRegistration])

      let queries = switch fetchStateWithDcB->FetchState.getNextQuery(
        ~chainTargetBlock=knownHeight,
        ~chainTargetItems=10_000.,
      ) {
      | Ready(queries) => queries
      | _ => JsError.throwWithMessage("Expected Ready queries")
      }
      let partition2Query = {
        ...queries->Array.getUnsafe(0),
        addresses: TestAddresses.setOf([mockAddress3]),
        partitionId: "2",
        toBlock: None, // Didn't merge because reached max addresses in partition
        fromBlock: 200,
      }
      t.expect((fetchStateWithDcB->FetchState.getNextQuery(~chainTargetBlock=knownHeight, ~chainTargetItems=10_000.))->TestAddresses.nextQuery,
        ~message=`Create a new partition for the newly registered contract`,
      ).toEqual((Ready([partition2Query, queries->Array.getUnsafe(1)]))->TestAddresses.nextQuery)

      //Response with updated fetch state
      let fetchStateWithBothDcsAndQueryAResponse =
        fetchStateWithDcB->FetchState.handleQueryResult(
          ~query=queryA,
          ~latestFetchedBlock=getBlockData(~blockNumber=400),
          ~newItems=[],
        )

      t.expect((fetchStateWithBothDcsAndQueryAResponse->FetchState.getNextQuery(
          ~chainTargetBlock=knownHeight,
          ~chainTargetItems=10_000.,
        ))->TestAddresses.nextQuery,
        ~message=`We don't merge partition 2 to partition 1, since it already has end block`,
      ).toEqual((Ready([
          {
            // Partition "1" is back in range now that its query resolved, so
            // the even split is now 3-way instead of 2-way.
            ...partition2Query,
            itemsTarget: Some(3333),
            itemsEst: 3333,
          },
          {
            // Partition responded with no items, so it still has only one
            // response (not two) — density isn't trusted yet, so it probes. It
            // starts further ahead (block 401) than partition "2", so it covers
            // less of the range to the target and gets a smaller probe.
            ...queryA,
            partitionId: "1",
            itemsTarget: Some(1663),
            itemsEst: 1663,
            toBlock: Some(500),
            fromBlock: 401,
          },
          {
            // Partition "0" starts even further ahead (block 501), so it covers
            // the least range and gets the smallest probe.
            ...queries->Array.getUnsafe(1),
            itemsTarget: Some(831),
            itemsEst: 831,
          },
        ]))->TestAddresses.nextQuery)
    },
  )
})

describe("FetchState.sortForBatch", () => {
  let mkQuery = (fetchState: FetchState.t) => {
    {
      FetchState.partitionId: "0",
      itemsTarget: Some(5000),
      itemsEst: 5000,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([]),
      fromBlock: 0,
    }
  }

  // Helper: create a fetch state with desired latestFetchedBlock and queue items via public API
  let makeFsWith = (~latestBlock: int, ~queueBlocks: array<int>): FetchState.t => {
    let (fs0, _) = makeInitial(~knownHeight=10)
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
    let (fetchState, _addressStore) = makeInitial()
    t.expect({...fetchState, knownHeight: 0}->FetchState.isReadyToEnterReorgThreshold(~tolerance=0)).toBe(false)
  })

  it(
    "Returns false when we just started the indexer and it has knownHeight=0, while start block is more than 0 + reorg threshold",
    t => {
      let (fetchState, _addressStore) = makeInitial(~startBlock=6000)
      t.expect({...fetchState, knownHeight: 0}->FetchState.isReadyToEnterReorgThreshold(~tolerance=0)).toBe(false)
    },
  )

  it("Returns true when endBlock is reached and queue is empty", t => {
    // latestFullyFetchedBlock = startBlock - 1 = 5, endBlock = 5
    let (fs, _addressStore) = makeFs(
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold(~tolerance=0)).toBe(true)
  })

  it("Returns false when endBlock not reached and below head - blockLag", t => {
    // latestFullyFetchedBlock = 49, endBlock = 100, head - lag = 50
    let (fs, _addressStore) = makeFs(
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold(~tolerance=0)).toBe(false)
  })

  it("Returns true when endBlock not reached but latest >= head - blockLag", t => {
    // latestFullyFetchedBlock = 49, head - lag = 49
    let (fs, _addressStore) = makeFs(
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold(~tolerance=0)).toBe(true)
  })

  it("Returns true when no endBlock and latest >= head - blockLag (boundary)", t => {
    // latestFullyFetchedBlock = 50, head - lag = 50
    let (fs, _addressStore) = makeFs(
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold(~tolerance=0)).toBe(true)
  })

  it("Returns false when no endBlock and latest < head - blockLag", t => {
    // latestFullyFetchedBlock = 49, head - lag = 50
    let (fs, _addressStore) = makeFs(
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold(~tolerance=0)).toBe(false)
  })

  it("With a tolerance, is ready within it below head - blockLag, false just beyond it", t => {
    let isReady = (~knownHeight) => {
      let (fs, _addressStore) = makeFs(
        ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
        ~addresses=[
          {
            Internal.address: mockAddress0,
            contractName: "Gravatar",
            registrationBlock: -1,
          },
        ],
        // latestFullyFetchedBlock = startBlock - 1 = 99
        ~startBlock=100,
        ~endBlock=None,
        ~maxAddrInPartition=3,
        ~maxOnBlockBufferSize=targetBufferSize,
        ~chainId,
        ~blockLag=10,
        ~knownHeight,
      )
      fs->FetchState.isReadyToEnterReorgThreshold(~tolerance=100)
    }
    // frontier 99, ready cutoff = knownHeight - blockLag - tolerance: 209 -> 99, 210 -> 100
    t.expect((isReady(~knownHeight=209), isReady(~knownHeight=210))).toEqual((true, false))
  })

  it("Does not apply the tolerance to a finite endBlock at or below the lagged head", t => {
    // endBlock 100 sits below the lagged head (150), so it is an exact target.
    // frontier 59 is within the tolerance of the lagged head (cutoff 50) but below
    // the endBlock, so entry must wait for the endBlock rather than enter early.
    let (fs, _addressStore) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
      ~addresses=[
        {
          Internal.address: mockAddress0,
          contractName: "Gravatar",
          registrationBlock: -1,
        },
      ],
      // latestFullyFetchedBlock = startBlock - 1 = 59
      ~startBlock=60,
      ~endBlock=Some(100),
      ~maxAddrInPartition=3,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~chainId,
      ~blockLag=0,
      ~knownHeight=150,
    )
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold(~tolerance=100)).toBe(false)
  })

  it("Blocks on processable items, but not on items stuck above the frontier", t => {
    // frontier (bufferBlockNumber) = 5, endBlock 5 reached.
    let readyWithItemAt = itemBlockNumber => {
      let (fs, _addressStore) = makeFs(
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
      fs
      ->FetchState.updateInternal(~mutItems=[mockEvent(~blockNumber=itemBlockNumber)])
      ->FetchState.isReadyToEnterReorgThreshold(~tolerance=0)
    }
    // A processable item (<= frontier 5) still needs draining; an item stuck
    // above the frontier (as behind a lagging partition's gap) is reorg-safe and
    // must not defer entry.
    t.expect((readyWithItemAt(5), readyWithItemAt(6))).toEqual((false, true))
  })

  it("Returns true when the queue is empty and threshold is more than current block height", t => {
    let (fs, _addressStore) = makeFs(
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
    t.expect(fs->FetchState.isReadyToEnterReorgThreshold(~tolerance=0)).toBe(true)
  })
})

describe("Dynamic contracts with start blocks", () => {
  it("Should respect dynamic contract startBlock even when registered earlier", t => {
    let (fetchState, addressStore) = makeInitial()

    // Register a dynamic contract with startBlock=200
    let dynamicContract = makeDynContractRegistration(
      ~contractAddress=mockAddress1, // Use a different address from static contracts
      ~blockNumber=200, // This is the startBlock - when indexing should actually begin
      ~contractName="Gravatar", // Use Gravatar which has event configs in makeInitial
    )

    // Register the contract at block 100 (before its startBlock)
    let _ =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [dynamicContract->dcToRegistration])

    // The contract should be registered in addressStore
    t.expect(
      addressStore->AddressStore.get(mockAddress1)->Option.isSome,
      ~message="Dynamic contract should be registered in addressStore",
    ).toBeTruthy()

    // Verify the startBlock is set correctly
    let registeredContract =
      addressStore->AddressStore.get(mockAddress1)
      ->Option.getOrThrow

    t.expect(
      registeredContract.effectiveStartBlock,
      ~message="Dynamic contract should have correct effectiveStartBlock",
    ).toBe(200)
  })

  it("Should handle dynamic contract registration with different startBlocks", t => {
    let (fetchState, addressStore) = makeInitial()

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
      fetchState->FetchState.registerDynamicContracts(~addressStore, [contract1->dcToRegistration, contract2->dcToRegistration])

    // Verify both contracts are registered with correct startBlocks
    let contract1Registered =
      addressStore->AddressStore.get(mockAddress1)
      ->Option.getOrThrow

    let contract2Registered =
      addressStore->AddressStore.get(mockAddress2)
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
    let (fs0, _) = makeInitial(~knownHeight=1000)
    let query = {
      FetchState.partitionId: "0",
      itemsTarget: Some(5000),
      itemsEst: 5000,
      toBlock: None,
      isChunk: false,
      selection: fs0.normalSelection,
      addresses: TestAddresses.setOf([]),
      fromBlock: 0,
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
      let (fetchState, addressStore) = makeInitial(~maxAddrInPartition=1, ~targetBufferSize=10)

      // Create a second partition to make sure a large buffer elsewhere doesn't
      // affect this partition's own proposal.
      let dc = makeDynContractRegistration(~blockNumber=0, ~contractAddress=mockAddress1)
      let fetchStateWithTwoPartitions =
        fetchState->FetchState.registerDynamicContracts(~addressStore, [dc->dcToRegistration])

      // Buffer 15 items (blocks 6..20), far more than targetBufferSize=10. Admission
      // against the shared budget happens in CrossChainState, not here — getNextQuery
      // proposes against the natural ceiling regardless of how full the buffer is.
      let largeQueueEvents = Array.fromInitializer(~length=15, i => mockEvent(~blockNumber=20 - i))

      let query0 = {
        FetchState.partitionId: "0",
        itemsTarget: Some(5000),
        itemsEst: 5000,
        toBlock: None,
        isChunk: false,
        selection: fetchStateWithTwoPartitions.normalSelection,
        addresses: TestAddresses.setOf([mockAddress0]),
        fromBlock: 0,
      }

      fetchStateWithTwoPartitions->FetchState.startFetchingQueries(~queries=[query0])
      let fetchStateWithLargeQueue =
        fetchStateWithTwoPartitions->FetchState.handleQueryResult(
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
        FetchState.partitionId: "0",
        itemsTarget: Some(5000),
        itemsEst: 5000,
        toBlock: None,
        isChunk: false,
        selection: fetchState.normalSelection,
        addresses: TestAddresses.setOf([mockAddress0]),
        fromBlock: 0,
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
      let (fetchState, _addressStore) = makeFs(
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

      t.expect((blockNumbers), ~message="Buffer should contain block items for blocks 0-10").toEqual(([
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
      ]))

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

describe("Stale query response should not overwrite source range capacity", () => {
  // The default configuration with ability to overwrite some values.
  // chainTargetBlock is derived from the post-update knownHeight (see the
  // other getNextQuery helper above for why).
  let getNextQuery = (fs, ~knownHeight=100000, ~chainTargetItems=10_000.) => {
    let updated = fs->FetchState.updateKnownHeight(~knownHeight)
    updated->FetchState.getNextQuery(~chainTargetBlock=updated.knownHeight, ~chainTargetItems)
  }

  it("Out-of-order parallel query responses should not degrade chunking heuristic", t => {
    let (fetchState, _) = makeInitial(~knownHeight=100000)

    // -- Query 1: uncapped query from block 0 --
    let q1 = switch fetchState->getNextQuery {
    | Ready([q]) => q
    | _ => JsError.throwWithMessage("Expected a single query")
    }
    fetchState->FetchState.startFetchingQueries(~queries=[q1])

    // Response arrives at block 500 (range = 501)
    // shouldUpdateSourceRangeCapacity: None toBlock => 500 < 100000 - 10 = true
    let fs1 =
      fetchState
      ->FetchState.updateKnownHeight(~knownHeight=100000)
      ->FetchState.handleQueryResult(
        ~query=q1,
        ~latestFetchedBlock={blockNumber: 500, blockTimestamp: 500 * 15},
        ~newItems=[mockEvent(~blockNumber=100)],
      )

    let p1 = fs1.optimizedPartitions.entities->Dict.getUnsafe("0")
    t.expect(p1.sourceRangeCapacity, ~message="First query should set sourceRangeCapacity=501").toBe(501)
    t.expect(
      p1.prevSourceRangeCapacity,
      ~message="First query prevSourceRangeCapacity should still be 0",
    ).toBe(0)
    t.expect(
      p1.latestSourceRangeCapacityUpdateBlock,
      ~message="latestSourceRangeCapacityUpdateBlock should be 500 after first query",
    ).toBe(500)
    t.expect(
      p1.eventDensity,
      ~message="First response should seed event density without blending against an empty value",
    ).toEqual(Some(1. /. 501.))

    // -- Query 2: uncapped query from block 501 --
    let q2 = switch fs1->getNextQuery {
    | Ready([q]) => q
    | _ => JsError.throwWithMessage("Expected a single query for second round")
    }
    fs1->FetchState.startFetchingQueries(~queries=[q2])

    // Response arrives at block 1000 (range = 500)
    // shouldUpdateSourceRangeCapacity: None toBlock => 1000 < 99990 = true
    let fs2 =
      fs1->FetchState.handleQueryResult(
        ~query=q2,
        ~latestFetchedBlock={blockNumber: 1000, blockTimestamp: 1000 * 15},
        ~newItems=[mockEvent(~blockNumber=600)],
      )

    let p2 = fs2.optimizedPartitions.entities->Dict.getUnsafe("0")
    t.expect(p2.sourceRangeCapacity, ~message="Second query should set sourceRangeCapacity=500").toBe(500)
    t.expect(
      p2.prevSourceRangeCapacity,
      ~message="Second query should shift prevSourceRangeCapacity=501",
    ).toBe(501)
    t.expect(p2.latestSourceRangeCapacityUpdateBlock).toBe(1000)
    t.expect(
      p2.eventDensity,
      ~message="Second response should blend the stored and observed densities 1:1",
    ).toEqual(Some((1. /. 501. +. 1. /. 500.) /. 2.))

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
    // shouldUpdateSourceRangeCapacity: 2500 > 1000
    //   (latestSourceRangeCapacityUpdateBlock) = true,
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
      (p3.sourceRangeCapacity, p3.prevSourceRangeCapacity, p3.latestSourceRangeCapacityUpdateBlock),
      ~message="Chunk B response should set sourceRangeCapacity=600, shift prevSourceRangeCapacity=500, update latestSourceRangeCapacityUpdateBlock=2500",
    ).toEqual((600, 500, 2500))

    // -- Now respond to the EARLIER chunk (A) --
    // Partial response: latestFetchedBlock=1500 < toBlock=1900
    // shouldUpdateSourceRangeCapacity: 1500 > 2500
    //   (latestSourceRangeCapacityUpdateBlock) = FALSE
    // So sourceRangeCapacity should NOT change
    let fs4 =
      fs3->FetchState.handleQueryResult(
        ~query=chunkA,
        ~latestFetchedBlock={blockNumber: 1500, blockTimestamp: 1500 * 15},
        ~newItems=[],
      )

    let p4 = fs4.optimizedPartitions.entities->Dict.getUnsafe("0")
    t.expect(
      (p4.sourceRangeCapacity, p4.prevSourceRangeCapacity, p4.latestSourceRangeCapacityUpdateBlock),
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
      addresses: TestAddresses.setOf([mockAddress0]),
      mergeBlock: None,
      dynamicContract: None,
      mutPendingQueries: [],
      sourceRangeCapacity: 10,
      prevSourceRangeCapacity: 10,
      eventDensity: Some(100.), // density = 1000 / 10 = 100 items/block
      latestSourceRangeCapacityUpdateBlock: 0,
    }
    let unknownPartition: FetchState.partition = {
      id: "unknown",
      latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
      selection: normalSelection,
      addresses: TestAddresses.setOf([mockAddress1]),
      mergeBlock: None,
      dynamicContract: None,
      mutPendingQueries: [],
      sourceRangeCapacity: 0,
      prevSourceRangeCapacity: 0,
      eventDensity: None,
      latestSourceRangeCapacityUpdateBlock: 0,
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
      ~clientFilteredContracts=Utils.Set.make(),
      ),
      startBlock: 0,
      endBlock: None,
      buffer: [],
      normalSelection,
      latestOnBlockBlockNumber: 0,
      maxOnBlockBufferSize: 10000,
      chainId,
      blockLag: 0,
      onBlockRegistrations: [],
      knownHeight: 10000,
      firstEventBlock: Some(0),
      clientFilterAddressThreshold: None,
    }
  }

  let getItemsTargetByPartition = nextQuery =>
    switch nextQuery {
    | FetchState.Ready(queries) =>
      queries->Array.map((q: FetchState.query) => (q.partitionId, q.itemsEst))
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
    addresses: TestAddresses.setOf([address]),
    mergeBlock,
    dynamicContract: None,
    mutPendingQueries: [],
    sourceRangeCapacity: 10,
    prevSourceRangeCapacity: 10,
    eventDensity: Some(10.), // density = 100 / 10 = 10 items/block
    latestSourceRangeCapacityUpdateBlock: 0,
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
      ~clientFilteredContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock: None,
    buffer: [],
    normalSelection,
    latestOnBlockBlockNumber: 0,
    maxOnBlockBufferSize: 10000,
    chainId,
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight: 100000,
    firstEventBlock: Some(0),
    clientFilterAddressThreshold: None,
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
        | Some(arr) => arr->Array.push((q.fromBlock, q.itemsEst))->ignore
        | None => byPartition->Dict.set(q.partitionId, [(q.fromBlock, q.itemsEst)])
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

  let makePartition = (
    ~id,
    ~address,
    ~knownDensity,
    ~pendingItemsTarget,
    ~latestFetchedBlock=0,
  ): FetchState.partition => {
    id,
    latestFetchedBlock: {blockNumber: latestFetchedBlock, blockTimestamp: 0},
    selection: normalSelection,
    addresses: TestAddresses.setOf([address]),
    mergeBlock: None,
    dynamicContract: None,
    mutPendingQueries: switch pendingItemsTarget {
    | Some(itemsTarget) => [
        {
          fromBlock: 1,
          toBlock: Some(100),
          isChunk: true,
          itemsTarget: None,
          itemsEst: itemsTarget,
          fetchedBlock: None,
        },
      ]
    | None => []
    },
    sourceRangeCapacity: knownDensity ? 10 : 0,
    prevSourceRangeCapacity: knownDensity ? 10 : 0,
    eventDensity: knownDensity ? Some(10.) : None, // density = 100 / 10 = 10 items/block
    latestSourceRangeCapacityUpdateBlock: 0,
  }

  let makeFetchState = (partitions): FetchState.t => {
    optimizedPartitions: FetchState.OptimizedPartitions.make(
      ~partitions,
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=2,
      ~dynamicContracts=Utils.Set.make(),
      ~clientFilteredContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock: None,
    buffer: [],
    normalSelection,
    latestOnBlockBlockNumber: 0,
    maxOnBlockBufferSize: 10000,
    chainId,
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight: 10000,
    firstEventBlock: Some(0),
    clientFilterAddressThreshold: None,
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
        | Some(arr) => arr->Array.push((q.fromBlock, q.itemsEst))->ignore
        | None => byPartition->Dict.set(q.partitionId, [(q.fromBlock, q.itemsEst)])
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
      t.expect((fetchState->FetchState.getNextQuery(~chainTargetBlock=10000, ~chainTargetItems=2000.))->TestAddresses.nextQuery,
      ).toEqual((FetchState.Ready([
          {
            partitionId: "0",
            fromBlock: 1,
            toBlock: None,
            isChunk: false,
            itemsTarget: Some(250),
            itemsEst: 250,
            selection: normalSelection,
            addresses: TestAddresses.setOf([mockAddress0]),
          },
          {
            partitionId: "1",
            fromBlock: 101,
            toBlock: Some(118),
            isChunk: true,
            itemsTarget: None,
            itemsEst: 180,
            selection: normalSelection,
            addresses: TestAddresses.setOf([mockAddress1]),
          },
          {
            partitionId: "1",
            fromBlock: 119,
            toBlock: Some(136),
            isChunk: true,
            itemsTarget: None,
            itemsEst: 180,
            selection: normalSelection,
            addresses: TestAddresses.setOf([mockAddress1]),
          },
        ]))->TestAddresses.nextQuery)
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
      itemsTarget: Some(100),
      itemsEst: 100,
      selection: normalSelection,
      addresses: TestAddresses.setOf([address]),
    }
    t.expect((fetchState->FetchState.getNextQuery(~chainTargetBlock=10000, ~chainTargetItems=300.))->TestAddresses.nextQuery,
    ).toEqual((FetchState.Ready([
        makeProbe(~id="0", ~address=mockAddress0),
        makeProbe(~id="1", ~address=mockAddress1),
        makeProbe(~id="2", ~address=mockAddress2),
      ]))->TestAddresses.nextQuery)
  })

  it("scales each open-ended probe by how much of the range to the target it still covers", t => {
    let fetchState = makeFetchState([
      // Frontier partition: covers the whole range to the target.
      makePartition(~id="0", ~address=mockAddress0, ~knownDensity=false, ~pendingItemsTarget=None),
      // Sits at block 50, so it covers only half the range and gets half as much.
      makePartition(
        ~id="1",
        ~address=mockAddress1,
        ~knownDensity=false,
        ~pendingItemsTarget=None,
        ~latestFetchedBlock=50,
      ),
    ])

    // rangeToTarget = 100 - 0 = 100, rangeTargetDensity = 1000 / 100 = 10.
    // Probe "0" (from block 1): 10 × (100 - 1 + 1) / 2 = 500.
    // Probe "1" (from block 51): 10 × (100 - 51 + 1) / 2 = 250.
    t.expect((fetchState->FetchState.getNextQuery(~chainTargetBlock=100, ~chainTargetItems=1000.))->TestAddresses.nextQuery,
    ).toEqual((FetchState.Ready([
        {
          partitionId: "0",
          fromBlock: 1,
          toBlock: None,
          isChunk: false,
          itemsTarget: Some(500),
          itemsEst: 500,
          selection: normalSelection,
          addresses: TestAddresses.setOf([mockAddress0]),
        },
        {
          partitionId: "1",
          fromBlock: 51,
          toBlock: None,
          isChunk: false,
          itemsTarget: Some(250),
          itemsEst: 250,
          selection: normalSelection,
          addresses: TestAddresses.setOf([mockAddress1]),
        },
      ]))->TestAddresses.nextQuery)
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
    addresses: TestAddresses.setOf([mockAddress0]),
    mergeBlock,
    dynamicContract: None,
    mutPendingQueries,
    sourceRangeCapacity: knownDensity ? 10 : 0,
    prevSourceRangeCapacity: knownDensity ? 10 : 0,
    eventDensity: knownDensity ? Some(10.) : None, // density = 100 / 10 = 10 items/block
    latestSourceRangeCapacityUpdateBlock: 0,
  }

  let makeFetchState = (partition): FetchState.t => {
    optimizedPartitions: FetchState.OptimizedPartitions.make(
      ~partitions=[partition],
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=1,
      ~dynamicContracts=Utils.Set.make(),
      ~clientFilteredContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock: None,
    buffer: [],
    normalSelection,
    latestOnBlockBlockNumber: partition.latestFetchedBlock.blockNumber,
    maxOnBlockBufferSize: 10000,
    chainId,
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight: 10000,
    firstEventBlock: Some(0),
    clientFilterAddressThreshold: None,
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
            {fromBlock: 200, toBlock: Some(219), isChunk: true, itemsTarget: None, itemsEst: 100, fetchedBlock: None},
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

  it("fills a gap behind a returned-but-unconsumed query even when its reservation would exhaust the budget", t => {
    // Chunk [101, 200] already returned (fetchedBlock set) but is stuck behind
    // the [51, 100] hole, so it lingers in mutPendingQueries. Its reservation
    // was released on return, so counting it against the budget would starve the
    // very gap-fill that lets it be consumed — a deadlock. itemsEst 1500 exceeds
    // chainTargetItems 1000, so the old up-front subtraction zeroed the budget
    // and dropped the gap; the fromBlock-ordered acceptance funds it instead.
    let fetchState = makeFetchState(
      makePartition(
        ~latestFetchedBlock=50,
        ~knownDensity=false,
        ~mutPendingQueries=[
          {
            fromBlock: 101,
            toBlock: Some(200),
            isChunk: true,
            itemsTarget: None,
            itemsEst: 1500,
            fetchedBlock: Some({blockNumber: 200, blockTimestamp: 0}),
          },
        ],
      ),
    )
    let emitted = switch fetchState->FetchState.getNextQuery(
      ~chainTargetBlock=100,
      ~chainTargetItems=1000.,
    ) {
    | Ready(queries) => queries->Array.map((q: FetchState.query) => (q.fromBlock, q.toBlock))
    | NothingToQuery => []
    | WaitingForNewBlock => [(-1, None)]
    }
    t.expect(emitted).toEqual([(51, Some(100))])
  })
})

describe("FetchState.getNextQuery chunk headroom and budget-driven emit", () => {
  // Single partition with density 10 items/block and chunk history 10 ->
  // chunkSize = ceil(10 * 1.8) = 18, so a chunk costs 180 items at multiplier
  // 1, 270 at the 1.5x backfill headroom, 540 at the 3x realtime headroom.
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}

  let makeFetchState = (~eventDensity=Some(10.)): FetchState.t => {
    optimizedPartitions: FetchState.OptimizedPartitions.make(
      ~partitions=[
        {
          id: "0",
          latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
          selection: normalSelection,
          addresses: TestAddresses.setOf([mockAddress0]),
          mergeBlock: None,
          dynamicContract: None,
          mutPendingQueries: [],
          sourceRangeCapacity: 10,
          prevSourceRangeCapacity: 10,
          eventDensity, // density = 100 / 10 = 10 items/block by default
          latestSourceRangeCapacityUpdateBlock: 0,
        },
      ],
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=1,
      ~dynamicContracts=Utils.Set.make(),
      ~clientFilteredContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock: None,
    buffer: [],
    normalSelection,
    latestOnBlockBlockNumber: 0,
    maxOnBlockBufferSize: 10000,
    chainId,
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight: 100000,
    firstEventBlock: Some(0),
    clientFilterAddressThreshold: None,
  }

  let getChunks = (fetchState: FetchState.t, ~chainTargetItems) =>
    switch fetchState->FetchState.getNextQuery(
      ~chainTargetBlock=100000,
      ~chainTargetItems,
    ) {
    | Ready(queries) => queries->Array.map((q: FetchState.query) => (q.fromBlock, q.itemsEst))
    | _ => []
    }

  it("chunk queries carry no server cap (itemsTarget: None)", t => {
    let chunkCaps = switch makeFetchState()->FetchState.getNextQuery(
      ~chainTargetBlock=100000,
      ~chainTargetItems=270.,
    ) {
    | Ready(queries) => queries->Array.map((q: FetchState.query) => (q.fromBlock, q.itemsTarget))
    | _ => []
    }
    // A chunk is bounded by its toBlock, so it sends no server-side item cap.
    t.expect(chunkCaps).toEqual([(1, None), (19, None)])
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

  it("bounded chunks send no cap while the open-ended probe keeps its budget-share cap", t => {
    let getCaps = (fetchState: FetchState.t, ~chainTargetItems) =>
      switch fetchState->FetchState.getNextQuery(
        ~chainTargetBlock=100000,
        ~chainTargetItems,
      ) {
      | Ready(queries) => queries->Array.map((q: FetchState.query) => (q.fromBlock, q.itemsTarget))
      | _ => []
      }
    t.expect({
      "boundedChunks": makeFetchState()->getCaps(~chainTargetItems=400.),
      "openProbe": makeFetchState(~eventDensity=None)->getCaps(~chainTargetItems=50.),
    }).toEqual({
      // A chunk's range is already the hard bound on its response, so it carries
      // no server-side item cap.
      "boundedChunks": [(1, None), (19, None), (37, None)],
      // The open-ended probe's cap is its only response bound, so it keeps its
      // budget-share size.
      "openProbe": [(1, Some(50))],
    })
  })
})

describe("Response density and source range capacity update independently", () => {
  // Source range capacity 300 with a bounded query truncated at block 90: for a
  // non-chunk query the truncation may be our own itemsTarget cap, which says
  // nothing about server capacity, so the 300 history must survive. Bounded
  // chunks send no cap, so their partial responses are always genuine capacity
  // evidence. Either way the items/block ratio is current density evidence,
  // blended 1:1 with the stored density.
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}
  let addresses = TestAddresses.setOf([mockAddress0])

  let makeFetchState = (~eventDensity=Some(1.), ~sourceRangeCapacity=300): FetchState.t => {
    optimizedPartitions: FetchState.OptimizedPartitions.make(
      ~partitions=[
        {
          id: "0",
          latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
          selection: normalSelection,
          addresses,
          mergeBlock: None,
          dynamicContract: None,
          mutPendingQueries: [],
          sourceRangeCapacity,
          prevSourceRangeCapacity: sourceRangeCapacity,
          eventDensity,
          latestSourceRangeCapacityUpdateBlock: 0,
        },
      ],
      ~maxAddrInPartition=2,
      ~nextPartitionIndex=1,
      ~dynamicContracts=Utils.Set.make(),
      ~clientFilteredContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock: None,
    buffer: [],
    normalSelection,
    latestOnBlockBlockNumber: 0,
    maxOnBlockBufferSize: 10000,
    chainId,
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight: 100000,
    firstEventBlock: Some(0),
    clientFilterAddressThreshold: None,
  }

  let makeQuery = (~isChunk): FetchState.query => {
    partitionId: "0",
    fromBlock: 1,
    toBlock: Some(540),
    isChunk,
    itemsTarget: isChunk ? None : Some(3),
    itemsEst: 3,
    selection: normalSelection,
    addresses,
  }
  let chunkQuery = makeQuery(~isChunk=true)

  let runPartialResponse = (~itemsCount, ~eventDensity=Some(1.), ~isChunk=true) => {
    let query = makeQuery(~isChunk)
    let fetchState = makeFetchState(~eventDensity)
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updated =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock={blockNumber: 90, blockTimestamp: 90 * 15},
        ~newItems=Array.fromInitializer(~length=itemsCount, i =>
          mockEvent(~blockNumber=10, ~logIndex=i)
        ),
      )
    let p = updated.optimizedPartitions.entities->Dict.getUnsafe("0")
    (p->FetchState.getMinHistoryRange, p.eventDensity)
  }

  it("updates density on every response but preserves capacity on a cap hit", t => {
    // A non-chunk bounded query still sends its itemsTarget cap, so a response
    // hitting it (itemsCount == itemsTarget) preserves the 300 capacity history.
    t.expect({
      "capHit": runPartialResponse(~itemsCount=3, ~isChunk=false),
      "subCap": runPartialResponse(~itemsCount=2, ~isChunk=false),
    }).toEqual({
      "capHit": (Some(300), Some((1. +. 3. /. 90.) /. 2.)),
      "subCap": (Some(90), Some((1. +. 2. /. 90.) /. 2.)),
    })
  })

  it("trusts a bounded chunk's partial response as capacity — it sends no cap", t => {
    // Bounded chunks carry no server cap, so a partial response is genuine
    // capacity evidence even when itemsCount reaches what a cap would have been.
    t.expect(runPartialResponse(~itemsCount=3, ~isChunk=true)).toEqual((
      Some(90),
      Some((1. +. 3. /. 90.) /. 2.),
    ))
  })

  it("trusts cap-hit density before source capacity is known", t => {
    let fetchState = makeFetchState(~eventDensity=None, ~sourceRangeCapacity=0)
    fetchState->FetchState.startFetchingQueries(~queries=[chunkQuery])
    let updated =
      fetchState->FetchState.handleQueryResult(
        ~query=chunkQuery,
        ~latestFetchedBlock={blockNumber: 90, blockTimestamp: 90 * 15},
        ~newItems=Array.fromInitializer(~length=3, i =>
          mockEvent(~blockNumber=10, ~logIndex=i)
        ),
      )
    let p = updated.optimizedPartitions.entities->Dict.getUnsafe("0")

    t.expect((p->FetchState.getMinHistoryRange, p->FetchState.getTrustedDensity)).toEqual((
      None,
      Some(3. /. 90.),
    ))
  })

  it("seeds the first observation and keeps zero as a real sample", t => {
    t.expect({
      "seedZero": runPartialResponse(~itemsCount=0, ~eventDensity=None),
      "blendFromZero": runPartialResponse(~itemsCount=2, ~eventDensity=Some(0.)),
    }).toEqual({
      "seedZero": (Some(90), Some(0.)),
      "blendFromZero": (Some(90), Some(1. /. 90.)),
    })
  })
})

describe("mergeIntoBuffer", () => {
  it("merges an unsorted response into the sorted buffer and drops duplicates", t => {
    let buffer = [mockEvent(~blockNumber=1), mockEvent(~blockNumber=3), mockEvent(~blockNumber=5)]
    let newItems = [
      mockEvent(~blockNumber=4),
      mockEvent(~blockNumber=2),
      mockEvent(~blockNumber=3), // duplicate of the buffer's block 3
      mockEvent(~blockNumber=4), // duplicate within the response
    ]
    t.expect((buffer->FetchState.mergeIntoBuffer(newItems))).toEqual(([
      mockEvent(~blockNumber=1),
      mockEvent(~blockNumber=2),
      mockEvent(~blockNumber=3),
      mockEvent(~blockNumber=4),
      mockEvent(~blockNumber=5),
    ]))
  })

  it("keeps two registrations for one log (equal block+logIndex, distinct index)", t => {
    let newItems = [
      mockEvent(~blockNumber=7, ~logIndex=2, ~registrationIndex=1),
      mockEvent(~blockNumber=7, ~logIndex=2, ~registrationIndex=0),
    ]
    t.expect(([]->FetchState.mergeIntoBuffer(newItems))).toEqual(([
      mockEvent(~blockNumber=7, ~logIndex=2, ~registrationIndex=0),
      mockEvent(~blockNumber=7, ~logIndex=2, ~registrationIndex=1),
    ]))
  })
})

describe("FetchState.getNextQuery caps per-chain concurrency", () => {
  let normalSelection = {FetchState.dependsOnAddresses: false, onEventRegistrations: []}
  let addresses = TestAddresses.setOf([mockAddress0])

  let makePartition = (~idx, ~inFlight): FetchState.partition => {
    id: idx->Int.toString,
    latestFetchedBlock: {blockNumber: 0, blockTimestamp: 0},
    selection: normalSelection,
    addresses,
    mergeBlock: None,
    dynamicContract: None,
    mutPendingQueries: inFlight
      ? [
          {
            fromBlock: 1,
            toBlock: None,
            isChunk: false,
            itemsTarget: Some(1),
            itemsEst: 1,
            fetchedBlock: None,
          },
        ]
      : [],
    sourceRangeCapacity: 0,
    prevSourceRangeCapacity: 0,
    eventDensity: None,
    latestSourceRangeCapacityUpdateBlock: 0,
  }

  let makeFetchState = (~partitionsCount, ~inFlightCount): FetchState.t => {
    optimizedPartitions: FetchState.OptimizedPartitions.make(
      ~partitions=Array.fromInitializer(~length=partitionsCount, idx =>
        makePartition(~idx, ~inFlight=idx < inFlightCount)
      ),
      ~maxAddrInPartition=1,
      ~nextPartitionIndex=partitionsCount,
      ~dynamicContracts=Utils.Set.make(),
      ~clientFilteredContracts=Utils.Set.make(),
    ),
    startBlock: 0,
    endBlock: None,
    buffer: [],
    normalSelection,
    latestOnBlockBlockNumber: 0,
    maxOnBlockBufferSize: 10000,
    chainId,
    blockLag: 0,
    onBlockRegistrations: [],
    knownHeight: 100000,
    firstEventBlock: Some(0),
    clientFilterAddressThreshold: None,
  }

  let countQueries = (fetchState: FetchState.t) =>
    switch fetchState->FetchState.getNextQuery(
      ~chainTargetBlock=100000,
      ~chainTargetItems=1_000_000.,
    ) {
    | Ready(queries) => queries->Array.length
    | _ => 0
    }

  it("accepts at most 100 queries counting in-flight ones", t => {
    t.expect({
      "freshOnly": makeFetchState(~partitionsCount=120, ~inFlightCount=0)->countQueries,
      "withInFlight": makeFetchState(~partitionsCount=120, ~inFlightCount=30)->countQueries,
      "underCap": makeFetchState(~partitionsCount=50, ~inFlightCount=0)->countQueries,
      "atCap": makeFetchState(~partitionsCount=120, ~inFlightCount=100)->countQueries,
    }).toEqual({
      "freshOnly": 100,
      "withInFlight": 70,
      "underCap": 50,
      "atCap": 0,
    })
  })

  it("sizes probes by the full in-range count while admitting only up to the cap", t => {
    let queries = switch makeFetchState(
      ~partitionsCount=120,
      ~inFlightCount=0,
    )->FetchState.getNextQuery(~chainTargetBlock=100000, ~chainTargetItems=1_000_000.) {
    | Ready(queries) => queries
    | _ => []
    }
    // 10 items/block budget density over the 100k-block range, split across all
    // 120 in-range partitions — an honest per-partition share for budget
    // control — even though the concurrency cap admits only 100 queries.
    t.expect({
      "count": queries->Array.length,
      "firstItemsTarget": (queries->Array.getUnsafe(0)).itemsEst,
    }).toEqual({
      "count": 100,
      "firstItemsTarget": 8333,
    })
  })

  it("doesn't count fetched chunks against the partition pipeline cap", t => {
    // A full 12-chunk pipeline where only the head chunk is still being
    // fetched: the 11 fetched chunks parked behind it hold no slots, so the
    // partition can still generate a query past the pipeline.
    let mutPendingQueries: array<FetchState.pendingQuery> = Array.fromInitializer(~length=12, idx => {
      FetchState.fromBlock: idx * 10 + 1,
      toBlock: Some((idx + 1) * 10),
      isChunk: true,
      itemsTarget: None,
      itemsEst: 1,
      fetchedBlock: idx === 0 ? None : Some({blockNumber: (idx + 1) * 10, blockTimestamp: 0}),
    })
    let fetchState = {
      ...makeFetchState(~partitionsCount=1, ~inFlightCount=0),
      optimizedPartitions: FetchState.OptimizedPartitions.make(
        ~partitions=[{...makePartition(~idx=0, ~inFlight=false), mutPendingQueries}],
        ~maxAddrInPartition=1,
        ~nextPartitionIndex=1,
        ~dynamicContracts=Utils.Set.make(),
      ~clientFilteredContracts=Utils.Set.make(),
      ),
    }
    t.expect((fetchState->FetchState.getNextQuery(~chainTargetBlock=100000, ~chainTargetItems=1000.))->TestAddresses.nextQuery,
    ).toEqual((FetchState.Ready([
        {
          partitionId: "0",
          fromBlock: 121,
          toBlock: None,
          isChunk: false,
          selection: normalSelection,
          itemsTarget: Some(999),
          itemsEst: 999,
          addresses,
        },
      ]))->TestAddresses.nextQuery)
  })

  it("re-sorts partitions when a response overtakes another partition", t => {
    // Exercises the handleQueryResult fast path (no dynamic contracts): the
    // responding partition jumps from block 0 to 100, past the partition
    // sitting at 50, so idsInAscOrder must be reordered without a full remake.
    let fetchState = {
      ...makeFetchState(~partitionsCount=1, ~inFlightCount=0),
      optimizedPartitions: FetchState.OptimizedPartitions.make(
        ~partitions=[
          makePartition(~idx=0, ~inFlight=false),
          {
            ...makePartition(~idx=1, ~inFlight=false),
            latestFetchedBlock: {blockNumber: 50, blockTimestamp: 0},
          },
        ],
        ~maxAddrInPartition=1,
        ~nextPartitionIndex=2,
        ~dynamicContracts=Utils.Set.make(),
      ~clientFilteredContracts=Utils.Set.make(),
      ),
    }
    let query: FetchState.query = {
      partitionId: "0",
      fromBlock: 1,
      toBlock: None,
      isChunk: false,
      selection: normalSelection,
      itemsTarget: Some(10),
      itemsEst: 10,
      addresses,
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updated =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock={blockNumber: 100, blockTimestamp: 0},
        ~newItems=[],
      )
    t.expect(
      updated.optimizedPartitions.idsInAscOrder,
      ~message="partition 1 (still at block 50) must sort before partition 0 (now at 100)",
    ).toEqual(["1", "0"])
  })
})

describe("FetchState client-side address filtering", () => {
  let makeGravatarFs = (~clientFilterAddressThreshold) =>
    makeFs(
      ~onEventRegistrations=[baseEventConfig],
      ~addresses=[makeConfigContract("Gravatar", mockAddress0)],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=10,
      ~chainId,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~knownHeight=100,
      ~clientFilterAddressThreshold,
    )

  let partitionShape = (fetchState: FetchState.t) =>
    fetchState.optimizedPartitions.entities
    ->Dict.valuesToArray
    ->Array.map(p => (
      p.selection.dependsOnAddresses,
      p.selection.clientFilteredContracts,
      p.addresses->AddressSet.contractNames,
    ))

  it("collapses a dynamic contract into one address-free partition once it crosses the threshold", t => {
    let (fetchState, addressStore) = makeGravatarFs(~clientFilterAddressThreshold=Some(1))
    // Config Gravatar (mockAddress0) + two dynamic Gravatar addresses => count 3 > 1.
    let updated =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
        makeDynContractRegistration(~blockNumber=4, ~contractAddress=mockAddress2)->dcToRegistration,
      ])

    t.expect(
      (updated->partitionShape, updated.optimizedPartitions.clientFilteredContracts->Utils.Set.toArray),
      ~message="single address-free partition marking Gravatar client-filtered, no server-side addresses",
    ).toEqual(([(false, Some(["Gravatar"]), [])], ["Gravatar"]))
  })

  it("stays server-side while under the threshold", t => {
    let (fetchState, addressStore) = makeGravatarFs(~clientFilterAddressThreshold=Some(10))
    let updated =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
      ])
    t.expect(
      updated.optimizedPartitions.clientFilteredContracts->Utils.Set.toArray,
      ~message="no contract switched below the threshold",
    ).toEqual([])
  })

  it("never switches when the threshold is None (unsupported source)", t => {
    let (fetchState, addressStore) = makeGravatarFs(~clientFilterAddressThreshold=None)
    let updated =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
        makeDynContractRegistration(~blockNumber=4, ~contractAddress=mockAddress2)->dcToRegistration,
        makeDynContractRegistration(~blockNumber=5, ~contractAddress=mockAddress3)->dcToRegistration,
      ])
    t.expect(
      updated.optimizedPartitions.clientFilteredContracts->Utils.Set.toArray,
      ~message="disabled: never switches regardless of address count",
    ).toEqual([])
  })

  it("emits queries carrying clientFilteredContracts", t => {
    let (fetchState, addressStore) = makeGravatarFs(~clientFilterAddressThreshold=Some(1))
    let updated =
      fetchState
      ->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
        makeDynContractRegistration(~blockNumber=4, ~contractAddress=mockAddress2)->dcToRegistration,
      ])
      ->FetchState.updateKnownHeight(~knownHeight=100)

    let clientFiltered = switch updated->FetchState.getNextQuery(
      ~chainTargetBlock=100,
      ~chainTargetItems=10_000.,
    ) {
    | Ready(queries) =>
      queries->Array.map(q => (q.selection.dependsOnAddresses, q.selection.clientFilteredContracts))
    | _ => []
    }
    t.expect(
      clientFiltered,
      ~message="the address-free partition's query names the client-filtered contract",
    ).toEqual([(false, Some(["Gravatar"]))])
  })

  it("rejects a response for a partition that no longer exists", t => {
    let (fetchState, addressStore) = makeGravatarFs(~clientFilterAddressThreshold=Some(1))
    let collapsed =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
        makeDynContractRegistration(~blockNumber=4, ~contractAddress=mockAddress2)->dcToRegistration,
      ])

    // Every path that stops a partition fetching now retires it until its last
    // response lands, so an unknown partition id means the response outlived a
    // rollback — which bumps the indexer epoch, so ChainFetching drops it long
    // before here. Reaching this point at all is a broken invariant, and
    // buffering the items would admit them below the frontier.
    let orphanQuery: FetchState.query = {
      ...defaultQuery,
      partitionId: "999",
      fromBlock: 0,
    }
    t.expect(
      () =>
        collapsed
        ->FetchState.handleQueryResult(
          ~query=orphanQuery,
          ~latestFetchedBlock=getBlockData(~blockNumber=5),
          ~newItems=[mockEvent(~blockNumber=1), mockEvent(~blockNumber=2)],
        )
        ->ignore,
      ~message="a response with no partition to advance is rejected, not buffered",
    ).toThrow()
  })

  it("holds the frontier below a query orphaned by a client-filter switch", t => {
    let (fetchState, addressStore) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
      ~addresses=[makeConfigContract("Gravatar", mockAddress0)],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=10,
      ~chainId,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~knownHeight=1000,
      ~clientFilterAddressThreshold=Some(1),
    )

    // Gravatar crosses the threshold → one standing address-free partition.
    let collapsed =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
        makeDynContractRegistration(~blockNumber=4, ~contractAddress=mockAddress2)->dcToRegistration,
      ])

    let takeQuery = fs =>
      switch fs->FetchState.getNextQuery(~chainTargetBlock=1000, ~chainTargetItems=10_000.) {
      | Ready([query]) => query
      | _ => JsError.throwWithMessage("expected a single ready query")
      }

    // The standing partition dispatches a query over the whole known range.
    let inFlight = collapsed->takeQuery
    collapsed->FetchState.startFetchingQueries(~queries=[inFlight])

    // NftFactory crosses the threshold while that query is still running, so the
    // client-filtered set grows and the standing partition's selection changes.
    let afterSwitch =
      collapsed->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(
          ~blockNumber=5,
          ~contractAddress=mockAddress3,
          ~contractName="NftFactory",
        )->dcToRegistration,
        makeDynContractRegistration(
          ~blockNumber=6,
          ~contractAddress=mockAddress4,
          ~contractName="NftFactory",
        )->dcToRegistration,
      ])

    // The old generation is retired beside the new one rather than dropped, so
    // it still holds the frontier and its query's budget reservation. Nothing
    // fetches over that range again until the response lands.
    let frontierAfterSwitch = afterSwitch->FetchState.bufferBlockNumber
    let queryableAfterSwitch =
      afterSwitch->FetchState.getNextQuery(~chainTargetBlock=1000, ~chainTargetItems=10_000.) !==
        NothingToQuery

    // The response lands against the partition that dispatched it.
    let afterSettled =
      afterSwitch->FetchState.handleQueryResult(
        ~query=inFlight,
        ~latestFetchedBlock=getBlockData(~blockNumber=500),
        ~newItems=[mockEvent(~blockNumber=200)],
      )

    // Retired and drained, so it's gone — but the frontier stays put: the new
    // generation has not covered that range under the wider selection yet, so
    // the item it delivered is buffered and not yet processable.
    let frontierAfterSettled = afterSettled->FetchState.bufferBlockNumber
    let readyAfterSettled = afterSettled->FetchState.bufferReadyCount

    // Only now does the new generation fetch, re-delivering the same event.
    let newQuery = afterSettled->takeQuery
    afterSettled->FetchState.startFetchingQueries(~queries=[newQuery])
    let afterNewGeneration =
      afterSettled->FetchState.handleQueryResult(
        ~query=newQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=500),
        ~newItems=[mockEvent(~blockNumber=200)],
      )

    t.expect(
      (
        (frontierAfterSwitch, queryableAfterSwitch),
        (frontierAfterSettled, readyAfterSettled),
        (
          afterNewGeneration->FetchState.bufferBlockNumber,
          afterNewGeneration.buffer->Array.map(Internal.getItemBlockNumber),
          afterNewGeneration->FetchState.bufferReadyCount,
        ),
      ),
      ~message="the retired generation holds the frontier until its response lands; no item is ever admitted below an already-processable frontier",
    ).toEqual(((-1, false), (-1, 0), (500, [200], 1)))
  })

  // The standing address-free partition: client-filtered contracts' events are
  // fetched by it, while a bounded backfill (mergeBlock set) covers overlap.
  let standingId = (fetchState: FetchState.t) =>
    (
      fetchState.optimizedPartitions.entities
      ->Dict.valuesToArray
      ->Array.find(p => !p.selection.dependsOnAddresses && p.mergeBlock->Option.isNone)
      ->Option.getOrThrow
    ).id

  it("keeps a retired generation until the last of its queries lands", t => {
    let (fetchState, addressStore) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
      ~addresses=[makeConfigContract("Gravatar", mockAddress0)],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=10,
      ~chainId,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~knownHeight=1000,
      ~clientFilterAddressThreshold=Some(1),
    )
    let collapsed =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
        makeDynContractRegistration(~blockNumber=4, ~contractAddress=mockAddress2)->dcToRegistration,
      ])

    // Two chunks in flight at once, so the first response drains only part of
    // the queue: the merge block is reached but a response is still owed.
    let standing = collapsed->standingId
    let chunk = (fromBlock, toBlock): FetchState.query => {
      ...defaultQuery,
      partitionId: standing,
      fromBlock,
      toBlock: Some(toBlock),
      isChunk: true,
    }
    let q1 = chunk(0, 100)
    let q2 = chunk(101, 200)
    collapsed->FetchState.startFetchingQueries(~queries=[q1, q2])

    let afterSwitch =
      collapsed->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(
          ~blockNumber=5,
          ~contractAddress=mockAddress3,
          ~contractName="NftFactory",
        )->dcToRegistration,
        makeDynContractRegistration(
          ~blockNumber=6,
          ~contractAddress=mockAddress4,
          ~contractName="NftFactory",
        )->dcToRegistration,
      ])
    let holdsId = (fs: FetchState.t) => fs.optimizedPartitions.idsInAscOrder->Array.includes(standing)

    let afterFirst =
      afterSwitch->FetchState.handleQueryResult(
        ~query=q1,
        ~latestFetchedBlock=getBlockData(~blockNumber=100),
        ~newItems=[],
      )
    let afterSecond =
      afterFirst->FetchState.handleQueryResult(
        ~query=q2,
        ~latestFetchedBlock=getBlockData(~blockNumber=200),
        ~newItems=[],
      )

    t.expect(
      (afterSwitch->holdsId, afterFirst->holdsId, afterSecond->holdsId),
      ~message="retired at a merge block it has already passed, it goes only once the second response lands",
    ).toEqual((true, true, false))
  })

  it("retires a fetching backfill when a later batch collapses again", t => {
    let (fetchState, addressStore) = makeFs(
      ~onEventRegistrations=[
        baseEventConfig,
        baseEventConfig2,
        (MockIndexer.evmOnEventRegistration(
          ~id="0",
          ~contractName="SimpleNft",
        ) :> Internal.onEventRegistration),
      ],
      ~addresses=[makeConfigContract("Gravatar", mockAddress0)],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=10,
      ~chainId,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~knownHeight=1000,
      ~clientFilterAddressThreshold=Some(1),
    )
    // Gravatar collapses, then its standing partition advances to 50.
    let collapsed =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
        makeDynContractRegistration(~blockNumber=4, ~contractAddress=mockAddress2)->dcToRegistration,
      ])
    let standingQuery: FetchState.query = {
      ...defaultQuery,
      partitionId: collapsed->standingId,
      fromBlock: 0,
      toBlock: Some(50),
      isChunk: true,
    }
    collapsed->FetchState.startFetchingQueries(~queries=[standingQuery])
    let advanced =
      collapsed->FetchState.handleQueryResult(
        ~query=standingQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=50),
        ~newItems=[],
      )

    // NftFactory crosses the threshold too. Its partitions sit far below the
    // standing frontier, so folding them in leaves a bounded backfill.
    let withBackfill =
      advanced->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(
          ~blockNumber=5,
          ~contractAddress=mockAddress3,
          ~contractName="NftFactory",
        )->dcToRegistration,
        makeDynContractRegistration(
          ~blockNumber=6,
          ~contractAddress=mockAddress4,
          ~contractName="NftFactory",
        )->dcToRegistration,
      ])
    let backfillId =
      (
        withBackfill.optimizedPartitions.entities
        ->Dict.valuesToArray
        ->Array.find(p => !(p.selection.dependsOnAddresses) && p.mergeBlock->Option.isSome)
        ->Option.getOrThrow
      ).id
    let backfillQuery: FetchState.query = {
      ...defaultQuery,
      partitionId: backfillId,
      fromBlock: 5,
      toBlock: Some(30),
      isChunk: true,
    }
    withBackfill->FetchState.startFetchingQueries(~queries=[backfillQuery])

    // A third contract crosses the threshold while that backfill is mid-query,
    // so the collapse runs again. Its response must still find the partition it
    // was sent for.
    let recollapsed =
      withBackfill->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(
          ~blockNumber=40,
          ~contractAddress=mockAddress5,
          ~contractName="SimpleNft",
        )->dcToRegistration,
        makeDynContractRegistration(
          ~blockNumber=41,
          ~contractAddress=mockAddress6,
          ~contractName="SimpleNft",
        )->dcToRegistration,
      ])
    let afterBackfill =
      recollapsed->FetchState.handleQueryResult(
        ~query=backfillQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=30),
        ~newItems=[mockEvent(~blockNumber=12)],
      )

    t.expect(
      (
        recollapsed.optimizedPartitions.idsInAscOrder->Array.includes(backfillId),
        afterBackfill.optimizedPartitions.idsInAscOrder->Array.includes(backfillId),
        afterBackfill->FetchState.bufferSize,
      ),
      ~message="a backfill mid-query survives the recollapse and goes once its response lands",
    ).toEqual((true, false, 1))
  })

  it("retires every fetching partition the collapse would otherwise absorb", t => {
    // Threshold 2: config address + one dynamic stays server-side, so real
    // address-bound partitions exist and can be mid-query when the second
    // registration pushes the count over and collapses them.
    let (fetchState, addressStore) = makeFs(
      ~onEventRegistrations=[baseEventConfig],
      ~addresses=[makeConfigContract("Gravatar", mockAddress0)],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=1,
      ~chainId,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~knownHeight=1000,
      ~clientFilterAddressThreshold=Some(2),
    )
    let serverSide =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
      ])

    let fetchingIds = serverSide.optimizedPartitions.idsInAscOrder
    serverSide->FetchState.startFetchingQueries(
      ~queries=fetchingIds->Array.map((id): FetchState.query => {
        ...defaultQuery,
        partitionId: id,
        fromBlock: 0,
        toBlock: Some(100),
        isChunk: true,
      }),
    )

    let collapsed =
      serverSide->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=4, ~contractAddress=mockAddress2)->dcToRegistration,
      ])

    t.expect(
      (
        fetchingIds->Utils.Array.isEmpty,
        fetchingIds->Array.filter(id =>
          !(collapsed.optimizedPartitions.idsInAscOrder->Array.includes(id))
        ),
        collapsed.optimizedPartitions.clientFilteredContracts->Utils.Set.toArray,
      ),
      ~message="absorbed partitions with a response owed survive the collapse, so their items keep an owner",
    ).toEqual((false, [], ["Gravatar"]))
  })

  it("keeps the collapsed address-free partition across an unrelated registration batch", t => {
    let (fetchState, addressStore) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
      ~addresses=[makeConfigContract("Gravatar", mockAddress0)],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=10,
      ~chainId,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~knownHeight=100,
      ~clientFilterAddressThreshold=Some(1),
    )
    // Gravatar crosses the threshold → collapses to one address-free partition.
    let collapsed =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
        makeDynContractRegistration(~blockNumber=4, ~contractAddress=mockAddress2)->dcToRegistration,
      ])

    // Registering an unrelated NftFactory address must not tear the Gravatar
    // address-free partition down: its id (and in-flight queries + learned
    // density) must survive, with NftFactory added as its own server-side
    // partition.
    let afterUnrelated =
      collapsed->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(
          ~blockNumber=5,
          ~contractAddress=mockAddress3,
          ~contractName="NftFactory",
        )->dcToRegistration,
      ])

    let shape = afterUnrelated->partitionShape
    t.expect(
      (
        collapsed->standingId === afterUnrelated->standingId,
        shape->Array.filter(((dependsOnAddresses, _, _)) => !dependsOnAddresses),
        shape->Array.filter(((dependsOnAddresses, _, _)) => dependsOnAddresses),
      ),
      ~message="address-free partition id preserved; NftFactory kept server-side",
    ).toEqual((
      true,
      [(false, Some(["Gravatar"]), [])],
      [(true, None, ["NftFactory"])],
    ))
  })

  it("switches a config contract to client-side filtering at creation when it exceeds the threshold", t => {
    // Config addresses (registrationBlock -1) are not dynamic, yet a static list
    // over the threshold still switches to client-side filtering at creation.
    let (fetchState, _addressStore) = makeFs(
      ~onEventRegistrations=[baseEventConfig],
      ~addresses=[
        makeConfigContract("Gravatar", mockAddress0),
        makeConfigContract("Gravatar", mockAddress1),
        makeConfigContract("Gravatar", mockAddress2),
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=10,
      ~chainId,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~knownHeight=100,
      ~clientFilterAddressThreshold=Some(2),
    )
    t.expect(
      (fetchState->partitionShape, fetchState.optimizedPartitions.clientFilteredContracts->Utils.Set.toArray),
      ~message="3 config addresses > threshold 2 → one address-free client-filtered partition",
    ).toEqual(([(false, Some(["Gravatar"]), [])], ["Gravatar"]))
  })

  it("creates no server-side partitions for a contract that is client-filtered from the start", t => {
    // maxAddrInPartition=1 would chunk the 6 addresses into 6 partitions before
    // the collapse absorbed them again. They must never be built: the only
    // partition index consumed is the address-free partition's.
    let (fetchState, _addressStore) = makeFs(
      ~onEventRegistrations=[baseEventConfig],
      ~addresses=[
        makeConfigContract("Gravatar", mockAddress0),
        makeConfigContract("Gravatar", mockAddress1),
        makeConfigContract("Gravatar", mockAddress2),
        makeConfigContract("Gravatar", mockAddress3),
        makeConfigContract("Gravatar", mockAddress4),
        makeConfigContract("Gravatar", mockAddress5),
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=1,
      ~chainId,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~knownHeight=100,
      ~clientFilterAddressThreshold=Some(2),
    )
    t.expect(
      (
        fetchState->partitionShape,
        fetchState.optimizedPartitions.idsInAscOrder,
        fetchState.optimizedPartitions.nextPartitionIndex,
      ),
      ~message="one address-free partition with the first index; no chunked partitions were ever created",
    ).toEqual(([(false, Some(["Gravatar"]), [])], ["0"], 1))
  })

  it("keeps a contract client-side filtered across rollback", t => {
    let (fetchState, addressStore) = makeGravatarFs(~clientFilterAddressThreshold=Some(1))
    let collapsed =
      fetchState->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
        makeDynContractRegistration(~blockNumber=4, ~contractAddress=mockAddress2)->dcToRegistration,
      ])
    let rolledBack = collapsed->FetchState.rollback(~addressStore, ~targetBlockNumber=3)
    t.expect(
      (
        rolledBack.optimizedPartitions.clientFilteredContracts->Utils.Set.toArray,
        rolledBack->partitionShape,
      ),
      ~message="client-side filtering is sticky through rollback; still one client-filtered address-free partition",
    ).toEqual((["Gravatar"], [(false, Some(["Gravatar"]), [])]))
  })

  // The address-free partition shows up with no addresses of its own; a
  // catch-up partition for freshly registered addresses shows its contract.
  let frontierShape = (fetchState: FetchState.t) =>
    fetchState.optimizedPartitions.idsInAscOrder->Array.map(id => {
      let p = fetchState.optimizedPartitions.entities->Dict.getUnsafe(id)
      (p.latestFetchedBlock.blockNumber, p.mergeBlock, p.addresses->AddressSet.contractNames)
    })

  // Standing address-free partition with its frontier advanced to block 50,
  // ready to take later registrations.
  let makeCollapsedAt50 = () => {
    let (fetchState, addressStore) = makeGravatarFs(~clientFilterAddressThreshold=Some(1))
    let collapsed =
      fetchState
      ->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=3, ~contractAddress=mockAddress1)->dcToRegistration,
        makeDynContractRegistration(~blockNumber=4, ~contractAddress=mockAddress2)->dcToRegistration,
      ])
      ->FetchState.updateKnownHeight(~knownHeight=100)
    let query = switch collapsed->FetchState.getNextQuery(
      ~chainTargetBlock=100,
      ~chainTargetItems=10_000.,
    ) {
    | Ready([query]) => query
    | _ => JsError.throwWithMessage("Expected a single address-free query")
    }
    collapsed->FetchState.startFetchingQueries(~queries=[query])
    let advanced =
      collapsed->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock=getBlockData(~blockNumber=50),
        ~newItems=[],
      )
    (advanced, addressStore)
  }

  // The same standing partition, but with a query in flight past its frontier.
  // A query already dispatched was routed against the address store before the
  // next batch registers, so its response carries nothing for those addresses —
  // yet it still advances the frontier over its range when it lands.
  let makeCollapsedAt50WithQueryInFlight = () => {
    let (advanced, addressStore) = makeCollapsedAt50()
    let query = switch advanced->FetchState.getNextQuery(
      ~chainTargetBlock=100,
      ~chainTargetItems=10_000.,
    ) {
    | Ready([query]) => query
    | _ => JsError.throwWithMessage("Expected a single query past the frontier")
    }
    advanced->FetchState.startFetchingQueries(~queries=[query])
    (advanced, addressStore, query)
  }

  it("leaves the catch-up unbounded while an open-ended query is in flight", t => {
    let (advanced, addressStore, inFlight) = makeCollapsedAt50WithQueryInFlight()
    let afterReg =
      advanced->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress3)->dcToRegistration,
      ])
    t.expect(
      (inFlight.toBlock, afterReg->frontierShape),
      // An open-ended probe carries no toBlock of its own, so there's no block
      // the standing partition is known to have covered the new address from.
      // The catch-up stays unbounded and keeps fetching until a later
      // optimization can bound it.
      ~message="no merge block guessed from the known height",
    ).toEqual((None, [(19, None, ["Gravatar"]), (50, None, [])]))
  })

  it("bounds the catch-up once the open-ended query settles", t => {
    let (advanced, addressStore, inFlight) = makeCollapsedAt50WithQueryInFlight()
    let afterReg =
      advanced->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress3)->dcToRegistration,
      ])
    // The query came back at 120 — past the height known when it went out. It
    // carried nothing for the new address, so the catch-up must reach 120.
    let settled =
      afterReg->FetchState.handleQueryResult(
        ~query=inFlight,
        ~latestFetchedBlock=getBlockData(~blockNumber=120),
        ~newItems=[],
      )
    t.expect(
      settled->frontierShape,
      ~message="catch-up bounded by what the response actually covered",
    ).toEqual([(19, Some(120), ["Gravatar"]), (120, None, [])])
  })

  // Both partitions probing open-ended at the same time: the standing partition
  // can't bound the catch-up while its own query is unbounded, so the catch-up
  // goes out unbounded too and the two responses may land in either order.
  let makeTwoOpenEndedQueriesInFlight = () => {
    let (advanced, addressStore, standingQuery) = makeCollapsedAt50WithQueryInFlight()
    let afterReg =
      advanced->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress3)->dcToRegistration,
      ])
    let catchUpQuery = switch afterReg->FetchState.getNextQuery(
      ~chainTargetBlock=100,
      ~chainTargetItems=10_000.,
    ) {
    | Ready([query]) => query
    | _ => JsError.throwWithMessage("Expected a single catch-up query")
    }
    afterReg->FetchState.startFetchingQueries(~queries=[catchUpQuery])
    (afterReg, standingQuery, catchUpQuery)
  }

  it("bounds and removes the catch-up when the standing response lands first", t => {
    let (afterReg, standingQuery, catchUpQuery) = makeTwoOpenEndedQueriesInFlight()
    // Dispatched after the catch-up's query (fromBlock 51 against 20) yet
    // completing before it.
    let afterStanding =
      afterReg->FetchState.handleQueryResult(
        ~query=standingQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=120),
        ~newItems=[mockEvent(~blockNumber=60)],
      )
    // The catch-up had no bound when it went out, so it comes back past the
    // merge block it has since been given — and is removed on arrival.
    let afterCatchUp =
      afterStanding->FetchState.handleQueryResult(
        ~query=catchUpQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=150),
        ~newItems=[mockEvent(~blockNumber=60)],
      )
    t.expect(
      (
        (standingQuery.toBlock, catchUpQuery.toBlock),
        afterStanding->frontierShape,
        afterCatchUp->frontierShape,
        afterCatchUp->FetchState.bufferSize,
      ),
      ~message="both queries open-ended; the settled response bounds the catch-up, which then over-fetches past it and disappears, its overlap deduped",
    ).toEqual(((None, None), [(19, Some(120), ["Gravatar"]), (120, None, [])], [(120, None, [])], 1))
  })

  it("retires an anchored catch-up that overshot its anchor while still fetching", t => {
    let (afterReg, standingQuery, catchUpQuery) = makeTwoOpenEndedQueriesInFlight()
    // The catch-up runs ahead of the standing partition, then dispatches again.
    let afterCatchUp =
      afterReg->FetchState.handleQueryResult(
        ~query=catchUpQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=80),
        ~newItems=[],
      )
    // Budget above the standing query's outstanding reservation, so the
    // catch-up's second query isn't held back by it.
    let secondCatchUpQuery = switch afterCatchUp->FetchState.getNextQuery(
      ~chainTargetBlock=100,
      ~chainTargetItems=100_000.,
    ) {
    | Ready([query]) => query
    | _ => JsError.throwWithMessage("Expected a single catch-up query")
    }
    afterCatchUp->FetchState.startFetchingQueries(~queries=[secondCatchUpQuery])

    // The standing query settles below the catch-up's frontier, so the block
    // the catch-up was to stop at is one it has already passed — but its second
    // query is still out, and dropping it would strand that response.
    let afterStanding =
      afterCatchUp->FetchState.handleQueryResult(
        ~query=standingQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=70),
        ~newItems=[],
      )
    let afterSecond =
      afterStanding->FetchState.handleQueryResult(
        ~query=secondCatchUpQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=90),
        ~newItems=[mockEvent(~blockNumber=85)],
      )
    t.expect(
      (afterStanding->frontierShape, afterSecond->frontierShape, afterSecond->FetchState.bufferSize),
      ~message="the overshooting catch-up is retired rather than dropped, so its last response still has a partition to land on",
    ).toEqual((
      [(70, None, []), (80, Some(80), ["Gravatar"])],
      [(70, None, [])],
      1,
    ))
  })

  it("keeps the catch-up unbounded when its own response lands first", t => {
    let (afterReg, standingQuery, catchUpQuery) = makeTwoOpenEndedQueriesInFlight()
    let afterCatchUp =
      afterReg->FetchState.handleQueryResult(
        ~query=catchUpQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=80),
        ~newItems=[mockEvent(~blockNumber=60)],
      )
    let afterStanding =
      afterCatchUp->FetchState.handleQueryResult(
        ~query=standingQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=120),
        ~newItems=[mockEvent(~blockNumber=60)],
      )
    t.expect(
      (
        afterCatchUp->frontierShape,
        afterStanding->frontierShape,
        afterStanding->FetchState.bufferSize,
      ),
      ~message="catch-up runs past the standing frontier unbounded, then is bounded by what the standing response actually covered",
    ).toEqual((
      [(50, None, []), (80, None, ["Gravatar"])],
      [(80, Some(120), ["Gravatar"]), (120, None, [])],
      1,
    ))
  })

  it("catches an address up over the in-flight range above the frontier", t => {
    let (advanced, addressStore, _inFlight) = makeCollapsedAt50WithQueryInFlight()
    // Registered at 60: above the standing frontier of 50, so nothing is behind
    // to catch up on — but the query covering [51, ...] was routed before the
    // address existed, so [59, ...] still needs its own partition.
    let afterReg =
      advanced->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=60, ~contractAddress=mockAddress3)->dcToRegistration,
      ])
    t.expect(
      afterReg->frontierShape,
      ~message="catch-up covers the in-flight range above the frontier",
    ).toEqual([(50, None, []), (59, None, ["Gravatar"])])
  })

  it("adds no catch-up above the frontier when nothing is in flight", t => {
    let (advanced, addressStore) = makeCollapsedAt50()
    // Same registration, no query dispatched: the standing partition has not
    // fetched past 50, so it covers block 60 going forward on its own.
    let afterReg =
      advanced->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=60, ~contractAddress=mockAddress3)->dcToRegistration,
      ])
    t.expect(
      afterReg->frontierShape,
      ~message="no catch-up; the standing partition still covers everything ahead",
    ).toEqual([(50, None, [])])
  })

  it("adds an address-bound catch-up partition when a client-filtered contract registers a new address", t => {
    let (advanced, addressStore) = makeCollapsedAt50()
    let afterReg =
      advanced->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress3)->dcToRegistration,
      ])
    let catchUp =
      afterReg.optimizedPartitions.entities
      ->Dict.valuesToArray
      ->Array.find(p => p.id !== afterReg->standingId)
      ->Option.getOrThrow
    t.expect(
      (
        advanced->standingId === afterReg->standingId,
        afterReg->frontierShape,
        (
          catchUp.selection.dependsOnAddresses,
          catchUp.dynamicContract,
          catchUp.addresses->AddressSet.addresses,
        ),
      ),
      ~message="standing partition untouched at 50; catch-up fetches only the new address over [19, 50]",
    ).toEqual((
      true,
      [(19, Some(50), ["Gravatar"]), (50, None, [])],
      (true, Some("Gravatar"), [mockAddress3]),
    ))
  })

  it("gives each successive registration its own catch-up partition", t => {
    let (advanced, addressStore) = makeCollapsedAt50()
    let afterSecond =
      advanced
      ->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress3)->dcToRegistration,
      ])
      ->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=30, ~contractAddress=mockAddress4)->dcToRegistration,
      ])
    t.expect(
      (advanced->standingId === afterSecond->standingId, afterSecond->frontierShape),
      ~message="each catch-up starts at its own address's block; standing partition untouched",
    ).toEqual((true, [(19, Some(50), ["Gravatar"]), (29, Some(50), ["Gravatar"]), (50, None, [])]))
  })

  it("removes the catch-up partition once it reaches its mergeBlock", t => {
    let (advanced, addressStore) = makeCollapsedAt50()
    let afterReg =
      advanced->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress3)->dcToRegistration,
      ])
    let queries = switch afterReg->FetchState.getNextQuery(
      ~chainTargetBlock=100,
      ~chainTargetItems=10_000.,
    ) {
    | Ready(queries) => queries
    | _ => []
    }
    afterReg->FetchState.startFetchingQueries(~queries)
    let catchUpQuery =
      queries->Array.find(q => q.partitionId !== afterReg->standingId)->Option.getOrThrow
    let caughtUp =
      afterReg->FetchState.handleQueryResult(
        ~query=catchUpQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=50),
        ~newItems=[],
      )
    t.expect(
      (
        catchUpQuery.selection.dependsOnAddresses,
        catchUpQuery.toBlock,
        caughtUp->standingId === afterReg->standingId,
        caughtUp->frontierShape,
      ),
      ~message="the catch-up queries server-side up to its mergeBlock, then is deleted; standing partition untouched",
    ).toEqual((true, Some(50), true, [(50, None, [])]))
  })

  it("merges a surviving catch-up partition away on rollback", t => {
    let (advanced, addressStore) = makeCollapsedAt50()
    let afterReg =
      advanced->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress3)->dcToRegistration,
      ])
    let queries = switch afterReg->FetchState.getNextQuery(
      ~chainTargetBlock=100,
      ~chainTargetItems=10_000.,
    ) {
    | Ready(queries) => queries
    | _ => []
    }
    let catchUpQuery =
      queries->Array.find(q => q.partitionId !== afterReg->standingId)->Option.getOrThrow
    afterReg->FetchState.startFetchingQueries(~queries=[catchUpQuery])
    let advancedCatchUp =
      afterReg->FetchState.handleQueryResult(
        ~query=catchUpQuery,
        ~latestFetchedBlock=getBlockData(~blockNumber=45),
        ~newItems=[],
      )
    // Rolling back to 40 keeps the address (registered at 20) and puts every
    // partition on the same frontier — nothing is left for a catch-up to cover,
    // so the address-free partition stands alone again.
    let rolledBack = advancedCatchUp->FetchState.rollback(~addressStore, ~targetBlockNumber=40)
    t.expect(
      (advancedCatchUp->frontierShape, rolledBack->frontierShape),
      ~message="catch-up merges into the address-free partition instead of surviving the rollback",
    ).toEqual(([(45, Some(50), ["Gravatar"]), (50, None, [])], [(40, None, [])]))
  })

  it("keeps a catch-up partition that rollback leaves behind the address-free partition", t => {
    let (advanced, addressStore) = makeCollapsedAt50()
    let afterReg =
      advanced->FetchState.registerDynamicContracts(~addressStore, [
        makeDynContractRegistration(~blockNumber=20, ~contractAddress=mockAddress3)->dcToRegistration,
      ])
    // The catch-up is still at 19 after the rollback to 30, so it keeps its
    // range — now bounded by where the address-free partition was rolled back to.
    let rolledBack = afterReg->FetchState.rollback(~addressStore, ~targetBlockNumber=30)
    t.expect(
      rolledBack->frontierShape,
      ~message="catch-up survives with its merge block capped at the rollback target",
    ).toEqual([(19, Some(30), ["Gravatar"]), (30, None, [])])
  })

  it("strips a client-filtered contract's addresses from a partition shared with a server-side contract", t => {
    // 3 Gravatar config addresses (> threshold 2) merge with NftFactory's into
    // one mixed partition before the collapse runs. The client-filtered side
    // covers Gravatar, so its addresses must leave the mixed partition (no
    // permanent duplicate fetching), while NftFactory stays server-side.
    let (fetchState, _addressStore) = makeFs(
      ~onEventRegistrations=[baseEventConfig, baseEventConfig2],
      ~addresses=[
        makeConfigContract("Gravatar", mockAddress0),
        makeConfigContract("Gravatar", mockAddress1),
        makeConfigContract("Gravatar", mockAddress2),
        makeConfigContract("NftFactory", mockAddress3),
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=10,
      ~chainId,
      ~maxOnBlockBufferSize=targetBufferSize,
      ~knownHeight=100,
      ~clientFilterAddressThreshold=Some(2),
    )
    let standingRegContracts =
      (
        fetchState.optimizedPartitions.entities
        ->Dict.valuesToArray
        ->Array.find(p => !p.selection.dependsOnAddresses)
        ->Option.getOrThrow
      ).selection.onEventRegistrations->Array.map(reg => reg.eventConfig.contractName)
    t.expect(
      (fetchState->partitionShape, standingRegContracts),
      ~message="Gravatar stripped from the mixed partition yet covered by the address-free partition's registrations",
    ).toEqual(
      (
        [(true, None, ["NftFactory"]), (false, Some(["Gravatar"]), [])],
        ["Gravatar"],
      ),
    )
  })
})
