// Binding to the Rust `AddressStore` napi class: the chain-wide index of every
// address being indexed, config-declared or dynamically registered. Identity is
// (address, contract), so one address may be indexed by several contracts, each
// with its own start block and partitions. It owns registration bookkeeping
// (duplicate detection, `effectiveStartBlock` derivation, reorg rollback) and
// hands out `AddressSet` snapshots for the fetch state's partitions. One store
// lives per chain on `ChainState`, shared with that chain's source clients —
// which read it to drop items whose emitter (or address-valued param) isn't
// registered at the item's block.
type t

// A contract an address may be registered for. Every config contract of every
// chain, since `context.chain.<Contract>.add` validates against that whole set
// — a name outside it makes the store throw. `dependsOnAddresses` is whether
// this chain fetches for the contract by address, which is what makes the store
// able to answer `fetchable` on a verdict. `id` is the contract's canonical id,
// and the list must be ordered by it: that id is what every persisted address
// row names its contract by.
type contract = {id: int, name: string, startBlock: option<int>, dependsOnAddresses: bool}

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
  // Already registered for the same contract. Another contract holding the
  // address is not a rejection — that's a registration of its own.
  | Duplicate({effectiveStartBlock: int, existingEffectiveStartBlock: int})
  // Not a well-formed address for the ecosystem.
  | Invalid

type rawVerdict = {
  kind: string,
  fetchable: bool,
  effectiveStartBlock: int,
  existingEffectiveStartBlock: Null.t<int>,
}

// A seeded row the store refused, already rendered for the warning. Only the
// rejections come back: a resume seeds millions of rows and needs a verdict for
// none of them. The only rejection a stored row can get is a repeat of a
// registration the store already holds.
type rejectedRow = {
  address: Address.t,
  contractName: string,
  effectiveStartBlock: int,
  existingEffectiveStartBlock: int,
}

// A registration the store handed over for persistence, paired with the
// checkpoint whose event registered it. `checkpointIdx` indexes the block
// numbers passed to `drainForWrite` — the ids stay on the JS side.
type drainedAddress = {
  // The raw store key, the same bytes the persisted row holds.
  address: NodeJs.Buffer.t,
  contractId: int,
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
// carries `dependsOnAddresses: false` just like a contract the config names but
// registers no events for. Either way the addresses are stored and persisted,
// never fetched.
let contractsOf = (
  ~onEventRegistrations: array<Internal.onEventRegistration>,
  // Every store of every chain holds the same contracts under the same ids, so
  // a persisted `contract_id` means the same thing wherever it's read.
  ~contractMapping: ContractMapping.t,
): array<contract> => {
  // Only ever holds a declared start block, so a missing key is unambiguous —
  // storing `None` in a dict would be indistinguishable from "not seen yet".
  let startBlocks: dict<int> = Dict.make()
  let unrestricted = Utils.Set.make()
  let addressDependent = Utils.Set.make()
  onEventRegistrations->Array.forEach(reg => {
    let name = reg.eventConfig.contractName
    contractMapping
    ->ContractMapping.idOfOrThrow(name, ~context=" has event registrations but")
    ->ignore
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
  contractMapping
  ->ContractMapping.names
  ->Array.mapWithIndex((name, id) => {
    id,
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

// `seedBatch` for rows read back from storage: columnar, so a resume of tens of
// millions of addresses never allocates a string or an object per row. Returns
// only the rows the store refused.
@send
external seedRowsRaw: (
  t,
  NodeJs.Buffer.t,
  array<int>,
  array<int>,
  array<int>,
) => array<rejectedRow> = "seedRows"

let seedRows = (store: t, rows: AddressRows.seedRows) =>
  store->seedRowsRaw(rows.addresses, rows.lengths, rows.contractIds, rows.registrationBlocks)

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

type contractAddressCount = {contractName: string, count: int}

// Live registration counts for every contract, in id order.
@send external contractCounts: t => array<contractAddressCount> = "contractCounts"
@send external size: t => int = "size"

// The chain-wide gate routing applies, exposed for the simulate source — it has
// no real query boundary to gate at.
@send external isIndexedAt: (t, Address.t, string, int) => bool = "isIndexedAt"

// A registration a rollback dropped, for the storage that has to delete its
// row. Only registrations the database may already hold are reported.
type rolledBackAddress = {address: NodeJs.Buffer.t, contractId: int}

// Drops every address registered after the target block, returning what the
// storage has to delete with it. Ids are tombstoned rather than reused, so sets
// built before the rollback still point at the right entries.
@send external rollback: (t, int) => array<rolledBackAddress> = "rollback"

// Every registration of an address, one per owning contract, in set order.
@send external getAll: (t, Address.t) => array<Internal.indexingContract> = "getAll"

// Contract names holding at least one dynamically registered address.
@send external dynamicContractNames: t => array<string> = "dynamicContractNames"

@send external contractAddresses: (t, string) => array<Address.t> = "contractAddresses"

let toVerdict = (raw: rawVerdict): verdict =>
  switch raw.kind {
  | "added" => Added({effectiveStartBlock: raw.effectiveStartBlock, fetchable: raw.fetchable})
  | "duplicate" =>
    Duplicate({
      effectiveStartBlock: raw.effectiveStartBlock,
      existingEffectiveStartBlock: raw.existingEffectiveStartBlock->Null.getUnsafe,
    })
  | "invalid" => Invalid
  | kind => JsError.throwWithMessage(`Unexpected address registration verdict "${kind}"`)
  }

// Registers dynamic registrations, resolving each address against both the
// store and the batch's own earlier entries — so the same address registered
// twice for one contract inside a single batch is a duplicate just as it would
// be across batches. Verdicts come back in the batch's order. What it adds is
// pending persistence until a batch write drains it.
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
