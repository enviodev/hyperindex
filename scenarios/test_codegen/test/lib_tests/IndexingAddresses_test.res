open Vitest

let addr = i => Envio.TestHelpers.Addresses.mockAddresses[i]->Option.getOrThrow

let contract = (~address, ~contractName, ~registrationBlock): Internal.indexingAddress => {
  address,
  contractName,
  registrationBlock,
}

// One event per contract so makeContractConfigs knows both contract names.
let onEventRegistrations = [
  (MockIndexer.evmOnEventRegistration(~id="0", ~contractName="A") :> Internal.onEventRegistration),
  (MockIndexer.evmOnEventRegistration(~id="1", ~contractName="B") :> Internal.onEventRegistration),
]
let contractConfigs = IndexingAddresses.makeContractConfigs(~onEventRegistrations)

describe("IndexingAddresses nested structure", () => {
  it("counts, looks up, filters, and rolls back per contract", t => {
    let index =
      IndexingAddresses.make(
        ~contractConfigs,
        ~addresses=[
          contract(~address=addr(0), ~contractName="A", ~registrationBlock=-1),
          contract(~address=addr(1), ~contractName="A", ~registrationBlock=5),
          contract(~address=addr(2), ~contractName="B", ~registrationBlock=8),
        ],
      )

    // Roll back to block 6: drops B's addr(2) (registered at 8), keeps A's addr(1) (at 5).
    index->IndexingAddresses.rollbackInPlace(~targetBlockNumber=6)

    t.expect((
      // Per-contract counts are O(1) inner-dict sizes.
      index->IndexingAddresses.contractCount(~contractName="A"),
      index->IndexingAddresses.contractCount(~contractName="B"),
      index->IndexingAddresses.size,
      // get walks the small contract set and finds an address regardless of contract.
      (index->IndexingAddresses.get(addr(1)->Address.toString))->Option.map(ia => ia.contractName),
      (index->IndexingAddresses.get(addr(2)->Address.toString))->Option.isNone,
      // forContract returns the contract's own address->entry dict.
      index->IndexingAddresses.forContract(~contractName="A")->Dict.keysToArray->Array.length,
      index->IndexingAddresses.forContract(~contractName="MISSING")->Dict.keysToArray,
    )).toEqual((2, 0, 2, Some("A"), true, 2, []))
  })

  it("the generated clientAddressFilter gates against the contract's own forContract dict", t => {
    // A non-wildcard event's filter checks the srcAddress is registered at/before
    // the log's block. It reads the address->entry dict directly, so scoping it
    // per contract via forContract must preserve the gate.
    let filter =
      EventConfigBuilder.buildAddressFilter([], ~isWildcard=false)->Option.getOrThrow
    let index =
      IndexingAddresses.make(
        ~contractConfigs,
        ~addresses=[
          contract(~address=addr(0), ~contractName="A", ~registrationBlock=-1),
          contract(~address=addr(1), ~contractName="A", ~registrationBlock=10),
        ],
      )
    let byAddr = index->IndexingAddresses.forContract(~contractName="A")
    let payload = srcAddress =>
      {"srcAddress": srcAddress}->(Utils.magic: {..} => Internal.eventPayload)

    t.expect((
      // Registered config address (effectiveStartBlock 0) at block 5.
      filter(payload(addr(0)), 5, byAddr),
      // Unregistered address is dropped.
      filter(payload(addr(9)), 5, byAddr),
      // addr(1) registered at block 10: dropped before, kept at, its start block.
      filter(payload(addr(1)), 9, byAddr),
      filter(payload(addr(1)), 10, byAddr),
    )).toEqual((true, false, false, true))
  })

  it("register groups additions by each entry's contract name", t => {
    let index = IndexingAddresses.make(~contractConfigs, ~addresses=[])
    let additions = Dict.fromArray([
      (
        addr(3)->Address.toString,
        IndexingAddresses.makeIndexingAddress(
          ~contract=contract(~address=addr(3), ~contractName="B", ~registrationBlock=1),
          ~contractConfigs,
        ),
      ),
    ])
    index->IndexingAddresses.register(additions)
    t.expect(
      index->IndexingAddresses.forContract(~contractName="B")->Dict.keysToArray,
      ~message="registered address lands under its own contract",
    ).toEqual([addr(3)->Address.toString])
  })
})
