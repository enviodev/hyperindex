// Address-store scaffolding for the source tests. `makeStore` mirrors what
// `ChainState.makeInternal` does in production: one store per chain, built from
// that chain's registrations, holding every address the chain indexes.

// The contract mapping a chain's store is built from — every contract the
// config declares, under the ids their names canonicalize to.
let contractMapping = (
  ~onEventRegistrations: array<Internal.onEventRegistration>=[],
  // Config contracts the chain has no events for. Registering an address for a
  // name outside the store's contracts throws, so a test exercising the
  // no-events path declares it here.
  ~configContractNames: array<string>=[],
) =>
  ContractMapping.make(
    ~names=onEventRegistrations
    ->Array.map(reg => reg.eventConfig.contractName)
    ->Array.concat(configContractNames),
  )

// An address a chain indexes, as its store's seed rows hold it. -1 is a config
// address.
type address = {
  address: Address.t,
  contractName: string,
  registrationBlock: int,
}

// Registrations in the columnar form the store seeds from: keys encoded by the
// Rust codec, contract ids resolved by `contractId`.
let rowsOf = (
  ~addresses: array<address>,
  ~contractId: string => int,
  ~ecosystem: Ecosystem.name,
): AddressRows.seedRows => {
  let keys = Core.getAddon().encodeAddresses(
    ~ecosystem=(ecosystem :> string),
    ~addresses=addresses->Array.map(a => a.address),
  )
  addresses
  ->Array.mapWithIndex((a, idx): AddressRows.row => {
    // The seed form is per-chain, so any chain id serves — `seedRowsOf` drops it.
    chainId: ChainId.fromInt(0),
    address: keys->Array.getUnsafe(idx),
    contractId: contractId(a.contractName),
    registrationBlock: a.registrationBlock,
  })
  ->AddressRows.seedRowsOf
}

// A store over `contracts` holding `addresses` as config addresses, seeded
// through `seedRows` - the only way in the store has for an address the
// database already holds.
let storeOf = (
  ~contracts: array<AddressStore.contract>,
  ~addresses: array<address>=[],
  ~ecosystem: Ecosystem.name=Evm,
) => {
  let store = AddressStore.make(~ecosystem, ~contracts)
  let _ = store->AddressStore.seedRows(
    rowsOf(
      ~addresses,
      // A row's contract id is its contract's position in the store's own list.
      ~contractId=name =>
        switch contracts->Array.findIndex(c => c.name === name) {
        | -1 =>
          JsError.throwWithMessage(`Contract "${name}" isn't among the test store's contracts`)
        | idx => idx
        },
      ~ecosystem,
    ),
  )
  store
}

// A store built from a chain's registrations, the way `ChainState.makeInternal`
// does.
let makeStore = (
  ~onEventRegistrations: array<Internal.onEventRegistration>=[],
  ~addresses: array<address>=[],
  ~ecosystem: Ecosystem.name=Evm,
  ~configContractNames: array<string>=[],
) =>
  storeOf(
    ~contracts=AddressStore.contractsOf(
      ~onEventRegistrations,
      ~contractMapping=contractMapping(~onEventRegistrations, ~configContractNames),
    ),
    ~addresses,
    ~ecosystem,
  )

// The store's own spelling of an address. Fixtures are written with the
// checksummed mock addresses, so an expected value compared against a store
// read goes through here.
let canonical = (addresses: array<Address.t>) =>
  addresses->Array.map(a => a->Address.toString->String.toLowerCase->Address.unsafeFromString)
