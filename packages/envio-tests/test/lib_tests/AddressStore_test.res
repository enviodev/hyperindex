open Vitest

let addr = i => Envio.TestHelpers.Addresses.mockAddresses[i]->Option.getOrThrow

let contract = (~address, ~contractName, ~registrationBlock): Internal.indexingAddress => {
  address,
  contractName,
  registrationBlock,
}

// One event per contract so the store knows both contract names; an address
// registered for anything else is tracked but never fetched.
let onEventRegistrations = [
  (EventRegistration.evmOnEventRegistration(~id="0", ~contractName="A") :> Internal.onEventRegistration),
  (EventRegistration.evmOnEventRegistration(~id="1", ~contractName="B") :> Internal.onEventRegistration),
]

describe("AddressStore", () => {
  it("counts, looks up, and rolls back per contract", t => {
    let store = TestAddresses.makeStore(
      ~onEventRegistrations,
      ~addresses=[
        contract(~address=addr(0), ~contractName="A", ~registrationBlock=-1),
        contract(~address=addr(1), ~contractName="A", ~registrationBlock=5),
        contract(~address=addr(2), ~contractName="B", ~registrationBlock=8),
      ],
    )

    // Roll back to block 6: drops B's addr(2) (registered at 8), keeps A's addr(1) (at 5).
    let rolledBack = store->AddressStore.rollback(6)

    t.expect({
      // What the storage has to delete: the one registration that died.
      "rolledBackContractIds": rolledBack->Array.map(({contractId}) => contractId),
      "countA": store->AddressStore.contractCount("A"),
      "countB": store->AddressStore.contractCount("B"),
      "size": store->AddressStore.size,
      // Lookup finds every contract holding an address.
      "ownersOfAddr1": store->AddressStore.getAll(addr(1))->Array.map(ia => ia.contractName),
      "addr2Gone": store->AddressStore.getAll(addr(2))->Utils.Array.isEmpty,
      "addressesOfA": store->AddressStore.contractAddresses("A"),
      "addressesOfMissing": store->AddressStore.contractAddresses("MISSING"),
    }).toEqual({
      "rolledBackContractIds": [1],
      "countA": 2,
      "countB": 0,
      "size": 2,
      "ownersOfAddr1": ["A"],
      "addr2Gone": true,
      // Set order is (effectiveStartBlock, address): addr(0) starts at 0,
      // addr(1) at its registration block.
      "addressesOfA": [addr(0), addr(1)],
      "addressesOfMissing": [],
    })
  })

  it("gates lookups on the contract and the effective start block", t => {
    let store = TestAddresses.makeStore(
      ~onEventRegistrations,
      ~addresses=[
        contract(~address=addr(0), ~contractName="A", ~registrationBlock=-1),
        contract(~address=addr(1), ~contractName="A", ~registrationBlock=10),
      ],
    )
    t.expect({
      // Config address (effectiveStartBlock 0) at block 5.
      "configAddress": store->AddressStore.isIndexedAt(addr(0), "A", 5),
      "unregistered": store->AddressStore.isIndexedAt(addr(9), "A", 5),
      // addr(1) registered at block 10: dropped before, kept at, its start block.
      "beforeRegistration": store->AddressStore.isIndexedAt(addr(1), "A", 9),
      "atRegistration": store->AddressStore.isIndexedAt(addr(1), "A", 10),
      // Registered, but for a different contract.
      "wrongContract": store->AddressStore.isIndexedAt(addr(0), "B", 5),
    }).toEqual({
      "configAddress": true,
      "unregistered": false,
      "beforeRegistration": false,
      "atRegistration": true,
      "wrongContract": false,
    })
  })

  it("scopes containsAt to the set, leaving the chain-wide gate on the store", t => {
    let store = TestAddresses.makeStore(
      ~onEventRegistrations,
      ~addresses=[
        contract(~address=addr(0), ~contractName="A", ~registrationBlock=-1),
        contract(~address=addr(1), ~contractName="A", ~registrationBlock=10),
      ],
    )
    let set = TestAddresses.setOf(~store, [addr(0)])
    t.expect({
      "inSet": set->AddressSet.containsAt(addr(0), "A", 5),
      // Registered for A, but held by another partition.
      "outOfSet": set->AddressSet.containsAt(addr(1), "A", 10),
      // The chain-wide gate lives on the store, so a set can't be asked it.
      "outOfSetChainWide": store->AddressStore.isIndexedAt(addr(1), "A", 10),
      // In the set, but registered under a different contract.
      "inSetWrongContract": set->AddressSet.containsAt(addr(0), "B", 5),
    }).toEqual({
      "inSet": true,
      "outOfSet": false,
      "outOfSetChainWide": true,
      "inSetWrongContract": false,
    })
  })

  it("keeps a contract unrestricted when any registration has no start block", t => {
    let reg = (~contractName, ~startBlock=?, ~isWildcard=false) =>
      (EventRegistration.evmOnEventRegistration(
        ~id=contractName,
        ~contractName,
        ~startBlock?,
        ~isWildcard,
      ) :> Internal.onEventRegistration)

    t.expect({
      // A `None` start block is unrestricted, so it wins over any `Some`
      // whichever order the registrations arrive in.
      "noneThenSome": AddressStore.contractsOf(
        ~onEventRegistrations=[reg(~contractName="A"), reg(~contractName="A", ~startBlock=100)],
        ~contractMapping=ContractMapping.make(~names=["A"]),
      ),
      "someThenNone": AddressStore.contractsOf(
        ~onEventRegistrations=[reg(~contractName="A", ~startBlock=100), reg(~contractName="A")],
        ~contractMapping=ContractMapping.make(~names=["A"]),
      ),
      "allRestricted": AddressStore.contractsOf(
        ~onEventRegistrations=[
          reg(~contractName="A", ~startBlock=100),
          reg(~contractName="A", ~startBlock=50),
        ],
        ~contractMapping=ContractMapping.make(~names=["A"]),
      ),
      // Contracts stay independent, and their ids follow the canonical list
      // rather than the order registrations arrive in.
      "perContract": AddressStore.contractsOf(
        ~onEventRegistrations=[
          reg(~contractName="B", ~startBlock=100),
          reg(~contractName="A"),
          reg(~contractName="B", ~startBlock=50),
        ],
        ~contractMapping=ContractMapping.make(~names=["A", "B"]),
      ),
      // A contract only the config names is registrable but never fetched.
      "configOnly": AddressStore.contractsOf(
        ~onEventRegistrations=[reg(~contractName="A")],
        ~contractMapping=ContractMapping.make(~names=["A", "NoEvents"]),
      ),
      // A wildcard event is fetched without consulting addresses, so
      // registering one changes nothing about what's queried.
      "wildcardOnly": AddressStore.contractsOf(
        ~onEventRegistrations=[reg(~contractName="A", ~isWildcard=true)],
        ~contractMapping=ContractMapping.make(~names=["A"]),
      ),
    }).toEqual({
      "noneThenSome": [
        ({name: "A", startBlock: None, dependsOnAddresses: true}: AddressStore.contract),
      ],
      "someThenNone": [
        ({name: "A", startBlock: None, dependsOnAddresses: true}: AddressStore.contract),
      ],
      "allRestricted": [
        ({name: "A", startBlock: Some(50), dependsOnAddresses: true}: AddressStore.contract),
      ],
      "perContract": [
        ({name: "A", startBlock: None, dependsOnAddresses: true}: AddressStore.contract),
        ({name: "B", startBlock: Some(50), dependsOnAddresses: true}: AddressStore.contract),
      ],
      "configOnly": [
        ({name: "A", startBlock: None, dependsOnAddresses: true}: AddressStore.contract),
        ({name: "NoEvents", startBlock: None, dependsOnAddresses: false}: AddressStore.contract),
      ],
      "wildcardOnly": [
        ({name: "A", startBlock: None, dependsOnAddresses: false}: AddressStore.contract),
      ],
    })
  })

  it("gives a batch's additions their own set, ordered independently of arrival", t => {
    let store = TestAddresses.makeStore(
      ~onEventRegistrations,
      ~configContractNames=["NoEvents"],
    )
    let cursor = store->AddressStore.nextId
    let verdicts =
      store->AddressStore.registerBatch(
        [
          {address: addr(3), contractName: "B", registrationBlock: 30},
          {address: addr(4), contractName: "B", registrationBlock: 10},
          // Same address again: a duplicate, not a second registration.
          {address: addr(3), contractName: "B", registrationBlock: 30},
          // A contract with no events: registered like any other, the fetch
          // state is what decides nothing is queried for it.
          {address: addr(5), contractName: "NoEvents", registrationBlock: 40},
        ],
      )
    let added = store->AddressStore.makeSet(~contractName="B", ~options={minId: cursor})
    t.expect({
      "verdicts": verdicts,
      "added": added->AddressSet.addresses,
      "noEventsIsStillReported": store->AddressStore.contractAddresses("NoEvents"),
      "size": store->AddressStore.size,
    }).toEqual({
      "verdicts": [
        AddressStore.Added({effectiveStartBlock: 30, fetchable: true}),
        Added({effectiveStartBlock: 10, fetchable: true}),
        Duplicate({effectiveStartBlock: 30, existingEffectiveStartBlock: 30}),
        // Registered and persisted, but nothing on this chain fetches for it.
        Added({effectiveStartBlock: 40, fetchable: false}),
      ],
      // Ordered by effectiveStartBlock, so addr(4) (10) precedes addr(3) (30).
      "added": [addr(4), addr(3)],
      "noEventsIsStillReported": [addr(5)],
      "size": 3,
    })
  })

  it("throws for a contract the chain doesn't index", t => {
    let store = TestAddresses.makeStore(~onEventRegistrations)
    t.expect(
      () =>
        store->AddressStore.registerBatch(
          [{address: addr(3), contractName: "Missing", registrationBlock: 7}],
        ),
    ).toThrow()
  })

  it("only hands over registrations the database hasn't seen", t => {
    let store = TestAddresses.makeStore(
      ~onEventRegistrations,
      ~addresses=[contract(~address=addr(0), ~contractName="A", ~registrationBlock=-1)],
    )
    let _ =
      store->AddressStore.registerBatch([
        {address: addr(1), contractName: "A", registrationBlock: 10},
        {address: addr(2), contractName: "A", registrationBlock: 30},
      ])

    let drain = (~toBlockInclusive, ~checkpointBlockNumbers) =>
      store
      ->AddressStore.drainForWrite(toBlockInclusive, checkpointBlockNumbers)
      ->Array.map(dc => (dc.contractId, dc.checkpointIdx))

    t.expect({
      // The config address was never pending, and addr(2) is above the bound.
      "upToBlock20": drain(~toBlockInclusive=20, ~checkpointBlockNumbers=[5, 10]),
      "drainedOnce": drain(~toBlockInclusive=20, ~checkpointBlockNumbers=[5, 10]),
      "rest": drain(~toBlockInclusive=30, ~checkpointBlockNumbers=[30]),
      "nothingLeftPending": store->AddressStore.pendingEntries,
    }).toEqual({
      // The checkpoint index points back at the block numbers passed in.
      "upToBlock20": [(0, 1)],
      "drainedOnce": [],
      "rest": [(0, 0)],
      "nothingLeftPending": [],
    })
  })

  it("refuses to drain a registration the batch has no checkpoint for", t => {
    let store = TestAddresses.makeStore(~onEventRegistrations)
    let _ =
      store->AddressStore.registerBatch([
        {address: addr(1), contractName: "A", registrationBlock: 10},
      ])

    let threw = try {
      let _ = store->AddressStore.drainForWrite(20, [9])
      false
    } catch {
    | _ => true
    }
    t.expect(
      // The failed drain consumed nothing, so the registration is still there
      // to be written by a batch that does cover it.
      (threw, store->AddressStore.pendingEntries->Array.map(ia => ia.address)),
      ~message="a failed drain leaves the queue intact",
    ).toEqual((true, [addr(1)]))
  })

  // https://github.com/enviodev/hyperindex/issues/1187
  it("registers an address already held by another contract", t => {
    let store = TestAddresses.makeStore(
      ~onEventRegistrations,
      ~addresses=[contract(~address=addr(0), ~contractName="A", ~registrationBlock=-1)],
    )
    t.expect({
      "verdicts": store->AddressStore.registerBatch([
        {address: addr(0), contractName: "B", registrationBlock: 7},
        {address: addr(0), contractName: "B", registrationBlock: 9},
      ]),
      "ownersOfAddr0": store->AddressStore.getAll(addr(0))->Array.map(ia => ia.contractName),
      "indexedForA": store->AddressStore.isIndexedAt(addr(0), "A", 7),
      "indexedForB": store->AddressStore.isIndexedAt(addr(0), "B", 7),
      // B's registration only starts where it was registered.
      "indexedForBBefore": store->AddressStore.isIndexedAt(addr(0), "B", 6),
      "size": store->AddressStore.size,
    }).toEqual({
      "verdicts": [
        AddressStore.Added({effectiveStartBlock: 7, fetchable: true}),
        Duplicate({effectiveStartBlock: 9, existingEffectiveStartBlock: 7}),
      ],
      "ownersOfAddr0": ["A", "B"],
      "indexedForA": true,
      "indexedForB": true,
      "indexedForBBefore": false,
      "size": 2,
    })
  })

  // https://github.com/enviodev/hyperindex/issues/1187
  it("indexes a config address listed under two contracts", t => {
    let addresses = [
      contract(~address=addr(0), ~contractName="A", ~registrationBlock=-1),
      contract(~address=addr(0), ~contractName="B", ~registrationBlock=-1),
      contract(~address=addr(1), ~contractName="B", ~registrationBlock=-1),
    ]
    let contractMapping = TestAddresses.contractMapping(~onEventRegistrations)
    let store = AddressStore.make(
      ~ecosystem=Evm,
      ~shouldChecksum=true,
      ~contracts=AddressStore.contractsOf(~onEventRegistrations, ~contractMapping),
    )
    let fetchState = FetchState.make(
      ~onEventRegistrations,
      ~addressStore=store,
      ~addressRows=TestAddresses.addressRows(~addresses, ~onEventRegistrations),
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=10,
      ~maxOnBlockBufferSize=10,
      ~chainId=1->ChainId.fromInt,
      ~knownHeight=100,
    )
    t.expect({
      "addressesOfA": store->AddressStore.contractAddresses("A"),
      "addressesOfB": store->AddressStore.contractAddresses("B"),
      "size": store->AddressStore.size,
      // Both contracts start at 0, so one partition covers them — sharing an
      // address doesn't split it.
      "partitions": fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count,
    }).toEqual({
      "addressesOfA": [addr(0)],
      // Set order at equal start blocks is by address bytes.
      "addressesOfB": [addr(1), addr(0)],
      "size": 3,
      "partitions": 1,
    })
  })

  it("builds the same sets whatever order the addresses arrive in", t => {
    // A restored indexer registers everything in one batch and in a different
    // order than a live run did; the partitions it rebuilds must be identical.
    let addresses = [
      contract(~address=addr(0), ~contractName="A", ~registrationBlock=30),
      contract(~address=addr(1), ~contractName="A", ~registrationBlock=10),
      contract(~address=addr(2), ~contractName="A", ~registrationBlock=20),
    ]
    let entriesOf = addresses =>
      (TestAddresses.makeStore(~onEventRegistrations, ~addresses))
      ->AddressStore.makeSet(~contractName="A")
      ->AddressSet.entries

    t.expect({
      "reversed": entriesOf(addresses->Array.toReversed),
      "rotated": entriesOf([
        addresses->Array.getUnsafe(1),
        addresses->Array.getUnsafe(2),
        addresses->Array.getUnsafe(0),
      ]),
    }).toEqual({
      "reversed": entriesOf(addresses),
      "rotated": entriesOf(addresses),
    })
  })
})
