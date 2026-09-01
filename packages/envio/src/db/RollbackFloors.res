// How far back a reorg rollback takes each chain. A chain's floor is the last
// checkpoint it keeps: everything above one is deleted, and a chain with no
// floor is left untouched. Superseding an unwritten rollback with a new one is a
// pointwise minimum, which is associative, commutative and idempotent — so a
// merge can neither lose a chain's floor nor raise it.

type entry = {
  chainId: ChainId.t,
  floorCheckpointId: Internal.checkpointId,
  // The last block the reorg that set this floor left valid. Progress recomputed
  // from the surviving checkpoints alone can land above it: the blocks between
  // the fork and the chain's next checkpoint carried no events on the orphaned
  // chain, but the chain replacing it can have its own. Absent for a chain
  // dragged along by another chain's reorg, which has no fork of its own.
  forkBlockNumber: option<int>,
}

type t = {
  byChainId: dict<entry>,
  // The floor every chain shares, when the rollback was built to reach all of
  // them at one. It is what lets a query over every chain's rows run as a single
  // unnarrowed statement, and the only floor a table with no chain of its own
  // can be bounded by.
  everyChainFloor: option<Internal.checkpointId>,
}

// The rollback of a schema whose chains can't have written each other's rows.
let isolated = (~chainId, ~floorCheckpointId, ~forkBlockNumber) => {
  let byChainId = Dict.make()
  byChainId->ChainId.Dict.set(
    chainId,
    {chainId, floorCheckpointId, forkBlockNumber: Some(forkBlockNumber)},
  )
  {byChainId, everyChainFloor: None}
}

// The rollback of a schema with a cross-chain entity, where a reorg on one chain
// can have changed a row any chain wrote: every chain goes back to the same
// checkpoint, and only the chain that reorged has a fork block of its own.
let global = (~chainIds: array<ChainId.t>, ~floorCheckpointId, ~reorgChainId, ~forkBlockNumber) => {
  let byChainId = Dict.make()
  chainIds->Array.forEach(chainId =>
    byChainId->ChainId.Dict.set(
      chainId,
      {
        chainId,
        floorCheckpointId,
        forkBlockNumber: chainId === reorgChainId ? Some(forkBlockNumber) : None,
      },
    )
  )
  {byChainId, everyChainFloor: Some(floorCheckpointId)}
}

let mergeEntries = (a: entry, b: entry) => {
  chainId: a.chainId,
  floorCheckpointId: Pervasives.min(a.floorCheckpointId, b.floorCheckpointId),
  forkBlockNumber: Utils.Math.minOptInt(a.forkBlockNumber, b.forkBlockNumber),
}

// Folds an unwritten rollback into the one replacing it. The new diff's deletes
// have to cover everything the pending one would have deleted, so every chain
// keeps the lower of the two floors and the lower of the two fork blocks.
let merge = (pending: t, next: t) => {
  let byChainId = pending.byChainId->Utils.Dict.shallowCopy
  next.byChainId->Utils.Dict.forEach(entry =>
    byChainId->ChainId.Dict.set(
      entry.chainId,
      switch byChainId->ChainId.Dict.dangerouslyGetNonOption(entry.chainId) {
      | Some(pendingEntry) => mergeEntries(pendingEntry, entry)
      | None => entry
      },
    )
  )
  {
    byChainId,
    // Only a floor both rollbacks held every chain to is still one the merged
    // floors hold every chain to. Where one of them reached a single chain, the
    // chains keep their own floors and the merge has no shared one.
    everyChainFloor: switch (pending.everyChainFloor, next.everyChainFloor) {
    | (Some(pending), Some(next)) => Some(Pervasives.min(pending, next))
    | _ => None
    },
  }
}

// Bounds where the rollback may leave a chain, when its reorg had a fork block.
let forkBlockNumber = (floors: t, chainId) =>
  floors.byChainId
  ->ChainId.Dict.dangerouslyGetNonOption(chainId)
  ->Option.flatMap(entry => entry.forkBlockNumber)

// What one statement of a rollback query binds. The floor is always `$1`, so a
// query can name it as many times as it needs — the entity restore reads it on
// both sides of its EXISTS — and a statement narrowed to one chain binds that
// chain as `$2`.
type statement = {
  // Appended to the query's WHERE. Empty when the statement covers every chain.
  chainPredicate: string,
  params: unknown,
}

let makeParams = (~floorCheckpointId: Internal.checkpointId, ~chainId: option<ChainId.t>) => {
  let floorCheckpointId = floorCheckpointId->BigInt.toString->(Utils.magic: string => unknown)
  switch chainId {
  | Some(chainId) => [floorCheckpointId, chainId->(Utils.magic: ChainId.t => unknown)]
  | None => [floorCheckpointId]
  }->(Utils.magic: array<unknown> => unknown)
}

// The statements a rollback query has to run to cover every chain it touches.
// A rollback reaching every chain at one floor is a single unnarrowed statement
// over all of them; otherwise each chain is deleted down to its own floor,
// leaving the chains with no floor untouched.
//
// A table with no chain-id column of its own holds a cross-chain entity's rows,
// which need the floor every chain shares. Those entities exist only in a schema
// where `Config.isIsolatedMultichain` is false, so every rollback reaching them
// is `global` and has one — and a rollback that doesn't leaves the table alone
// rather than deleting from it on a floor that isn't every chain's.
let statements = (floors: t, ~chainIdColumn: option<string>) =>
  switch (chainIdColumn, floors.everyChainFloor) {
  | (_, Some(floorCheckpointId)) => [
      {chainPredicate: "", params: makeParams(~floorCheckpointId, ~chainId=None)},
    ]
  | (None, None) => []
  | (Some(column), None) =>
    floors.byChainId
    ->Dict.valuesToArray
    ->Array.map(({chainId, floorCheckpointId}) => {
      chainPredicate: ` AND "${column}" = $2`,
      params: makeParams(~floorCheckpointId, ~chainId=Some(chainId)),
    })
  }
