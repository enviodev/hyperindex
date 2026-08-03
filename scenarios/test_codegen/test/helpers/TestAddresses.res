// Address-store scaffolding for the fetch-state tests. `makeStore` mirrors what
// `ChainState.makeInternal` does in production: one store per chain, built from
// that chain's registrations, holding every address the chain indexes.

let makeStore = (
  ~onEventRegistrations: array<Internal.onEventRegistration>=[],
  ~addresses: array<Internal.indexingAddress>=[],
  ~ecosystem: Ecosystem.name=Evm,
  // Config contracts the chain has no events for. Registering an address for a
  // name outside the store's contracts throws, so a test exercising the
  // no-events path declares it here.
  ~configContractNames: array<string>=[],
  // Matches the common `lowercaseAddresses: false`, so entries render like the
  // checksummed mock addresses the tests use.
  ~shouldChecksum=true,
) => {
  let store = AddressStore.make(
    ~ecosystem,
    ~shouldChecksum,
    ~contracts=AddressStore.contractsOf(~onEventRegistrations, ~configContractNames),
  )
  // Config addresses, like `FetchState.make` seeds them: already stored, so
  // they never drain back into a write.
  let _ = store->AddressStore.seedBatch(
    addresses->Array.map((contract): AddressStore.registration => {
      address: contract.address,
      contractName: contract.contractName,
      registrationBlock: contract.registrationBlock,
    }),
  )
  store
}

// A real `AddressSet` is a Rust handle: it carries no own properties, so two of
// them always compare equal. Expected-value fixtures need something `toEqual`
// compares by contents instead, so `setOf` hands back a double whose addresses
// live in an own enumerable property and whose methods are non-enumerable.
//
// Assertions run both sides through `partition`/`query`/`fetchState`/`nextQuery`
// below, which turn a real handle into the same shape.
//
// A fixture that stands in for state the fetch state will go on to *operate* on
// (merge, split, roll back) must pass `~store` instead: those operations resolve
// each address against the store that owns it, so only a real set of that store
// behaves like production.
//
// The owning contract name isn't cosmetic either — the fetch state groups and
// splits partitions by it (`countFor`, `contractNames`), so a fixture whose
// addresses belong to another contract than it claims takes a different path.
let fakeSetOf: (~contractName: string=?, array<Address.t>) => AddressSet.t = %raw(`
function (contractName, addresses) {
  var owner = contractName === undefined ? "Gravatar" : contractName;
  return makeFakeSet(
    addresses.map(function (address) { return {address: address, contractName: owner} })
  );
}`)

let setOf = (~store: option<AddressStore.t>=?, ~contractName=?, addresses) =>
  switch store {
  | Some(store) => store->AddressStore.makeSetOf(addresses)
  | None => fakeSetOf(~contractName?, addresses)
  }

%%raw(`
function makeFakeSet(unordered) {
  // Set order: fixtures are all config addresses, so they share an effective
  // start block and order by address alone. Applied to both sides of an
  // assertion, so a partition's contents compare regardless of how the fixture
  // listed them; the ordering rule itself is asserted in AddressStore_test.
  var entries = unordered.slice().sort(function (a, b) {
    return a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1;
  });
  // Enumerable, so vitest compares two of these by the addresses they hold.
  var set = {addressList: entries.map(function (e) { return e.address })};
  var methods = {
    addresses: function () { return set.addressList },
    size: function () { return entries.length },
    contractNames: function () {
      var names = [];
      entries.forEach(function (e) {
        if (!names.includes(e.contractName)) names.push(e.contractName);
      });
      return names;
    },
    countFor: function (name) {
      return entries.filter(function (e) { return e.contractName === name }).length;
    },
    filterByContracts: function (names) {
      return makeFakeSet(entries.filter(function (e) { return names.includes(e.contractName) }));
    },
    filterByRegistrationBlock: function () {
      throw new Error(
        "A fixture set doesn't know its registration blocks. Build it with ~store so rollback prunes it like production does."
      );
    },
    slice: function (offset, limit) {
      return makeFakeSet(entries.slice(offset, limit === undefined ? undefined : offset + limit));
    },
    merge: function (other) {
      if (other.__entries === undefined) {
        throw new Error(
          "Can't merge a fixture set with a real one. Build the fixture with ~store so both belong to the same address store."
        );
      }
      var merged = entries.slice();
      other.__entries.forEach(function (e) {
        if (!merged.some(function (m) { return m.address === e.address })) merged.push(e);
      });
      return makeFakeSet(merged);
    },
    startBlockGroups: function () { return [{startBlock: 0, count: entries.length}] },
  };
  var descriptors = {__entries: {value: entries}};
  Object.keys(methods).forEach(function (key) { descriptors[key] = {value: methods[key]} });
  Object.defineProperties(set, descriptors);
  return set;
}`)

// A real handle in the same shape, so both sides of an assertion compare by
// the addresses they hold rather than by handle identity.
let comparable: AddressSet.t => AddressSet.t = %raw(`function (set) {
  if (!(set instanceof Object) || typeof set.addresses !== "function") return set;
  if (set.__entries !== undefined) return set;
  var entries = [];
  set.contractNames().forEach(function (contractName) {
    set.filterByContracts([contractName]).addresses().forEach(function (address) {
      entries.push({address: address, contractName: contractName});
    });
  });
  // Set order, not per-contract order.
  var order = set.addresses();
  entries.sort(function (a, b) { return order.indexOf(a.address) - order.indexOf(b.address) });
  return makeFakeSet(entries);
}`)

let partition = (p: FetchState.partition): FetchState.partition => {
  ...p,
  addresses: p.addresses->comparable,
}

let partitions = (optimizedPartitions: FetchState.OptimizedPartitions.t) => {
  ...optimizedPartitions,
  entities: optimizedPartitions.entities->Utils.Dict.mapValues(partition),
}

let query = (q: FetchState.query): FetchState.query => {
  ...q,
  addresses: q.addresses->comparable,
}

let fetchState = (fs: FetchState.t): FetchState.t => {
  ...fs,
  optimizedPartitions: partitions(fs.optimizedPartitions),
}

let queries = (qs: array<FetchState.query>) => qs->Array.map(query)

let nextQuery = (result: FetchState.nextQuery) =>
  switch result {
  | Ready(qs) => FetchState.Ready(queries(qs))
  | other => other
  }
