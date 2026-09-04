// A checkpoint id per chain that a query compares each chain's rows against. A
// schema with a cross-chain entity gets one bound for every chain, since a reorg
// on any chain reaches every chain's rows; otherwise each chain has its own, and
// a chain absent from them is left alone.
type t =
  | EveryChain(Internal.checkpointId)
  | PerChain(array<(ChainId.t, Internal.checkpointId)>)

// The pieces a query splices in to read its bound as `checkpointId`: a SELECT
// joins the bounds next to its table with `join`, a DELETE names them with
// `using` and matches the chain with `usingMatch` in its WHERE.
type sql = {
  join: string,
  using: string,
  usingMatch: string,
  checkpointId: string,
}

// The chain ids are cast to the widest integer type rather than the column's
// own: nothing indexes the join, so the values only have to compare.
let relation = `unnest($1::${(Postgres.BigInt :> string)}[],$2::${(Postgres.BigInt :> string)}[]) AS envio_bounds(chain_id, checkpoint_id)`

let sql = (bounds: t, ~chainIdColumn: option<string>, ~tableRef: string): sql =>
  switch (bounds, chainIdColumn) {
  | (EveryChain(_), _) => {join: "", using: "", usingMatch: "", checkpointId: "$1"}
  | (PerChain(_), Some(column)) =>
    let chainMatch = `envio_bounds.chain_id = ${tableRef}."${column}"`
    {
      join: ` JOIN ${relation} ON ${chainMatch}`,
      using: ` USING ${relation}`,
      usingMatch: ` AND ${chainMatch}`,
      checkpointId: "envio_bounds.checkpoint_id",
    }
  | (PerChain(_), None) =>
    JsError.throwWithMessage(
      "Internal error: per-chain checkpoint bounds can't bound a table with no chain-id column. Only a schema whose entities are all per-chain has them.",
    )
  }

// Bound in the order `sql` reads them: the one bound as `$1`, or the chains and
// their bounds as the two parallel arrays the relation unnests.
let params = (bounds: t): unknown =>
  switch bounds {
  | EveryChain(checkpointId) =>
    [checkpointId->BigInt.toString]->(Utils.magic: array<string> => unknown)
  | PerChain(byChain) =>
    [
      byChain->Array.map(((chainId, _)) => chainId)->(Utils.magic: array<ChainId.t> => unknown),
      byChain
      ->Array.map(((_, checkpointId)) => checkpointId->BigInt.toString)
      ->(Utils.magic: array<string> => unknown),
    ]->(Utils.magic: array<unknown> => unknown)
  }
