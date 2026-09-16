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

@send external addresses: t => array<Address.t> = "addresses"

@send external entries: t => array<Internal.indexingContract> = "entries"

let isEmpty = (set: t) => set->size === 0
