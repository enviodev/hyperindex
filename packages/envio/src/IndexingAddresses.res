type indexingAddress = Internal.indexingContract

type contractConfig = {startBlock: option<int>}

type t = dict<indexingAddress>

let deriveEffectiveStartBlock = (~registrationBlock: int, ~contractStartBlock: option<int>) => {
  Pervasives.max(Pervasives.max(registrationBlock, 0), contractStartBlock->Option.getOr(0))
}

let makeContractConfigs = (~eventConfigs: array<Internal.eventConfig>): dict<contractConfig> => {
  let contractConfigs: dict<contractConfig> = Dict.make()
  eventConfigs->Array.forEach(ec => {
    switch contractConfigs->Utils.Dict.dangerouslyGetNonOption(ec.contractName) {
    | Some({startBlock}) =>
      contractConfigs->Dict.set(
        ec.contractName,
        {
          startBlock: switch (startBlock, ec.startBlock) {
          | (Some(a), Some(b)) => Some(Pervasives.min(a, b))
          | (Some(_) as s, None) | (None, Some(_) as s) => s
          | (None, None) => None
          },
        },
      )
    | None =>
      contractConfigs->Dict.set(
        ec.contractName,
        {
          startBlock: ec.startBlock,
        },
      )
    }
  })
  contractConfigs
}

let make = (
  ~contractConfigs: dict<contractConfig>,
  ~addresses: array<Internal.indexingAddress>,
): t => {
  let indexingAddresses = Dict.make()
  addresses->Array.forEach(contract => {
    let contractStartBlock = switch contractConfigs->Utils.Dict.dangerouslyGetNonOption(
      contract.contractName,
    ) {
    | Some({startBlock}) => startBlock
    | None => None
    }
    let ia: indexingAddress = {
      address: contract.address,
      contractName: contract.contractName,
      registrationBlock: contract.registrationBlock,
      effectiveStartBlock: deriveEffectiveStartBlock(
        ~registrationBlock=contract.registrationBlock,
        ~contractStartBlock,
      ),
    }
    indexingAddresses->Dict.set(contract.address->Address.toString, ia)
  })
  indexingAddresses
}

let get = (indexingAddresses: t, address) =>
  indexingAddresses->Utils.Dict.dangerouslyGetNonOption(address)

let has = (indexingAddresses: t, address) =>
  indexingAddresses->Utils.Dict.dangerouslyGetNonOption(address)->Option.isSome

let size = (indexingAddresses: t) => indexingAddresses->Utils.Dict.size

let toArray = (indexingAddresses: t): array<indexingAddress> =>
  indexingAddresses->Dict.valuesToArray

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

let rollback = (indexingAddresses: t, ~targetBlockNumber: int): Utils.Set.t<Address.t> => {
  let removed = Utils.Set.make()
  let keysToDelete = []
  indexingAddresses->Utils.Dict.forEachWithKey((indexingContract, address) => {
    if indexingContract.registrationBlock > targetBlockNumber {
      removed->Utils.Set.add(address->Address.unsafeFromString)->ignore
      keysToDelete->Array.push(address)
    }
  })
  keysToDelete->Array.forEach(key => indexingAddresses->Utils.Dict.deleteInPlace(key))
  removed
}
