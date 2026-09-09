// How far back a reorg rollback takes each chain: the last checkpoint each
// keeps, and for a chain whose own reorg set its floor, the last block that
// reorg left valid. Superseding an unwritten rollback with a new one is a
// pointwise minimum, so a merge can neither lose a chain's floor nor raise it.
type t = {
  checkpointBounds: CheckpointSequence.checkpointBoundsByChain,
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
  checkpointBounds: {
    CheckpointSequence.sequence,
    byChain: switch sequence {
    | SharedAcrossChains =>
      chainIds->Array.map(chainId => (chainId, floorCheckpointId))->Frontier.fromEntries
    | PerChain => Frontier.fromEntries([(reorgChainId, floorCheckpointId)])
    },
  },
  forkBlockNumberByChain: Dict.fromArray([(reorgChainId->ChainId.toString, forkBlockNumber)]),
}

let merge = (pending: t, next: t) => {
  checkpointBounds: {
    CheckpointSequence.sequence: next.checkpointBounds.sequence,
    byChain: Frontier.mergeMin(pending.checkpointBounds.byChain, next.checkpointBounds.byChain),
  },
  forkBlockNumberByChain: Utils.Dict.mergeWith(
    pending.forkBlockNumberByChain,
    next.forkBlockNumberByChain,
    Pervasives.min,
  ),
}

let forkBlockNumber = (floors: t, chainId) =>
  floors.forkBlockNumberByChain->ChainId.Dict.dangerouslyGetNonOption(chainId)
