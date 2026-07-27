// Binding to the Rust `AddressStore` napi class: the chain-wide index of every
// address being indexed, config-declared or dynamically registered. It owns
// registration bookkeeping (conflict detection, `effectiveStartBlock`
// derivation, reorg rollback) and hands out `AddressSet` snapshots for the
// fetch state's partitions. One store lives per chain on `ChainState`, shared
// with that chain's source clients — which read it to drop items whose emitter
// (or address-valued param) isn't registered at the item's block.
type t

// A contract the chain has events for. An address registered for anything else
// gets the `NoEvents` verdict: persisted so a future config that adds events
// picks it up, but never fetched.
type contract = {name: string, startBlock: option<int>}

type registration = {
  address: Address.t,
  contractName: string,
  // -1 for a config address (not dynamically registered).
  registrationBlock: int,
}

type verdict =
  | Added({effectiveStartBlock: int})
  // Contract has no events; tracked and persisted, never fetched.
  | NoEvents({effectiveStartBlock: int})
  // Already registered for the same contract.
  | Duplicate({effectiveStartBlock: int, existingEffectiveStartBlock: int})
  // Already registered for a different contract.
  | Conflict({existingContractName: string})
  // Not a well-formed address for the ecosystem.
  | Invalid

type rawVerdict = {
  kind: string,
  effectiveStartBlock: int,
  existingContractName: Null.t<string>,
  existingEffectiveStartBlock: Null.t<int>,
}

type makeSetOptions = {
  // Only addresses whose id is at or above this. Ids are handed out in
  // registration order, so a cursor read before a batch (`nextId`) selects
  // exactly what that batch added.
  minId?: int,
  // Inclusive effectiveStartBlock bounds.
  fromStartBlock?: int,
  toStartBlock?: int,
  offset?: int,
  limit?: int,
}

@send
external newEvm: (Core.addressStoreCtor, bool, array<contract>) => t = "newEvm"
@send external newSvm: (Core.addressStoreCtor, array<contract>) => t = "newSvm"
@send external newFuel: (Core.addressStoreCtor, array<contract>) => t = "newFuel"

// The store's ecosystem is fixed here, from the chain's config, and decides how
// address strings are parsed and rendered back. EVM carries the chain's
// address-checksumming setting so entries render exactly as the sources do.
let make = (~ecosystem: Ecosystem.name, ~shouldChecksum: bool, ~contracts: array<contract>): t => {
  let ctor = Core.getAddon().addressStore
  switch ecosystem {
  | Evm => ctor->newEvm(shouldChecksum, contracts)
  | Svm => ctor->newSvm(contracts)
  | Fuel => ctor->newFuel(contracts)
  }
}

// The contracts of a chain that have events, with the earliest block any of
// their events may fire at.
let contractsOf = (~onEventRegistrations: array<Internal.onEventRegistration>): array<contract> => {
  let startBlocks = Dict.make()
  let names = []
  onEventRegistrations->Array.forEach(reg => {
    let name = reg.eventConfig.contractName
    switch startBlocks->Utils.Dict.dangerouslyGetNonOption(name) {
    | None =>
      names->Array.push(name)->ignore
      startBlocks->Dict.set(name, reg.startBlock)
    | Some(existing) =>
      startBlocks->Dict.set(
        name,
        switch (existing, reg.startBlock) {
        | (Some(a), Some(b)) => Some(Pervasives.min(a, b))
        | (Some(_) as s, None) | (None, Some(_) as s) => s
        | (None, None) => None
        },
      )
    }
  })
  names->Array.map(name => {name, startBlock: startBlocks->Dict.getUnsafe(name)})
}

@send external nextId: t => int = "nextId"

// A set holding nothing — what an address-free (wildcard) partition carries, so
// every partition is queried through the same handle.
@send external emptySet: t => AddressSet.t = "emptySet"
@send external registerBatchRaw: (t, array<registration>) => array<rawVerdict> = "registerBatch"
@send external makeSetRaw: (t, string, makeSetOptions) => AddressSet.t = "makeSet"
@send
external startBlockGroups: (t, string) => array<AddressSet.startBlockGroup> = "startBlockGroups"
@send external contractCount: (t, string) => int = "contractCount"
@send external size: t => int = "size"

// The gate routing applies, exposed for the simulate source — it has no real
// query boundary to gate at.
@send external has: (t, Address.t, string, int) => bool = "has"

// Drops every address registered after the target block, returning how many
// were dropped. Ids are tombstoned rather than reused, so sets built before the
// rollback still point at the right entries.
@send external rollback: (t, int) => int = "rollback"

// The entry an address is registered under, whichever contract holds it —
// addresses are unique chain-wide. `None` once rolled back.
@send external get: (t, Address.t) => option<Internal.indexingContract> = "get"

@send external contractAddresses: (t, string) => array<Address.t> = "contractAddresses"

@send external entries: t => array<Internal.indexingContract> = "entries"

let toVerdict = (raw: rawVerdict): verdict =>
  switch raw.kind {
  | "added" => Added({effectiveStartBlock: raw.effectiveStartBlock})
  | "noEvents" => NoEvents({effectiveStartBlock: raw.effectiveStartBlock})
  | "duplicate" =>
    Duplicate({
      effectiveStartBlock: raw.effectiveStartBlock,
      existingEffectiveStartBlock: raw.existingEffectiveStartBlock->Null.getUnsafe,
    })
  | "conflict" => Conflict({existingContractName: raw.existingContractName->Null.getUnsafe})
  | "invalid" => Invalid
  | kind => JsError.throwWithMessage(`Unexpected address registration verdict "${kind}"`)
  }

// Registers a batch, resolving each address against both the store and the
// batch's own earlier entries — so two contracts claiming one address inside a
// single batch conflict just as they would across batches. Verdicts come back
// in the batch's order.
let registerBatch = (store: t, registrations: array<registration>): array<verdict> =>
  store->registerBatchRaw(registrations)->Array.map(toVerdict)

let makeSet = (store: t, ~contractName, ~options={}: makeSetOptions) =>
  store->makeSetRaw(contractName, options)
