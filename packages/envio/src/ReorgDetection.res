type blockData = {
  blockHash: string,
  blockNumber: int,
}

type reorgDetected = {
  scannedBlock: blockData,
  receivedBlock: blockData,
}

let logReorgDetected = (logger, reorgDetected: reorgDetected, ~shouldRollbackOnReorg) => {
  let {scannedBlock, receivedBlock} = reorgDetected
  logger->Logging.info(
    `Blockchain reorg detected. ${shouldRollbackOnReorg
        ? "Initiating indexer rollback"
        : "NOT initiating indexer rollback due to configuration"}.`,
    ~params={
      "blockNumber": scannedBlock.blockNumber,
      "indexedBlockHash": scannedBlock.blockHash,
      "receivedBlockHash": receivedBlock.blockHash,
    },
  )
}

type reorgResult = NoReorg | ReorgDetected(reorgDetected)
