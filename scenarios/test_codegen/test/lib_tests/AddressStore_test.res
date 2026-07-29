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
  (MockIndexer.evmOnEventRegistration(~id="0", ~contractName="A") :> Internal.onEventRegistration),
  (MockIndexer.evmOnEventRegistration(~id="1", ~contractName="B") :> Internal.onEventRegistration),
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
    let removed = store->AddressStore.rollback(6)

    t.expect({
      "removed": removed,
      "countA": store->AddressStore.contractCount("A"),
      "countB": store->AddressStore.contractCount("B"),
      "size": store->AddressStore.size,
      // Lookup finds an address whichever contract holds it.
      "ownerOfAddr1": (store->AddressStore.get(addr(1)))->Option.map(ia => ia.contractName),
      "addr2Gone": (store->AddressStore.get(addr(2)))->Option.isNone,
      "addressesOfA": store->AddressStore.contractAddresses("A"),
      "addressesOfMissing": store->AddressStore.contractAddresses("MISSING"),
    }).toEqual({
      "removed": 1,
      "countA": 2,
      "countB": 0,
      "size": 2,
      "ownerOfAddr1": Some("A"),
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
    let set = store->AddressStore.makeSetOf([addr(0)])
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
    let reg = (~contractName, ~startBlock=?) =>
      (MockIndexer.evmOnEventRegistration(
        ~id=contractName,
        ~contractName,
        ~startBlock?,
      ) :> Internal.onEventRegistration)

    t.expect({
      // A `None` start block is unrestricted, so it wins over any `Some`
      // whichever order the registrations arrive in.
      "noneThenSome": AddressStore.contractsOf(
        ~onEventRegistrations=[reg(~contractName="A"), reg(~contractName="A", ~startBlock=100)],
      ),
      "someThenNone": AddressStore.contractsOf(
        ~onEventRegistrations=[reg(~contractName="A", ~startBlock=100), reg(~contractName="A")],
      ),
      "allRestricted": AddressStore.contractsOf(
        ~onEventRegistrations=[
          reg(~contractName="A", ~startBlock=100),
          reg(~contractName="A", ~startBlock=50),
        ],
      ),
      // Contracts stay independent, in first-registration order.
      "perContract": AddressStore.contractsOf(
        ~onEventRegistrations=[
          reg(~contractName="B", ~startBlock=100),
          reg(~contractName="A"),
          reg(~contractName="B", ~startBlock=50),
        ],
      ),
    }).toEqual({
      "noneThenSome": [({name: "A", startBlock: None}: AddressStore.contract)],
      "someThenNone": [({name: "A", startBlock: None}: AddressStore.contract)],
      "allRestricted": [({name: "A", startBlock: Some(50)}: AddressStore.contract)],
      "perContract": [
        ({name: "B", startBlock: Some(50)}: AddressStore.contract),
        ({name: "A", startBlock: None}: AddressStore.contract),
      ],
    })
  })

  it("gives a batch's additions their own set, ordered independently of arrival", t => {
    let store = TestAddresses.makeStore(~onEventRegistrations)
    let cursor = store->AddressStore.nextId
    let verdicts = store->AddressStore.registerBatch([
      {address: addr(3), contractName: "B", registrationBlock: 30},
      {address: addr(4), contractName: "B", registrationBlock: 10},
      // Same address again: a duplicate, not a second registration.
      {address: addr(3), contractName: "B", registrationBlock: 30},
      // A contract with no events: persisted, never fetched.
      {address: addr(5), contractName: "NoEvents", registrationBlock: 40},
    ])
    let added = store->AddressStore.makeSet(~contractName="B", ~options={minId: cursor})
    t.expect({
      "verdicts": verdicts,
      "added": added->AddressSet.addresses,
      // A no-events address is never fetched — it has no set — but it's still
      // registered, so the chain reports and persists it.
      "noEventsIsNotFetched": (store->AddressStore.makeSet(~contractName="NoEvents"))
        ->AddressSet.size,
      "noEventsIsStillReported": store->AddressStore.contractAddresses("NoEvents"),
      // No-events addresses still count towards what the chain tracks.
      "size": store->AddressStore.size,
    }).toEqual({
      "verdicts": [
        AddressStore.Added({effectiveStartBlock: 30}),
        Added({effectiveStartBlock: 10}),
        Duplicate({effectiveStartBlock: 30, existingEffectiveStartBlock: 30}),
        NoEvents({effectiveStartBlock: 40}),
      ],
      // Ordered by effectiveStartBlock, so addr(4) (10) precedes addr(3) (30).
      "added": [addr(4), addr(3)],
      "noEventsIsNotFetched": 0,
      "noEventsIsStillReported": [addr(5)],
      "size": 3,
    })
  })

  it("rejects an address already held by another contract", t => {
    let store = TestAddresses.makeStore(
      ~onEventRegistrations,
      ~addresses=[contract(~address=addr(0), ~contractName="A", ~registrationBlock=-1)],
    )
    t.expect(
      store->AddressStore.registerBatch([
        {address: addr(0), contractName: "B", registrationBlock: 7},
      ]),
    ).toEqual([AddressStore.Conflict({existingContractName: "A"})])
  })

  it("drops config addresses the store rejects, without failing startup", t => {
    // Config addresses go through the same verdicts as dynamic ones, so a
    // config listing one address under two contracts (or a malformed one) has
    // to leave the chain indexing what it can rather than throwing.
    let addresses = [
      contract(~address=addr(0), ~contractName="A", ~registrationBlock=-1),
      // Already held by A.
      contract(~address=addr(0), ~contractName="B", ~registrationBlock=-1),
      contract(~address="not-an-address"->Utils.magic, ~contractName="B", ~registrationBlock=-1),
      contract(~address=addr(1), ~contractName="B", ~registrationBlock=-1),
    ]
    let store = AddressStore.make(
      ~ecosystem=Evm,
      ~shouldChecksum=true,
      ~contracts=AddressStore.contractsOf(~onEventRegistrations),
    )
    let fetchState = FetchState.make(
      ~onEventRegistrations,
      ~addressStore=store,
      ~addresses,
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=10,
      ~maxOnBlockBufferSize=10,
      ~chainId=1->ChainId.fromInt,
      ~knownHeight=100,
    )
    t.expect({
      "addressesOfA": store->AddressStore.contractAddresses("A"),
      // Only the address B actually won; the conflicting and the malformed
      // ones are gone.
      "addressesOfB": store->AddressStore.contractAddresses("B"),
      "size": store->AddressStore.size,
      // Both survivors are config addresses starting at block 0, so they share
      // one partition — the point is that startup got that far at all.
      "partitions": fetchState.optimizedPartitions->FetchState.OptimizedPartitions.count,
    }).toEqual({
      "addressesOfA": [addr(0)],
      "addressesOfB": [addr(1)],
      "size": 2,
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
