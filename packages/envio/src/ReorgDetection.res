// Reorg detection lives in the Rust `BlockStore`. A validated response is
// compared with the persistent store and only that cross-store mismatch is a
// reorg signal; response-internal conflicts are retried by SourceManager.

type blockData = {
  // Block hash is used for actual comparison to test for reorg
  blockHash: string,
  blockNumber: int,
}

type reorgDetected = {
  scannedBlock: blockData,
  receivedBlock: blockData,
}

let reorgDetectedToLogParams = (reorgDetected: reorgDetected, ~shouldRollbackOnReorg) => {
  let {scannedBlock, receivedBlock} = reorgDetected
  {
    "msg": `Blockchain reorg detected. ${shouldRollbackOnReorg
        ? "Initiating indexer rollback"
        : "NOT initiating indexer rollback due to configuration"}.`,
    "blockNumber": scannedBlock.blockNumber,
    "indexedBlockHash": scannedBlock.blockHash,
    "receivedBlockHash": receivedBlock.blockHash,
  }
}

type reorgResult = NoReorg | ReorgDetected(reorgDetected)
