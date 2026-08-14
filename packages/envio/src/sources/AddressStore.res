// Binding to the Rust `AddressStore` napi class: the chain-wide index of every
// address being indexed, config-declared or dynamically registered. It owns
// registration bookkeeping (conflict detection, `effectiveStartBlock`
// derivation, reorg rollback) and hands out `AddressSet` snapshots for the
// fetch state's partitions. One store lives per chain on `ChainState`, shared
// with that chain's source clients — which read it to drop items whose emitter
// (or address-valued param) isn't registered at the item's block.
type t

// A contract an address may be registered for. Every config contract of every
// chain, since `context.chain.<Contract>.add` validates against that whole set
// — a name outside it makes the store throw. `dependsOnAddresses` is whether
// this chain fetches for the contract by address, which is what makes the store
// able to answer `fetchable` on a verdict.
type contract = {name: string, startBlock: option<int>, dependsOnAddresses: bool}

type registration = {
  address: Address.t,
  contractName: string,
  // -1 for a config address (not dynamically registered).
  registrationBlock: int,
}

type verdict =
  // `fetchable` is false when nothing on the chain is fetched by address for the
  // contract: the address is still stored and persisted, so a config that later
  // adds events picks it up on restart, but no partition is built from it.
  | Added({effectiveStartBlock: int, fetchable: bool})
  // Already registered for the same contract.
  | Duplicate({effectiveStartBlock: int, existingEffectiveStartBlock: int})
  // Already registered for a different contract.
  | Conflict({existingContractName: string})
  // Not a well-formed address for the ecosystem.
  | Invalid

type rawVerdict = {
  kind: string,
  fetchable: bool,
  effectiveStartBlock: int,
  existingContractName: Null.t<string>,
  existingEffectiveStartBlock: Null.t<int>,
}

