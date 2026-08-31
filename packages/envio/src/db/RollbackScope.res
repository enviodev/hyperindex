// How far across chains a reorg rollback reaches. `Isolated` is only chosen for
// a schema with no cross-chain entity, where a reorg on one chain can't have
// changed a row another chain owns — every sibling then keeps its progress,
// entities, history and checkpoints.
type t =
  | Global
  | Isolated(ChainId.t)

// Appended to the WHERE of a rollback query, which binds its target checkpoint
// as $1. An isolated rollback binds its chain id as $2 so only the rows that
// chain owns match.
let predicate = (scope, ~chainIdColumn: option<string>) =>
  switch (scope, chainIdColumn) {
  | (Global, _) => ""
  | (Isolated(_), Some(column)) => ` AND "${column}" = $2`
  | (Isolated(_), None) =>
    JsError.throwWithMessage(
      "Internal error: a rollback isolated to one chain needs a chain-id column to narrow to.",
    )
  }

// The parameters such a query binds, in the order `predicate` reads them.
let params = (scope, ~targetCheckpointId: Internal.checkpointId): unknown => {
  let targetCheckpointId = targetCheckpointId->BigInt.toString->(Utils.magic: string => unknown)
  switch scope {
  | Global => [targetCheckpointId]
  | Isolated(chainId) => [targetCheckpointId, chainId->(Utils.magic: ChainId.t => unknown)]
  }->(Utils.magic: array<unknown> => unknown)
}
