// Whether a write keeps entity history. Decided once, where the chain states
// are in reach, and carried on the batch and on each flush group — so the
// storage layer writes what it is handed instead of re-deriving the rule.
type keep =
  | Keep
  | Skip

// History is only ever kept for what a rollback could reach. Under one shared
// sequence any chain's rollback reaches every chain's rows, so the run decides
// together; with a counter per chain only the group's own chain can reach its
// rows, and each chain decides for itself.
type t =
  | Shared(keep)
  | ByChain(dict<keep>)

// `save_full_history` keeps everything regardless. Everything else follows
// `keepsHistory` per chain — whether a rollback can still reach what that chain
// writes.
let decide = (config: Config.t, ~keepsHistory: dict<bool>): t =>
  if config.shouldSaveFullHistory {
    Shared(Keep)
  } else {
    switch config.checkpointSequence {
    | Global => Shared(keepsHistory->Dict.valuesToArray->Array.some(keeps => keeps) ? Keep : Skip)
    | PerChain => ByChain(keepsHistory->Utils.Dict.mapValues(keeps => keeps ? Keep : Skip))
    }
  }

// The decision for one flush group.
let forScope = (t: t, ~scope: Internal.chainScope): keep =>
  switch (t, scope) {
  | (Shared(keep), _) => keep
  | (ByChain(byChain), Chain(chainId)) =>
    byChain->ChainId.Dict.dangerouslyGetNonOption(chainId)->Option.getOr(Skip)
  | (ByChain(_), CrossChain) =>
    JsError.throwWithMessage(
      "Internal error: a cross-chain flush group can't exist under per-chain checkpoint sequences. A cross-chain entity is what makes the sequence shared.",
    )
  }

// The decision for one chain's checkpoints.
let forChain = (t: t, chainId: ChainId.t): keep =>
  switch t {
  | Shared(keep) => keep
  | ByChain(byChain) => byChain->ChainId.Dict.dangerouslyGetNonOption(chainId)->Option.getOr(Skip)
  }

// Whether a run has stale history to prune at all: history it keeps but doesn't
// keep forever.
let mayPrune = (config: Config.t, ~keepsHistory: dict<bool>) =>
  !config.shouldSaveFullHistory && keepsHistory->Dict.valuesToArray->Array.some(keeps => keeps)
