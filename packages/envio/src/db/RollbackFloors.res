// How far back a reorg rollback takes each chain: the last checkpoint each keeps,
// and for a chain whose own reorg set its floor, the last block that reorg left
// valid. Superseding an unwritten rollback with a new one is a pointwise
// minimum, so a merge can neither lose a chain's floor nor raise it.
type t = {
  floors: CheckpointBounds.t,
  // Progress recomputed from the surviving checkpoints alone can land above the
  // fork: the blocks between it and the chain's next checkpoint carried no
  // events on the orphaned chain, but the chain replacing it can have its own.
  // Absent for a chain dragged along by another chain's reorg.
  forkBlockNumberByChain: array<(ChainId.t, int)>,
}

// The rollback of a schema whose chains can't have written each other's rows.
let isolated = (~chainId, ~floorCheckpointId, ~forkBlockNumber) => {
  floors: PerChain([(chainId, floorCheckpointId)]),
  forkBlockNumberByChain: [(chainId, forkBlockNumber)],
}

// The rollback of a schema with a cross-chain entity: every chain goes back to
// the same checkpoint.
let global = (~floorCheckpointId, ~reorgChainId, ~forkBlockNumber) => {
  floors: EveryChain(floorCheckpointId),
  forkBlockNumberByChain: [(reorgChainId, forkBlockNumber)],
}

let mergeByChain = (pending: array<(ChainId.t, 'a)>, next: array<(ChainId.t, 'a)>) => {
  let merged = pending->Array.copy
  next->Array.forEach(((chainId, value)) =>
    switch merged->Array.findIndexOpt(((mergedChainId, _)) => mergedChainId === chainId) {
    | Some(idx) =>
      let (_, pendingValue) = merged->Array.getUnsafe(idx)
      merged->Array.setUnsafe(idx, (chainId, Pervasives.min(pendingValue, value)))
    | None => merged->Array.push((chainId, value))
    }
  )
  merged
}

let merge = (pending: t, next: t) => {
  floors: switch (pending.floors, next.floors) {
  | (EveryChain(pending), EveryChain(next)) => EveryChain(Pervasives.min(pending, next))
  | (PerChain(pending), PerChain(next)) => PerChain(mergeByChain(pending, next))
  | (EveryChain(_), PerChain(_)) | (PerChain(_), EveryChain(_)) =>
    JsError.throwWithMessage(
      "Internal error: a rollback reaching every chain can't be merged with one isolated to a chain. The schema decides which a run builds, and it doesn't change.",
    )
  },
  forkBlockNumberByChain: mergeByChain(pending.forkBlockNumberByChain, next.forkBlockNumberByChain),
}

let forkBlockNumber = (floors: t, chainId) =>
  floors.forkBlockNumberByChain
  ->Array.find(((forkChainId, _)) => forkChainId === chainId)
  ->Option.map(((_, forkBlockNumber)) => forkBlockNumber)
