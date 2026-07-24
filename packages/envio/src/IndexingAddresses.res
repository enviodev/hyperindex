type indexingAddress = Internal.indexingContract

type contractConfig = {startBlock: option<int>}

// Grouped by contract name, then by address string. Contracts are few, so
// per-contract operations (address count, the client-side filter's lookup
// dict) are direct, and whole-index scans (get by address, rollback) walk the
// small contract set. Address strings are globally unique across contracts
// (conflicting registrations are rejected before they reach here).
type t = dict<dict<indexingAddress>>

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

let insert = (indexingAddresses: t, indexingAddress: indexingAddress) => {
  indexingAddresses
  ->Utils.Dict.getOrInsertEmptyDict(indexingAddress.contractName)
  ->Dict.set(indexingAddress.address->Address.toString, indexingAddress)
}

let make = (
  ~contractConfigs: dict<contractConfig>,
  ~addresses: array<Internal.indexingAddress>,
): t => {
  let indexingAddresses = Dict.make()
  addresses->Array.forEach(contract => {
    indexingAddresses->insert(makeIndexingAddress(~contract, ~contractConfigs))
  })
  indexingAddresses
}

// Address strings are globally unique, so the first inner dict holding the
// address owns it. for..in returns on the first hit without allocating a values
// array per lookup (get runs once per registration).
let get: (t, string) => option<indexingAddress> = %raw(`(index, address) => {
  for (var contractName in index) {
    var entry = index[contractName][address];
    if (entry !== undefined) {
      return entry;
    }
  }
  return undefined;
}`)

let size = (indexingAddresses: t) => {
  let total = ref(0)
  indexingAddresses->Utils.Dict.forEach(inner => {
    total := total.contents + inner->Utils.Dict.size
  })
  total.contents
}

// Number of registered addresses for a single contract — a for..in over that
// one contract's addresses. The trigger deciding when to switch a contract to
// client-side filtering reads this.
let contractCount = (indexingAddresses: t, ~contractName) =>
  switch indexingAddresses->Utils.Dict.dangerouslyGetNonOption(contractName) {
  | Some(inner) => inner->Utils.Dict.size
  | None => 0
  }

let getContractAddresses = (indexingAddresses: t, ~contractName): array<Address.t> => {
  switch indexingAddresses->Utils.Dict.dangerouslyGetNonOption(contractName) {
  | Some(inner) => inner->Dict.valuesToArray->Array.map(ia => ia.address)
  | None => []
  }
}

let emptyContractDict: dict<indexingAddress> = Dict.make()

// The address→entry dict for a single contract, passed to that contract's
// precompiled `clientAddressFilter` (which does raw `byAddr[srcAddress]` access
// in generated JS). Every leaf of a filter references the event's own contract
// — `chain.<Contract>.addresses` only exposes the event's contract — so one
// inner dict covers the srcAddress and param-address checks alike. Returns a
// shared empty dict when the contract has no registered addresses.
let forContract = (indexingAddresses: t, ~contractName): dict<indexingAddress> =>
  switch indexingAddresses->Utils.Dict.dangerouslyGetNonOption(contractName) {
  | Some(inner) => inner
  | None => emptyContractDict
  }

let register = (indexingAddresses: t, additions: dict<indexingAddress>) => {
  additions->Utils.Dict.forEach(indexingAddress => {
    indexingAddresses->insert(indexingAddress)
  })
}

let rollbackInPlace = (indexingAddresses: t, ~targetBlockNumber: int): unit => {
  // forEachWithKey is a `for..in`, so deleting the key currently being visited is
  // safe — it doesn't affect enumeration of the remaining keys.
  indexingAddresses->Utils.Dict.forEach(inner => {
    inner->Utils.Dict.forEachWithKey((indexingContract, address) => {
      if indexingContract.registrationBlock > targetBlockNumber {
        inner->Utils.Dict.deleteInPlace(address)
      }
    })
  })
}
