open Belt

type t = {
  shouldRollbackOnReorg: bool,
  lastBlockScannedHashes: ReorgDetection.LastBlockScannedHashes.t,
}

let make = (
  ~chainId,
  ~maxReorgDepth,
  ~shouldRollbackOnReorg,
  ~reorgCheckpoints: array<InternalTable.Checkpoints.reorgCheckpoint>,
) => {
  {
    shouldRollbackOnReorg,
    lastBlockScannedHashes: reorgCheckpoints
    ->Array.keepMapU(reorgCheckpoint => {
      if reorgCheckpoint.chainId === chainId {
        Some({
          ReorgDetection.blockNumber: reorgCheckpoint.blockNumber,
          blockHash: reorgCheckpoint.blockHash,
        })
      } else {
        None
      }
    })
    ->ReorgDetection.LastBlockScannedHashes.makeWithData(~maxReorgDepth),
  }
}

let registerReorgGuard = (
  chainBlocks: t,
  ~reorgGuard: ReorgDetection.reorgGuard,
  ~currentBlockHeight: int,
) => {
  let (updatedLastBlockScannedHashes, reorgResult: ReorgDetection.reorgResult) =
    chainBlocks.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
      ~reorgGuard,
      ~currentBlockHeight,
      ~shouldRollbackOnReorg=chainBlocks.shouldRollbackOnReorg,
    )
  (
    {
      ...chainBlocks,
      lastBlockScannedHashes: updatedLastBlockScannedHashes,
    },
    reorgResult,
  )
}
