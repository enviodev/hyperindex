// Whether a write keeps entity history. Decided once, where the chain states
// are in reach, and carried on the batch and on each flush group — so the
// storage layer writes what it is handed instead of re-deriving the rule.
type t =
  | Keep
  | Skip

// History is only ever kept for what a rollback could reach. `save_full_history`
// keeps everything regardless, and a run that can't roll back keeps nothing.
let decide = (config: Config.t, ~inThreshold) =>
  if config.shouldSaveFullHistory {
    Keep
  } else if !config.shouldRollbackOnReorg {
    Skip
  } else if inThreshold() {
    Keep
  } else {
    Skip
  }

// The run-wide decision a batch carries: what its checkpoints follow, and the
// value writes are grouped on so one never mixes the two modes.
let forBatch = (config: Config.t, ~isInReorgThreshold) =>
  config->decide(~inThreshold=() => isInReorgThreshold)

// The decision for one flush group. Under one shared sequence any chain's
// rollback reaches every chain's rows, so the whole run decides together; with
// a counter per chain only the group's own chain can reach its rows, and a
// chain that can't be rolled back at all has no history to keep.
let forScope = (
  config: Config.t,
  ~scope: Internal.chainScope,
  ~isInReorgThreshold,
  ~isChainInReorgThreshold: ChainId.t => bool,
) =>
  switch (config.checkpointSequence, scope) {
  | (Global, _) => config->forBatch(~isInReorgThreshold)
  | (PerChain, Chain(chainId)) =>
    config->decide(~inThreshold=() =>
      isChainInReorgThreshold(chainId) && (config.chainMap->ChainMap.get(chainId)).maxReorgDepth > 0
    )
  | (PerChain, CrossChain) =>
    JsError.throwWithMessage(
      "Internal error: a cross-chain flush group can't exist under per-chain checkpoint sequences. A cross-chain entity is what makes the sequence shared.",
    )
  }
