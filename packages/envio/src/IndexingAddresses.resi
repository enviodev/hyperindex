type indexingAddress = Internal.indexingContract

type contractConfig = {startBlock: option<int>}

type t

let deriveEffectiveStartBlock: (~registrationBlock: int, ~contractStartBlock: option<int>) => int

let makeContractConfigs: (~eventConfigs: array<Internal.eventConfig>) => dict<contractConfig>

let makeIndexingAddress: (
  ~contract: Internal.indexingAddress,
  ~contractConfigs: dict<contractConfig>,
) => indexingAddress

let make: (~contractConfigs: dict<contractConfig>, ~addresses: array<Internal.indexingAddress>) => t

let get: (t, string) => option<indexingAddress>

let size: t => int

let getContractAddresses: (t, ~contractName: string) => array<Address.t>

// Underlying dict for the precompiled `clientAddressFilter` only, which does raw
// `indexingAddresses[srcAddress]` access in generated JS. Don't use elsewhere —
// prefer the domain accessors so the opaque type stays enforced.
let rawForFilter: t => dict<indexingAddress>

let register: (t, dict<indexingAddress>) => unit

// Deletes addresses registered after `targetBlockNumber` from the index in place.
let rollbackInPlace: (t, ~targetBlockNumber: int) => unit
