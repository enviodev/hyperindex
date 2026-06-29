type indexingAddress = Internal.indexingContract

type contractConfig = {startBlock: option<int>}

type t

let deriveEffectiveStartBlock: (~registrationBlock: int, ~contractStartBlock: option<int>) => int

let makeContractConfigs: (~eventConfigs: array<Internal.eventConfig>) => dict<contractConfig>

let make: (~contractConfigs: dict<contractConfig>, ~addresses: array<Internal.indexingAddress>) => t

let get: (t, string) => option<indexingAddress>

let size: t => int

// Underlying dict for raw `obj[address]` access (the generated `clientAddressFilter`)
// and the public chain accessor. Zero-cost: `t` is represented as a dict.
let dict: t => dict<indexingAddress>

let register: (t, dict<indexingAddress>) => unit

// Deletes addresses registered after `targetBlockNumber` in place and returns them
// so partitions can be pruned to match.
let rollback: (t, ~targetBlockNumber: int) => Utils.Set.t<Address.t>
