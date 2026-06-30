type t

// Builds a tracker from the run's config, seeded with every item each simulate
// source provided. None when no chain has a simulate source.
let makeFromConfig: Config.t => option<t>

// Drop the batch's items from the not-yet-routed set (matched by reference).
let recordProcessed: (t, ~batch: Batch.t) => unit

// Items that never reached a handler, grouped by chain id, each reported as its
// index within that chain's `simulate` array (ascending). Empty when all routed.
let unroutedByChain: t => array<(int, array<int>)>