// A registration the store handed over for persistence, paired with the
// checkpoint that owns its row. `checkpointIdx` indexes the block numbers
// passed to `drainForWrite` — the ids stay on the JS side.
type drainedAddress = {
  address: Address.t,
  contractName: string,
  registrationBlock: int,
  checkpointIdx: int,
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

// Every contract an address may be registered for, with the earliest block any
// of this chain's events for it may fire at. `None` means unrestricted, so it
// wins over any `Some`: one registration without a start block makes the whole
// contract's address gate open from the chain's start, and the per-registration
// start block still holds back the registrations that declared one.
//
// A contract whose events are all wildcard is fetched without consulting
// addresses, so registering one changes nothing about what's queried — it
// carries `dependsOnAddresses: false` just like a contract named only by
// `configContractNames`. Either way the addresses are stored and persisted,
// never fetched.
let contractsOf = (
  ~onEventRegistrations: array<Internal.onEventRegistration>,
  ~configContractNames: array<string>,
): array<contract> => {
  // Only ever holds a declared start block, so a missing key is unambiguous —
  // storing `None` in a dict would be indistinguishable from "not seen yet".
  let startBlocks: dict<int> = Dict.make()
  let unrestricted = Utils.Set.make()
  let addressDependent = Utils.Set.make()
  let names = []
  let addName = name =>
    if !(names->Array.includes(name)) {
      names->Array.push(name)->ignore
    }
  onEventRegistrations->Array.forEach(reg => {
    let name = reg.eventConfig.contractName
    addName(name)
    if reg.dependsOnAddresses {
      addressDependent->Utils.Set.add(name)->ignore
    }
    switch reg.startBlock {
    | None => unrestricted->Utils.Set.add(name)->ignore
    | Some(startBlock) =>
      startBlocks->Dict.set(
        name,
        switch startBlocks->Utils.Dict.dangerouslyGetNonOption(name) {
        | Some(existing) => Pervasives.min(existing, startBlock)
        | None => startBlock
        },
      )
    }
  })
  configContractNames->Array.forEach(addName)
  names->Array.map(name => {
    name,
    startBlock: unrestricted->Utils.Set.has(name)
      ? None
      : startBlocks->Utils.Dict.dangerouslyGetNonOption(name),
    dependsOnAddresses: addressDependent->Utils.Set.has(name),
  })
}

@send external nextId: t => int = "nextId"

// A set holding nothing — what an address-free (wildcard) partition carries, so
// every partition is queried through the same handle.
@send external emptySet: t => AddressSet.t = "emptySet"

// A set over exactly these addresses, in set order. Every set of a chain must
// come from that chain's one store — ids are store-scoped, so sets from
// different stores can't be merged.
@send external makeSetOf: (t, array<Address.t>) => AddressSet.t = "makeSetOf"
@send
external registerBatchRaw: (t, array<registration>) => array<rawVerdict> = "registerBatch"
@send external seedBatchRaw: (t, array<registration>) => array<rawVerdict> = "seedBatch"

// Drains the registrations awaiting persistence at or below the given block —
// what the batch being written covers — pairing each with the checkpoint at its
// registration block. Later registrations stay pending. Throws, with the queue
// untouched, when a drained registration's block has no checkpoint in the batch.
@send
external drainForWrite: (t, int, array<int>) => array<drainedAddress> = "drainForWrite"

// How many registrations await persistence — lets a caller skip the work of
// assembling what `drainForWrite` needs.
@send external pendingCount: t => int = "pendingCount"

// The registrations still awaiting persistence. For assertions.
@send external pendingEntries: t => array<Internal.indexingContract> = "pendingEntries"
@send external makeSetRaw: (t, string, makeSetOptions) => AddressSet.t = "makeSet"
@send external contractCount: (t, string) => int = "contractCount"
@send external size: t => int = "size"

// The chain-wide gate routing applies, exposed for the simulate source — it has
// no real query boundary to gate at.
@send external isIndexedAt: (t, Address.t, string, int) => bool = "isIndexedAt"

// Drops every address registered after the target block, returning how many
// were dropped. Ids are tombstoned rather than reused, so sets built before the
// rollback still point at the right entries.
@send external rollback: (t, int) => int = "rollback"

@send external getRaw: (t, Address.t) => Null.t<Internal.indexingContract> = "get"

@send external contractAddresses: (t, string) => array<Address.t> = "contractAddresses"

let toVerdict = (raw: rawVerdict): verdict =>
  switch raw.kind {
  | "added" => Added({effectiveStartBlock: raw.effectiveStartBlock, fetchable: raw.fetchable})
  | "duplicate" =>
    Duplicate({
      effectiveStartBlock: raw.effectiveStartBlock,
      existingEffectiveStartBlock: raw.existingEffectiveStartBlock->Null.getUnsafe,
    })
  | "conflict" => Conflict({existingContractName: raw.existingContractName->Null.getUnsafe})
  | "invalid" => Invalid
  | kind => JsError.throwWithMessage(`Unexpected address registration verdict "${kind}"`)
  }

// Registers dynamic registrations, resolving each address against both the
// store and the batch's own earlier entries — so two contracts claiming one
// address inside a single batch conflict just as they would across batches.
// Verdicts come back in the batch's order. What it adds is pending persistence
// until a batch write drains it.
//
// An unknown contract name throws with none of the batch applied.
let registerBatch = (store: t, registrations: array<registration>): array<verdict> =>
  store->registerBatchRaw(registrations)->Array.map(toVerdict)

// `registerBatch` for addresses the database already holds — config addresses
// and the dynamic ones a resume restores. Nothing is marked pending, so nothing
// is ever written back.
let seedBatch = (store: t, registrations: array<registration>): array<verdict> =>
  store->seedBatchRaw(registrations)->Array.map(toVerdict)

let makeSet = (store: t, ~contractName, ~options={}: makeSetOptions) =>
  store->makeSetRaw(contractName, options)

// The entry an address is registered under, whichever contract holds it —
// addresses are unique chain-wide. `None` once rolled back.
let get = (store: t, address) => store->getRaw(address)->Null.toOption
