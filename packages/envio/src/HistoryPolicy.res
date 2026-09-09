// Whether each chain's rows get history on a write, keyed by chain id. History
// is only ever kept for what a rollback could reach: under one shared sequence
// any chain's rollback reaches every chain's rows, so the run decides together;
// with a counter per chain only the group's own chain can reach its rows.
type t = dict<bool>

%%private(
  let anyChainSaves = (shouldSaveHistory: dict<bool>) =>
    shouldSaveHistory->Dict.valuesToArray->Array.some(saves => saves)
)

let decide = (config: Config.t, ~shouldSaveHistory: dict<bool>): t =>
  if config.shouldSaveFullHistory {
    shouldSaveHistory->Utils.Dict.mapValues(_ => true)
  } else {
    switch config.checkpointSequence {
    | Global =>
      let saves = shouldSaveHistory->anyChainSaves
      shouldSaveHistory->Utils.Dict.mapValues(_ => saves)
    | PerChain => shouldSaveHistory
    }
  }

// Every chain the run indexes was decided for, so an absent one is a bug —
// answering `false` for it would silently leave the chain with nothing to roll
// back to.
let forChain = (t: t, chainId: ChainId.t): bool =>
  switch t->ChainId.Dict.dangerouslyGetNonOption(chainId) {
  | Some(saves) => saves
  | None =>
    JsError.throwWithMessage(
      `Internal error: no history decision for chain ${chainId->ChainId.toString}. The policy is decided for every chain the run indexes.`,
    )
  }

// A cross-chain group's rows are reachable by any chain's rollback.
let forScope = (t: t, ~scope: Internal.chainScope): bool =>
  switch scope {
  | Chain(chainId) => t->forChain(chainId)
  | CrossChain => t->anyChainSaves
  }

// Whether a run has stale history to prune at all: history it keeps but doesn't
// keep forever.
let mayPrune = (config: Config.t, ~shouldSaveHistory: dict<bool>) =>
  !config.shouldSaveFullHistory && shouldSaveHistory->anyChainSaves
