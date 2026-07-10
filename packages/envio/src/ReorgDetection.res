// Reorg-detection data shapes. The detection itself lives in the Rust
// `BlockStore`: merging a fetch-response page compares block hashes and
// reports a mismatch, and the store keeps in-threshold hashes on prune.

type blockDataWithTimestamp = {
  blockHash: string,
  blockNumber: int,
  blockTimestamp: int,
}

type blockData = {
  // Block hash is used for actual comparison to test for reorg
  blockHash: string,
  blockNumber: int,
}

external generalizeBlockDataWithTimestamp: blockDataWithTimestamp => blockData = "%identity"

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
