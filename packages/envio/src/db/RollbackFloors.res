// How far back a reorg rollback takes each chain: the last checkpoint each
// keeps, and for a chain whose own reorg set its floor, the last block that
// reorg left valid. Superseding an unwritten rollback with a new one is a
// pointwise minimum, so a merge can neither lose a chain's floor nor raise it.
type t = {
  floors: CheckpointSequence.bounds,
  // Progress recomputed from the surviving checkpoints alone can land above the
  // fork: the blocks between it and the chain's next checkpoint carried no
  // events on the orphaned chain, but the chain replacing it can have its own.
  // Absent for a chain dragged along by another chain's reorg.
  forkBlockNumberByChain: dict<int>,
}

// Under one shared sequence a reorg on any chain can have changed any chain's
// rows, so every chain goes back to the same checkpoint; with a counter per
// chain the floor names the reorg chain alone and every sibling is left alone.
let make = (
  ~sequence: CheckpointSequence.t,
  ~chainIds: array<ChainId.t>,
  ~reorgChainId,
  ~floorCheckpointId,
  ~forkBlockNumber,
) => {
  floors: CheckpointSequence.bounds(
    sequence,
    switch sequence {
    | Global => Frontier.make(~chainIds, ~checkpointId=floorCheckpointId)
    | PerChain => Frontier.fromEntries([(reorgChainId, floorCheckpointId)])
    },
  ),
  forkBlockNumberByChain: Dict.fromArray([(reorgChainId->ChainId.toString, forkBlockNumber)]),
}

let mergeForkBlocks = (pending: dict<int>, next: dict<int>) => {
  let merged = pending->Dict.copy
  next->Utils.Dict.forEachWithKey((blockNumber, key) =>
    merged->Dict.set(
      key,
      switch merged->Utils.Dict.dangerouslyGetNonOption(key) {
      | Some(pending) => Pervasives.min(pending, blockNumber)
      | None => blockNumber
      },
    )
  )
  merged
}

let merge = (pending: t, next: t) => {
  floors: CheckpointSequence.bounds(
    next.floors.sequence,
    Frontier.mergeMin(pending.floors.byChain, next.floors.byChain),
  ),
  forkBlockNumberByChain: mergeForkBlocks(
    pending.forkBlockNumberByChain,
    next.forkBlockNumberByChain,
  ),
}

let forkBlockNumber = (floors: t, chainId) =>
  floors.forkBlockNumberByChain->ChainId.Dict.dangerouslyGetNonOption(chainId)
