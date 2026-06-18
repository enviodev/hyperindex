// Whole-indexer view over every chain's ChainState. `t` is opaque: other modules
// read it through the accessors and change it only through the transitions here.

type t

let make: (
  ~chainStates: dict<ChainState.t>,
  ~isInReorgThreshold: bool,
  ~isRealtime: bool,
  ~maxConcurrency: int=?,
) => t

// Accessors.
let chainStates: t => dict<ChainState.t>
let isRealtime: t => bool
let isInReorgThreshold: t => bool
let inFlight: t => int

// Derived (pure).
let nextItemIsNone: t => bool
let isProgressAtHead: t => bool
let getSafeCheckpointId: t => option<Internal.checkpointId>

// Cross-chain transitions.
let createBatch: (
  t,
  ~processedCheckpointId: Internal.checkpointId,
  ~batchSizeTarget: int,
  ~isRollback: bool,
) => Batch.t
let enterReorgThreshold: t => unit
let applyBatchProgress: (t, ~batch: Batch.t) => unit

// Fetch control.
let checkAndFetch: (
  t,
  ~fetchChain: (~chain: ChainMap.Chain.t, ~concurrencyLimit: int) => promise<unit>,
) => promise<unit>
