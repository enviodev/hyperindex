// How checkpoint ids are handed out. A schema with a cross-chain entity has
// rows any chain's reorg can reach, so its checkpoints have to be comparable
// across chains and come from one shared counter. Without one, no chain can
// touch another's rows, and each gets a counter of its own — which is what lets
// a rollback, a prune or a resume name one chain without saying anything about
// the others.
type t =
  | Global
  | PerChain

let fromEntities = (entities: array<Internal.entityConfig>) =>
  entities->Array.some(entityConfig => entityConfig.crossChain) ? Global : PerChain

// The committed (or processed) id a scope's rows compare against. A chain scope
// reads its own. A cross-chain scope spans every chain: under one shared
// sequence the highest id is exactly how far the scope has got, while per-chain
// ids aren't comparable across chains, so only the lowest is an id every chain
// has passed.
let forScope = (sequence: t, frontier: Frontier.t, ~scope: Internal.chainScope) =>
  switch scope {
  | Chain(chainId) => frontier->Frontier.get(chainId)
  | CrossChain =>
    switch sequence {
    | Global => frontier->Frontier.max
    | PerChain => frontier->Frontier.min
    }
  }

// Hands out the ids of one batch, starting from where the frontier left each
// chain. Under `Global` the ids come from a single run of the counter, so they
// interleave across chains in allocation order; under `PerChain` each chain
// continues its own.
type cursor = {sequence: t, mutable highest: Internal.checkpointId, frontier: Frontier.t}

let cursor = (sequence: t, ~frontier: Frontier.t) => {
  sequence,
  highest: frontier->Frontier.max,
  frontier: frontier->Frontier.copy,
}

let next = (cursor, ~chainId): Internal.checkpointId => {
  let checkpointId =
    switch cursor.sequence {
    | Global => cursor.highest
    | PerChain => cursor.frontier->Frontier.get(chainId)
    }->BigInt.add(1n)
  cursor.highest = Pervasives.max(cursor.highest, checkpointId)
  cursor.frontier->Frontier.set(chainId, checkpointId)
  checkpointId
}

let cursorFrontier = cursor => cursor.frontier

// The ids a query compares each chain's rows against, together with the
// sequence that decides how they narrow. Built in one place from a frontier, so
// a bound can't hold ids from one sequence and be read as the other.
type bounds = {sequence: t, byChain: Frontier.t}

let bounds = (sequence: t, byChain: Frontier.t) => {sequence, byChain}

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

let sql = (bounds: bounds, ~chainIdColumn: option<string>, ~tableRef: string): sql =>
  switch (bounds.sequence, chainIdColumn) {
  | (Global, _) => {join: "", using: "", usingMatch: "", checkpointId: "$1"}
  | (PerChain, Some(column)) =>
    let chainMatch = `envio_bounds.chain_id = ${tableRef}."${column}"`
    {
      join: ` JOIN ${relation} ON ${chainMatch}`,
      using: ` USING ${relation}`,
      usingMatch: ` AND ${chainMatch}`,
      checkpointId: "envio_bounds.checkpoint_id",
    }
  | (PerChain, None) =>
    JsError.throwWithMessage(
      "Internal error: per-chain checkpoint bounds can't bound a table with no chain-id column. Only a schema whose entities are all per-chain has them.",
    )
  }

// Bound in the order `sql` reads them: under one shared sequence the lowest of
// the ids as `$1` (every chain is held to it), otherwise the chains and their
// own ids as the two parallel arrays the relation unnests.
let params = (bounds: bounds): unknown =>
  switch bounds.sequence {
  | Global =>
    [bounds.byChain->Frontier.min->BigInt.toString]->(Utils.magic: array<string> => unknown)
  | PerChain =>
    let entries = bounds.byChain->Frontier.entries
    [
      entries->Array.map(((chainId, _)) => chainId)->(Utils.magic: array<ChainId.t> => unknown),
      entries
      ->Array.map(((_, checkpointId)) => checkpointId->BigInt.toString)
      ->(Utils.magic: array<string> => unknown),
    ]->(Utils.magic: array<unknown> => unknown)
  }
