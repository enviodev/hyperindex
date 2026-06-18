// Whole-indexer view over every chain's ChainState. `t` is opaque: other modules
// read it through the accessors and change it only through the transitions here.

type t

let calculateTargetBufferSize: unit => int

let make: (
  ~chainStates: dict<ChainState.t>,
  ~isInReorgThreshold: bool,
  ~isRealtime: bool,
  ~maxBackfillConcurrency: int=?,
  ~maxRealtimeConcurrency: int=?,
  ~targetBufferSize: int=?,
) => t

// Accessors.
let chainStates: t => dict<ChainState.t>
let isRealtime: t => bool
let isInReorgThreshold: t => bool
let maxConcurrency: t => int
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
let shouldPauseFetch: (ChainState.t, ~isRealtime: bool, ~anyChainBackfilling: bool) => bool
let priorityOrder: t => array<ChainState.t>
let checkAndFetch: (
  t,
  ~fetchChain: (
    ~chain: ChainMap.Chain.t,
    ~concurrencyLimit: int,
    ~bufferLimit: int,
  ) => promise<unit>,
) => promise<unit>
