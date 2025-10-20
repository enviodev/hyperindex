// We need this module to effectively track safe checkpoint id
// this is very cheap to do in memory, while requires a lot of work on a db
// especially when save_full_history is enabled.
// The safe checkpoint id can be used to optimize checkpoints traverse logic and
// make pruning operation super cheap.
type t = {
  checkpointIds: array<int>,
  checkpointBlockNumbers: array<int>,
  maxReorgDepth: int,
}

let make = (
  ~maxReorgDepth,
  ~shouldRollbackOnReorg,
  ~chainReorgCheckpoints: array<Internal.reorgCheckpoint>,
) => {
  if maxReorgDepth > 0 && shouldRollbackOnReorg {
    let checkpointIds = Belt.Array.makeUninitializedUnsafe(chainReorgCheckpoints->Array.length)
    let checkpointBlockNumbers = Belt.Array.makeUninitializedUnsafe(
      chainReorgCheckpoints->Array.length,
    )
    chainReorgCheckpoints->Js.Array2.forEachi((checkpoint, idx) => {
      checkpointIds->Belt.Array.setUnsafe(idx, checkpoint.checkpointId)
      checkpointBlockNumbers->Belt.Array.setUnsafe(idx, checkpoint.blockNumber)
    })
    Some({
      checkpointIds,
      checkpointBlockNumbers,
      maxReorgDepth,
    })
  } else {
    None
  }
}

let getSafeCheckpointId = (safeCheckpointTracking: t, ~sourceBlockNumber: int) => {
  let safeBlockNumber = sourceBlockNumber - safeCheckpointTracking.maxReorgDepth

  switch safeCheckpointTracking.checkpointIds {
  | [] => 0
  | _
    if safeCheckpointTracking.checkpointBlockNumbers->Belt.Array.getUnsafe(0) > safeBlockNumber => 0
  | [checkpointId] => checkpointId
  | _ => {
      let trackingCheckpointsCount = safeCheckpointTracking.checkpointIds->Array.length
      let result = ref(None)
      let idx = ref(1)

      while idx.contents < trackingCheckpointsCount && result.contents === None {
        if (
          safeCheckpointTracking.checkpointBlockNumbers->Belt.Array.getUnsafe(idx.contents) >
            safeBlockNumber
        ) {
          result :=
            Some(safeCheckpointTracking.checkpointIds->Belt.Array.getUnsafe(idx.contents - 1))
        }
        idx := idx.contents + 1
      }

      switch result.contents {
      | Some(checkpointId) => checkpointId
      | None =>
        safeCheckpointTracking.checkpointIds->Belt.Array.getUnsafe(trackingCheckpointsCount - 1)
      }
    }
  }
}

let updateOnNewBatch = (
  safeCheckpointTracking: t,
  ~sourceBlockNumber: int,
  ~chainId: int,
  ~batchCheckpointIds: array<int>,
  ~batchCheckpointBlockNumbers: array<int>,
  ~batchCheckpointChainIds: array<int>,
) => {
  let safeCheckpointId = getSafeCheckpointId(safeCheckpointTracking, ~sourceBlockNumber)

  let mutCheckpointIds = []
  let mutCheckpointBlockNumbers = []

  // Copy + Clean up old checkpoints
  for idx in 0 to safeCheckpointTracking.checkpointIds->Array.length - 1 {
    let checkpointId = safeCheckpointTracking.checkpointIds->Belt.Array.getUnsafe(idx)
    if checkpointId >= safeCheckpointId {
      mutCheckpointIds->Js.Array2.push(checkpointId)->ignore
      mutCheckpointBlockNumbers
      ->Js.Array2.push(safeCheckpointTracking.checkpointBlockNumbers->Belt.Array.getUnsafe(idx))
      ->ignore
    }
  }

  // Append new checkpoints
  for idx in 0 to batchCheckpointIds->Array.length - 1 {
    if batchCheckpointChainIds->Belt.Array.getUnsafe(idx) === chainId {
      mutCheckpointIds->Js.Array2.push(batchCheckpointIds->Belt.Array.getUnsafe(idx))->ignore
      mutCheckpointBlockNumbers
      ->Js.Array2.push(batchCheckpointBlockNumbers->Belt.Array.getUnsafe(idx))
      ->ignore
    }
  }

  {
    checkpointIds: mutCheckpointIds,
    checkpointBlockNumbers: mutCheckpointBlockNumbers,
    maxReorgDepth: safeCheckpointTracking.maxReorgDepth,
  }
}

let rollback = (safeCheckpointTracking: t, ~targetBlockNumber: int) => {
  let mutCheckpointIds = []
  let mutCheckpointBlockNumbers = []

  for idx in 0 to safeCheckpointTracking.checkpointIds->Array.length - 1 {
    let blockNumber = safeCheckpointTracking.checkpointBlockNumbers->Belt.Array.getUnsafe(idx)
    if blockNumber <= targetBlockNumber {
      mutCheckpointIds
      ->Js.Array2.push(safeCheckpointTracking.checkpointIds->Belt.Array.getUnsafe(idx))
      ->ignore
      mutCheckpointBlockNumbers
      ->Js.Array2.push(safeCheckpointTracking.checkpointBlockNumbers->Belt.Array.getUnsafe(idx))
      ->ignore
    }
  }

  {
    checkpointIds: mutCheckpointIds,
    checkpointBlockNumbers: mutCheckpointBlockNumbers,
    maxReorgDepth: safeCheckpointTracking.maxReorgDepth,
  }
}
