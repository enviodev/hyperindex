type indexingAddress = Internal.indexingContract

type contractConfig = {startBlock: option<int>}

type t = dict<indexingAddress>

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
  let indexingAddresses = Dict.make()
  addresses->Array.forEach(contract => {
    indexingAddresses->Dict.set(
      contract.address->Address.toString,
      makeIndexingAddress(~contract, ~contractConfigs),
    )
  })
  indexingAddresses
}

let get = (indexingAddresses: t, address) =>
  indexingAddresses->Utils.Dict.dangerouslyGetNonOption(address)

let size = (indexingAddresses: t) => indexingAddresses->Utils.Dict.size

let getContractAddresses = (indexingAddresses: t, ~contractName): array<Address.t> => {
  let addresses = []
  indexingAddresses->Utils.Dict.forEach(ia => {
    if ia.contractName === contractName {
      addresses->Array.push(ia.address)
    }
  })
  addresses
}

// Underlying dict for the precompiled `clientAddressFilter` only — it does raw
// `indexingAddresses[srcAddress]` access in generated JS and can't take the opaque
// type. Don't reach for this elsewhere; use the domain accessors above.
let rawForFilter = (indexingAddresses: t): dict<indexingAddress> => indexingAddresses

let register = (indexingAddresses: t, additions: dict<indexingAddress>) => {
  let _ = Utils.Dict.mergeInPlace(indexingAddresses, additions)
}

let rollbackInPlace = (indexingAddresses: t, ~targetBlockNumber: int): unit => {
  // forEachWithKey is a `for..in`, so deleting the key currently being visited is
  // safe — it doesn't affect enumeration of the remaining keys.
  indexingAddresses->Utils.Dict.forEachWithKey((indexingContract, address) => {
    if indexingContract.registrationBlock > targetBlockNumber {
      indexingAddresses->Utils.Dict.deleteInPlace(address)
    }
  })
}
