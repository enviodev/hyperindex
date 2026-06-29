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

let size = (indexingAddresses: t) => indexingAddresses->Utils.Dict.size

let dict = (indexingAddresses: t): dict<indexingAddress> => indexingAddresses

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
