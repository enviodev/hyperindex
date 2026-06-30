type t

// Builds a tracker from the run's config, seeded with every item each simulate
// source provided. None when no chain has a simulate source.
let makeFromConfig: Config.t => option<t>

// Drop the batch's items from the not-yet-routed set, matched by event coordinate.
let recordProcessed: (t, ~batch: Batch.t) => unit

// The error to fail the run with when items never reached a handler, listing them
// by chain and index within that chain's `simulate` array. None when all routed.
let failureMessage: t => option<string>
