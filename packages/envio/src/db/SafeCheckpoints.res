// How far back a prune may delete. Every chain has a safe block of its own — its
// head less its reorg depth — below which a rollback can no longer reach, and the
// last checkpoint at or under it is what that chain's history is kept from.

type t =
  // One checkpoint bounds every chain's rows. What a schema with a cross-chain
  // entity needs: a reorg on any chain rolls every chain back to one checkpoint,
  // which can sit below another chain's safe point.
  | EveryChain(Internal.checkpointId)
  // Each chain down to its own safe checkpoint. A chain with nothing safe yet is
  // absent, and so holds only itself back.
  | PerChain(array<(ChainId.t, Internal.checkpointId)>)

// The bound one table can be measured against, or None when it has none.
//
// A table whose rows aren't a single chain's needs one bound for all of them,
// which per-chain bounds can't give: the chains absent from them have nothing
// safe at all, so no checkpoint they share can be derived. Unreachable — only a
// schema whose entities are all per-chain prunes per chain — and it leaves the
// table alone rather than guessing a bound for it.
let forTable = (safeCheckpoints: t, ~chainIdColumn: option<string>) =>
  switch (chainIdColumn, safeCheckpoints) {
  | (None, PerChain(_)) => None
  | _ => Some(safeCheckpoints)
  }

// The parameters a prune query binds, in the order it reads them: a bound shared
// by every chain as `$1`, or the per-chain bounds as the two parallel arrays a
// query unnests into `(chain_id, safe_checkpoint_id)` rows.
let params = (safeCheckpoints: t): unknown =>
  switch safeCheckpoints {
  | EveryChain(checkpointId) =>
    [checkpointId->BigInt.toString]->(Utils.magic: array<string> => unknown)
  | PerChain(byChain) =>
    (
      byChain->Array.map(((chainId, _)) => chainId),
      byChain->Array.map(((_, checkpointId)) => checkpointId->BigInt.toString),
    )->(Utils.magic: ((array<ChainId.t>, array<string>)) => unknown)
  }

// The relation a per-chain query joins its bounds in from, and the bound to
// compare a checkpoint id against once joined. Cast to the widest integer type
// rather than the chain-id column's own: nothing indexes these columns, so the
// join only needs the values to compare.
let boundsRelation = `unnest($1::${(Postgres.BigInt :> string)}[],$2::${(Postgres.BigInt :> string)}[]) AS envio_bounds(chain_id, safe_checkpoint_id)`
let boundsChainId = "envio_bounds.chain_id"
let boundsCheckpointId = "envio_bounds.safe_checkpoint_id"
