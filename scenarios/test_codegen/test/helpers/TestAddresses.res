// Address-store scaffolding for the fetch-state tests. Mirrors what
// `ChainState.makeInternal` does in production: one store per chain, built from
// that chain's registrations, holding every address the chain indexes.

let makeStore = (
  ~onEventRegistrations: array<Internal.onEventRegistration>=[],
  ~addresses: array<Internal.indexingAddress>=[],
  ~ecosystem: Ecosystem.name=Evm,
  ~shouldChecksum=false,
) => {
  let store = AddressStore.make(
    ~ecosystem,
    ~shouldChecksum,
    ~contracts=AddressStore.contractsOf(~onEventRegistrations),
  )
  let _ = store->AddressStore.registerBatch(
    addresses->Array.map((contract): AddressStore.registration => {
      address: contract.address,
      contractName: contract.contractName,
      registrationBlock: contract.registrationBlock,
    }),
  )
  store
}

// A partition's addresses are a Rust `AddressSet` handle, which carries no own
// properties and so isn't structurally comparable. Both sides of an assertion
// go through `partition`/`partitions` below, which swap the handle for the
// addresses it holds — in set order, which is
// `(effectiveStartBlock, address)`, not insertion order.
external unsafeSet: array<Address.t> => AddressSet.t = "%identity"

let partition = (p: FetchState.partition): FetchState.partition => {
  ...p,
  addresses: p.addresses->AddressSet.addresses->unsafeSet,
}

let partitions = (optimizedPartitions: FetchState.OptimizedPartitions.t) => {
  ...optimizedPartitions,
  entities: optimizedPartitions.entities->Utils.Dict.mapValues(partition),
}

let query = (q: FetchState.query): FetchState.query => {
  ...q,
  addresses: q.addresses->AddressSet.addresses->unsafeSet,
}

let queries = (qs: array<FetchState.query>) => qs->Array.map(query)
