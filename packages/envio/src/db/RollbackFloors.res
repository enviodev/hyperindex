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
  // Whether this rollback was built to reach every configured chain. Only then
  // does one floor bound the whole rollback, which is what lets a query over
  // every chain's rows run as a single statement.
  reachesEveryChain: bool,
}

// The rollback of a schema whose chains can't have written each other's rows.
let isolated = (~chainId, ~floorCheckpointId, ~forkBlockNumber) => {
  let byChainId = Dict.make()
  byChainId->ChainId.Dict.set(
    chainId,
    {chainId, floorCheckpointId, forkBlockNumber: Some(forkBlockNumber)},
  )
  {byChainId, reachesEveryChain: false}
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
  {byChainId, reachesEveryChain: true}
}

let mergeEntries = (a: entry, b: entry) => {
  chainId: a.chainId,
  floorCheckpointId: Pervasives.min(a.floorCheckpointId, b.floorCheckpointId),
  forkBlockNumber: switch (a.forkBlockNumber, b.forkBlockNumber) {
  | (Some(a), Some(b)) => Some(Pervasives.min(a, b))
  | (Some(forkBlockNumber), None)
  | (None, Some(forkBlockNumber)) =>
    Some(forkBlockNumber)
  | (None, None) => None
  },
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
    reachesEveryChain: pending.reachesEveryChain || next.reachesEveryChain,
  }
}

// Bounds where the rollback may leave a chain, when its reorg had a fork block.
let forkBlockNumber = (floors: t, chainId) =>
  floors.byChainId
  ->ChainId.Dict.dangerouslyGetNonOption(chainId)
  ->Option.flatMap(entry => entry.forkBlockNumber)

let entries = (floors: t) => floors.byChainId->Dict.valuesToArray

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

let lowestFloor = (entries: array<entry>) =>
  entries->Array.reduce((entries->Array.getUnsafe(0)).floorCheckpointId, (lowest, entry) =>
    Pervasives.min(lowest, entry.floorCheckpointId)
  )

// The statements a rollback query has to run to cover every chain it touches.
//
// A table with no chain-id column of its own holds a cross-chain entity's rows,
// which exist only in a schema where `Config.isIsolatedMultichain` is false —
// there every rollback is `global`, so the floors are uniform and the lowest is
// every chain's.
//
// A rollback that reaches every chain at one floor is likewise a single
// statement over all of them. Otherwise each chain is deleted down to its own
// floor, leaving the chains with no floor untouched.
let statements = (floors: t, ~chainIdColumn: option<string>) => {
  let uniform = floorCheckpointId => [
    {chainPredicate: "", params: makeParams(~floorCheckpointId, ~chainId=None)},
  ]

  switch (floors->entries, chainIdColumn) {
  | ([], _) => []
  | (entries, None) => uniform(entries->lowestFloor)
  | (entries, Some(column)) =>
    let lowest = entries->lowestFloor
    if floors.reachesEveryChain && entries->Array.every(e => e.floorCheckpointId === lowest) {
      uniform(lowest)
    } else {
      entries->Array.map(({chainId, floorCheckpointId}) => {
        chainPredicate: ` AND "${column}" = $2`,
        params: makeParams(~floorCheckpointId, ~chainId=Some(chainId)),
      })
    }
  }
}
