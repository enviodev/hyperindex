type indexingAddress = Internal.indexingContract

type contractConfig = {startBlock: option<int>}

type t

let deriveEffectiveStartBlock: (~registrationBlock: int, ~contractStartBlock: option<int>) => int

let makeContractConfigs: (
  ~onEventRegistrations: array<Internal.onEventRegistration>,
) => dict<contractConfig>

let makeIndexingAddress: (
  ~contract: Internal.indexingAddress,
  ~contractConfigs: dict<contractConfig>,
) => indexingAddress

let make: (~contractConfigs: dict<contractConfig>, ~addresses: array<Internal.indexingAddress>) => t

let get: (t, string) => option<indexingAddress>

let size: t => int

// Number of registered addresses for a single contract (O(1)).
let contractCount: (t, ~contractName: string) => int

let getContractAddresses: (t, ~contractName: string) => array<Address.t>

// The address→entry dict for a single contract, passed to that contract's
// precompiled `clientAddressFilter` (raw `byAddr[srcAddress]` access in
// generated JS). Don't use elsewhere — prefer the domain accessors so the
// opaque type stays enforced.
let forContract: (t, ~contractName: string) => dict<indexingAddress>

let register: (t, dict<indexingAddress>) => unit

// Deletes addresses registered after `targetBlockNumber` from the index in place.
let rollbackInPlace: (t, ~targetBlockNumber: int) => unit
