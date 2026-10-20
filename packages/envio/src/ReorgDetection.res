type blockData = {
  blockHash: string,
  blockNumber: int,
}

type reorgDetected = {
  scannedBlock: blockData,
  receivedBlock: blockData,
}

type reorgResult = NoReorg | ReorgDetected(reorgDetected)
