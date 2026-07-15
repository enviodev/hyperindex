type indexingAddress = Internal.indexingContract

type contractConfig = {startBlock: option<int>}

// A dynamic contract registration awaiting persistence to envio_addresses.
// registrationLogIndex is the log index of the event that registered it.
type dcToStore = {
  address: Address.t,
  contractName: string,
  registrationBlock: int,
  registrationLogIndex: int,
}

type t = {
  addresses: dict<indexingAddress>,
  // Registrations queued at fetch time, drained into the write batch once the
  // registering event's checkpoint is committed. Pruned on rollback alongside
  // `addresses`.
  mutable dcsToStore: array<dcToStore>,
}

let deriveEffectiveStartBlock = (~registrationBlock: int, ~contractStartBlock: option<int>) => {
  Pervasives.max(Pervasives.max(registrationBlock, 0), contractStartBlock->Option.getOr(0))
}

let makeContractConfigs = (~onEventRegistrations: array<Internal.onEventRegistration>): dict<
  contractConfig,
> => {
  let contractConfigs: dict<contractConfig> = Dict.make()
  onEventRegistrations->Array.forEach(reg => {
    let contractName = reg.eventConfig.contractName
    switch contractConfigs->Utils.Dict.dangerouslyGetNonOption(contractName) {
    | Some({startBlock}) =>
      contractConfigs->Dict.set(
        contractName,
        {
          startBlock: switch (startBlock, reg.startBlock) {
          | (Some(a), Some(b)) => Some(Pervasives.min(a, b))
          | (Some(_) as s, None) | (None, Some(_) as s) => s
          | (None, None) => None
          },
        },
      )
    | None =>
      contractConfigs->Dict.set(
        contractName,
        {
          startBlock: reg.startBlock,
        },
      )
    }
  })
  contractConfigs
}

let makeIndexingAddress = (
  ~contract: Internal.indexingAddress,
  ~contractConfigs: dict<contractConfig>,
): indexingAddress => {
  let contractStartBlock = switch contractConfigs->Utils.Dict.dangerouslyGetNonOption(
    contract.contractName,
  ) {
  | Some({startBlock}) => startBlock
  | None => None
  }
  {
    address: contract.address,
    contractName: contract.contractName,
    registrationBlock: contract.registrationBlock,
    effectiveStartBlock: deriveEffectiveStartBlock(
      ~registrationBlock=contract.registrationBlock,
      ~contractStartBlock,
    ),
  }
}

let make = (
  ~contractConfigs: dict<contractConfig>,
  ~addresses: array<Internal.indexingAddress>,
): t => {
  let dict = Dict.make()
  addresses->Array.forEach(contract => {
    dict->Dict.set(
      contract.address->Address.toString,
      makeIndexingAddress(~contract, ~contractConfigs),
    )
  })
  {addresses: dict, dcsToStore: []}
}

let get = (indexingAddresses: t, address) =>
  indexingAddresses.addresses->Utils.Dict.dangerouslyGetNonOption(address)

let size = (indexingAddresses: t) => indexingAddresses.addresses->Utils.Dict.size

let getContractAddresses = (indexingAddresses: t, ~contractName): array<Address.t> => {
  let addresses = []
  indexingAddresses.addresses->Utils.Dict.forEach(ia => {
    if ia.contractName === contractName {
      addresses->Array.push(ia.address)
    }
  })
  addresses
}

// Underlying dict for the precompiled `clientAddressFilter` only — it does raw
// `indexingAddresses[srcAddress]` access in generated JS and can't take the opaque
// type. Don't reach for this elsewhere; use the domain accessors above.
let rawForFilter = (indexingAddresses: t): dict<indexingAddress> => indexingAddresses.addresses

let register = (indexingAddresses: t, additions: dict<indexingAddress>) => {
  let _ = Utils.Dict.mergeInPlace(indexingAddresses.addresses, additions)
}

let addDcToStore = (indexingAddresses: t, dcToStore: dcToStore) => {
  indexingAddresses.dcsToStore->Array.push(dcToStore)->ignore
}

let dcsToStore = (indexingAddresses: t): array<dcToStore> => indexingAddresses.dcsToStore

// Removes and returns the queued registrations whose block resolves to a
// checkpoint via `getCheckpointId` (i.e. their registering event is in the batch
// being written); the rest stay queued for a later batch.
let drainDcsToStore = (
  indexingAddresses: t,
  ~getCheckpointId: int => option<Internal.checkpointId>,
): array<(dcToStore, Internal.checkpointId)> => {
  let drained = []
  let remaining = []
  indexingAddresses.dcsToStore->Array.forEach(dc => {
    switch getCheckpointId(dc.registrationBlock) {
    | Some(checkpointId) => drained->Array.push((dc, checkpointId))->ignore
    | None => remaining->Array.push(dc)->ignore
    }
  })
  indexingAddresses.dcsToStore = remaining
  drained
}

let rollbackInPlace = (indexingAddresses: t, ~targetBlockNumber: int): unit => {
  // forEachWithKey is a `for..in`, so deleting the key currently being visited is
  // safe — it doesn't affect enumeration of the remaining keys.
  indexingAddresses.addresses->Utils.Dict.forEachWithKey((indexingContract, address) => {
    if indexingContract.registrationBlock > targetBlockNumber {
      indexingAddresses.addresses->Utils.Dict.deleteInPlace(address)
    }
  })
  indexingAddresses.dcsToStore =
    indexingAddresses.dcsToStore->Array.filter(dc => dc.registrationBlock <= targetBlockNumber)
}
