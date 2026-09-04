type t

type contract = {name: string, startBlock: option<int>, dependsOnAddresses: bool}

type registration = {
  address: Address.t,
  contractName: string,
  // -1 for a config address.
  registrationBlock: int,
}

type verdict =
  // False when nothing on this chain is fetched by address for the contract.
  // The address is still stored and persisted.
  | Added({effectiveStartBlock: int, fetchable: bool})
  | Duplicate({effectiveStartBlock: int, existingEffectiveStartBlock: int})
  | Invalid

type rawVerdict = {
  kind: string,
  fetchable: bool,
  effectiveStartBlock: int,
  existingEffectiveStartBlock: Null.t<int>,
}

type rejectedRow = {
  address: Address.t,
  contractName: string,
  effectiveStartBlock: int,
  existingEffectiveStartBlock: int,
}

type drainedAddress = {
  address: NodeJs.Buffer.t,
  contractId: int,
  registrationBlock: int,
  checkpointIdx: int,
}

type makeSetOptions = {
  minId?: int,
  fromStartBlock?: int,
  toStartBlock?: int,
  offset?: int,
  limit?: int,
}

@send
external newEvm: (Core.addressStoreCtor, bool, array<contract>) => t = "newEvm"
@send external newSvm: (Core.addressStoreCtor, array<contract>) => t = "newSvm"
@send external newFuel: (Core.addressStoreCtor, array<contract>) => t = "newFuel"

let make = (~ecosystem: Ecosystem.name, ~shouldChecksum: bool, ~contracts: array<contract>): t => {
  let ctor = Core.getAddon().addressStore
  switch ecosystem {
  | Evm => ctor->newEvm(shouldChecksum, contracts)
  | Svm => ctor->newSvm(contracts)
  | Fuel => ctor->newFuel(contracts)
  }
}

let contractsOf = (
  ~onEventRegistrations: array<Internal.onEventRegistration>,
  ~contractMapping: ContractMapping.t,
): array<contract> => {
  // Only ever holds a declared start block, so a missing key is unambiguous.
  // Storing None in a dict would be indistinguishable from "not seen yet".
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
  ->Array.map(name => {
    name,
    startBlock: unrestricted->Utils.Set.has(name)
      ? None
      : startBlocks->Utils.Dict.dangerouslyGetNonOption(name),
    dependsOnAddresses: addressDependent->Utils.Set.has(name),
  })
}

@send external nextId: t => int = "nextId"

@send external emptySet: t => AddressSet.t = "emptySet"

@send
external registerBatchRaw: (t, array<registration>) => array<rawVerdict> = "registerBatch"
@send external seedBatchRaw: (t, array<registration>) => array<rawVerdict> = "seedBatch"

@send
external seedRowsRaw: (
  t,
  NodeJs.Buffer.t,
  array<int>,
  array<int>,
  array<int>,
) => array<rejectedRow> = "seedRows"

let seedRows = (store: t, rows: AddressRows.seedRows) => {
  let (bytes, lengths) = AddressRows.packBuffers(rows.addresses)
  store->seedRowsRaw(bytes, lengths, rows.contractIds, rows.registrationBlocks)
}

// Throws with the queue untouched when a drained registration's block has no
// checkpoint in the batch.
@send
external drainForWrite: (t, int, array<int>) => array<drainedAddress> = "drainForWrite"

@send external pendingCount: t => int = "pendingCount"

@send external pendingEntries: t => array<Internal.indexingContract> = "pendingEntries"
@send external makeSetRaw: (t, string, makeSetOptions) => AddressSet.t = "makeSet"
@send external contractCount: (t, string) => int = "contractCount"

type contractAddressCount = {contractName: string, count: int}

@send external contractCounts: t => array<contractAddressCount> = "contractCounts"
@send external size: t => int = "size"

@send external isIndexedAt: (t, Address.t, string, int) => bool = "isIndexedAt"

type rolledBackAddress = {address: NodeJs.Buffer.t, contractId: int}

// Ids are tombstoned rather than reused, so sets built before the rollback
// still point at the right entries.
@send external rollback: (t, int) => array<rolledBackAddress> = "rollback"

@send external getAll: (t, Address.t) => array<Internal.indexingContract> = "getAll"

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

// An unknown contract name throws with none of the batch applied.
let registerBatch = (store: t, registrations: array<registration>): array<verdict> =>
  store->registerBatchRaw(registrations)->Array.map(toVerdict)

let seedBatch = (store: t, registrations: array<registration>): array<verdict> =>
  store->seedBatchRaw(registrations)->Array.map(toVerdict)

let makeSet = (store: t, ~contractName, ~options={}: makeSetOptions) =>
  store->makeSetRaw(contractName, options)
