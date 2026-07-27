// Binding to the Rust `AddressSet` napi class: an immutable, ordered snapshot
// of some of a chain's indexed addresses, handed to a fetch-state partition
// instead of a JS address array. Sets are ordered by
// `(effectiveStartBlock, address)`, so the same addresses always produce the
// same set however they were registered or restored. Everything a query derives
// from one (padded topics, the routing owner index, per-contract counts) is
// built once inside Rust and shared by every query the partition makes.
type t

type startBlockGroup = {startBlock: int, count: int}

@send external size: t => int = "size"

// Live addresses of one contract, derived once per set inside Rust — so the
// fetch state can size and split partitions without ever walking the addresses.
@send external countFor: (t, string) => int = "countFor"

// The chain-wide address gate, reachable through any set of the store. Not set
// membership: the simulate source has no native query boundary, so it applies
// the same gate every real source applies while routing.
@send external has: (t, Address.t, string, int) => bool = "has"

@send external contractNames: t => array<string> = "contractNames"

// Distinct effective start blocks in this set, ascending — how partition
// creation decides where one partition ends and the next begins.
@send external startBlockGroups: t => array<startBlockGroup> = "startBlockGroups"

@send external slice: (t, ~offset: int, ~limit: option<int>) => t = "slice"

// Keeps only the named contracts' addresses, in set order.
@send external filterByContracts: (t, array<string>) => t = "filterByContracts"

// Drops addresses registered after the target block, and any the store has
// tombstoned since this set was built.
@send external filterByRegistrationBlock: (t, int) => t = "filterByRegistrationBlock"

// Union with another set of the same store, keeping set order; duplicates
// collapse.
@send external merge: (t, t) => t = "merge"

// Canonical address strings in set order. Not on a query path — queries read
// the set's cached slices inside Rust.
@send external addresses: t => array<Address.t> = "addresses"

@send external entries: t => array<Internal.indexingContract> = "entries"

let isEmpty = (set: t) => set->size === 0
