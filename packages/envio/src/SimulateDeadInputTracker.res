// Lives on IndexerState and is fed each processed batch, so ChainState and the
// fetch loop carry no simulate-specific state.

// Match a provided item to a processed one by its (chain, block, logIndex)
// coordinate rather than object identity, so matching survives any copy or
// transform of the item between the source and the batch.
let itemKey = (item: Internal.item): string =>
  switch item {
  | Internal.Event({chain, blockNumber, logIndex}) =>
    `${chain
      ->ChainMap.Chain.toChainId
      ->Int.toString}:${blockNumber->Int.toString}:${logIndex->Int.toString}`
  | _ => "" // non-event items are never a provided simulate input
  }

// `index` is the item's position in its chain's `simulate` array, reported back
// so a user finds it without echoing its fields.
type entry = {chainId: int, index: int, key: string}

type t = {mutable unprocessed: array<entry>}

let makeFromConfig = (config: Config.t): option<t> => {
  let entries =
    config.chainMap
    ->ChainMap.values
    ->Array.flatMap(chainConfig =>
      switch chainConfig.sourceConfig {
      | Config.CustomSources(sources) =>
        sources->Array.flatMap(source =>
          source.simulateItems
          ->Option.getOr([])
          ->Array.mapWithIndex(
            (item, index) => {
              chainId: chainConfig.id,
              index,
              key: itemKey(item),
            },
          )
        )
      | _ => []
      }
    )
  switch entries {
  | [] => None
  | _ => Some({unprocessed: entries})
  }
}

let recordProcessed = (t: t, ~batch: Batch.t) => {
  let processedKeys = batch.items->Array.map(itemKey)->Utils.Set.fromArray
  t.unprocessed = t.unprocessed->Array.filter(entry => !(processedKeys->Utils.Set.has(entry.key)))
}

// Unrouted item indices grouped by chain, in the order chains were first seen.
let unroutedByChain = (t: t): array<(int, array<int>)> => {
  let indicesByChain = Dict.make()
  let chainOrder = []
  t.unprocessed->Array.forEach(entry => {
    let key = entry.chainId->Int.toString
    if indicesByChain->Dict.get(key)->Option.isNone {
      chainOrder->Array.push(entry.chainId)->ignore
    }
    indicesByChain->Utils.Dict.push(key, entry.index)
  })
  chainOrder->Array.map(chainId => (chainId, indicesByChain->Dict.getUnsafe(chainId->Int.toString)))
}

let failureMessage = (t: t): option<string> =>
  switch t->unroutedByChain {
  | [] => None
  | byChain =>
    let count = byChain->Array.reduce(0, (acc, (_chainId, indices)) => acc + indices->Array.length)
    let itemWord = count === 1 ? "item" : "items"
    let lines =
      byChain
      ->Array.map(((chainId, indices)) =>
        `  - chain ${chainId->Int.toString}: ${indices
          ->Array.map(index => index->Int.toString)
          ->Array.join(", ")}`
      )
      ->Array.join("\n")
    Some(
      `simulate: ${count->Int.toString} ${itemWord} you passed to simulate never reached a handler, so nothing ran for them. Each was filtered out before the handler — usually a non-wildcard srcAddress that isn't indexed for the contract, or a where/block filter that excluded the event. Unrouted items, by index in each chain's simulate array:\n${lines}`,
    )
  }
