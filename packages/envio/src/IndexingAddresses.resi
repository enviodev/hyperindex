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

let getContractAddresses: (t, ~contractName: string) => array<Address.t>

// Underlying dict for the precompiled `clientAddressFilter` only, which does raw
// `indexingAddresses[srcAddress]` access in generated JS. Don't use elsewhere —
// prefer the domain accessors so the opaque type stays enforced.
let rawForFilter: t => dict<indexingAddress>

let register: (t, dict<indexingAddress>) => unit

// Queues a registration for persistence to envio_addresses.
let addDcToStore: (t, dcToStore) => unit

// Snapshot of the registrations currently queued for persistence.
let dcsToStore: t => array<dcToStore>

// Removes and returns the queued registrations whose block resolves to a
// checkpoint via `getCheckpointId` (their registering event is in the batch being
// written); the rest stay queued for a later batch.
let drainDcsToStore: (
  t,
  ~getCheckpointId: int => option<Internal.checkpointId>,
) => array<(dcToStore, Internal.checkpointId)>

// Deletes addresses and queued registrations after `targetBlockNumber` in place.
let rollbackInPlace: (t, ~targetBlockNumber: int) => unit
