// Tracks the items a simulate run was given and drops each as it lands in a
// processed batch, so the run can report inputs that never reached a handler
// (dead test code) instead of exiting clean. Built only when the run has a
// simulate source; absent otherwise, which keeps this test concern out of the
// core indexing state — IndexerState holds the tracker and feeds it the
// processed batches, ChainState and the fetch loop stay simulate-agnostic.

type t = {mutable unprocessed: array<Internal.item>}

let makeFromConfig = (config: Config.t): option<t> => {
  let items =
    config.chainMap
    ->ChainMap.values
    ->Array.flatMap(chainConfig =>
      switch chainConfig.sourceConfig {
      | Config.CustomSources(sources) =>
        switch sources->Array.find(source => source.simulateItems->Option.isSome) {
        | Some(source) => source.simulateItems->Option.getOr([])
        | None => []
        }
      | _ => []
      }
    )
  switch items {
  | [] => None
  | _ => Some({unprocessed: items})
  }
}

// A batch holds the same item references the simulate source provided, so an
// item that never appears in one never ran.
let recordProcessed = (t: t, ~batch: Batch.t) =>
  t.unprocessed =
    t.unprocessed->Array.filter(provided =>
      !(batch.items->Array.some(processed => processed === provided))
    )

let unprocessedItems = (t: t) => t.unprocessed
