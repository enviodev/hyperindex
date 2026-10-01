type t

type startBlockGroup = {startBlock: int, count: int}

@send external size: t => int = "size"

@send external countFor: (t, string) => int = "countFor"

@send external containsAt: (t, Address.t, string, int) => bool = "containsAt"

@send external contractNames: t => array<string> = "contractNames"

@send external startBlockGroups: t => array<startBlockGroup> = "startBlockGroups"

@send external slice: (t, ~offset: int, ~limit: option<int>) => t = "slice"

@send external filterByContracts: (t, array<string>) => t = "filterByContracts"

@send external filterByRegistrationBlock: (t, int) => t = "filterByRegistrationBlock"

@send external merge: (t, t) => t = "merge"

// For assertions only - nothing in the indexer reads it. A query gets its
// address filter from the set's cached per-contract slices and the runtime asks
// `containsAt`; this is the only way a test can compare two sets by what they
// hold rather than by handle identity.
@send external addressesForTest: t => array<Address.t> = "addressesForTest"

let isEmpty = (set: t) => set->size === 0
