// Tracks the items a simulate run was given and drops each as it lands in a
// processed batch, so the run can report inputs that never reached a handler
// (dead test code) instead of exiting clean. Built only when the run has a
// simulate source; absent otherwise, which keeps this test concern out of the
// core indexing state — IndexerState holds the tracker and feeds it the
// processed batches, ChainState and the fetch loop stay simulate-agnostic.

// `index` is the item's position in its chain's `simulate` array, which is what
// gets reported back so a user can find it without echoing its fields.
type entry = {chainId: int, index: int, item: Internal.item}

type t = {mutable unprocessed: array<entry>}

let makeFromConfig = (config: Config.t): option<t> => {
  let entries =
    config.chainMap
    ->ChainMap.values
    ->Array.flatMap(chainConfig =>
      switch chainConfig.sourceConfig {
      | Config.CustomSources(sources) =>
        switch sources->Array.find(source => source.simulateItems->Option.isSome) {
        | Some(source) =>
          source.simulateItems
          ->Option.getOr([])
          ->Array.mapWithIndex((item, index) => {chainId: chainConfig.id, index, item})
        | None => []
        }
      | _ => []
      }
    )
  switch entries {
  | [] => None
  | _ => Some({unprocessed: entries})
  }
}

// A batch holds the same item references the simulate source provided, so an
// item that never appears in one never ran.
let recordProcessed = (t: t, ~batch: Batch.t) =>
  t.unprocessed =
    t.unprocessed->Array.filter(entry =>
      !(batch.items->Array.some(processed => processed === entry.item))
    )

let unroutedByChain = (t: t): array<(int, array<int>)> => {
  let indicesByChain = Dict.make()
  let chainOrder = []
  t.unprocessed->Array.forEach(entry => {
    let key = entry.chainId->Int.toString
    switch indicesByChain->Dict.get(key) {
    | Some(indices) => indices->Array.push(entry.index)->ignore
    | None =>
      indicesByChain->Dict.set(key, [entry.index])
      chainOrder->Array.push(entry.chainId)->ignore
    }
  })
  chainOrder->Array.map(chainId => (
    chainId,
    indicesByChain->Dict.get(chainId->Int.toString)->Option.getOr([]),
  ))
}
