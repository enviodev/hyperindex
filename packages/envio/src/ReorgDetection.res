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

type t = {
  // Whether to rollback on reorg
  // Even if it's disabled, we still track reorgs checkpoints in memory
  // and log when we detect an unhandled reorg
  shouldRollbackOnReorg: bool,
  // Number of blocks behind head, we want to keep track
  // as a threshold for reorgs. If for eg. this is 200,
  // it means we are accounting for reorgs up to 200 blocks
  // behind the head
  maxReorgDepth: int,
  // A hash map of recent blockdata by block number to make comparison checks
  // for reorgs.
  dataByBlockNumber: dict<blockData>,
}

let make = (
  ~chainReorgCheckpoints: array<Internal.reorgCheckpoint>,
  ~maxReorgDepth,
  ~shouldRollbackOnReorg,
) => {
  let dataByBlockNumber = Dict.make()

  chainReorgCheckpoints->Belt.Array.forEach(block => {
    dataByBlockNumber->Utils.Dict.setByInt(
      block.blockNumber,
      {
        blockHash: block.blockHash,
        blockNumber: block.blockNumber,
      },
    )
  })

  {
    shouldRollbackOnReorg,
    maxReorgDepth,
    dataByBlockNumber,
  }
}

let getDataByBlockNumberCopyInThreshold = ({dataByBlockNumber, maxReorgDepth}: t, ~knownHeight) => {
  // Js engine automatically orders numeric object keys
  let ascBlockNumberKeys = dataByBlockNumber->Dict.keysToArray
  let thresholdBlockNumber = knownHeight - maxReorgDepth

  let copy = Dict.make()

  for idx in 0 to ascBlockNumberKeys->Array.length - 1 {
    let blockNumberKey = ascBlockNumberKeys->Array.getUnsafe(idx)
    let scannedBlock = dataByBlockNumber->Dict.getUnsafe(blockNumberKey)
    let isInReorgThreshold = scannedBlock.blockNumber >= thresholdBlockNumber
    if isInReorgThreshold {
      copy->Dict.set(blockNumberKey, scannedBlock)
    }
  }

  copy
}

/** Registers observed (blockNumber, blockHash) pairs from a range fetch, prunes
 * unneeded data, and returns the updated state.
 *
 * Iterates the provided block hashes, skips entries outside the reorg threshold,
 * and compares each one against the previously scanned data. Returns on the first
 * mismatch as `ReorgDetected`.
 *
 * Resets internal state if shouldRollbackOnReorg is false (detect-only mode).
 */
let registerReorgGuard = (
  {maxReorgDepth, shouldRollbackOnReorg} as self: t,
  ~blockHashes: array<blockData>,
  ~knownHeight,
) => {
  let dataByBlockNumberCopyInThreshold = self->getDataByBlockNumberCopyInThreshold(~knownHeight)
  let thresholdBlockNumber = knownHeight - maxReorgDepth

  let maybeReorgDetected = ref(None)
  let idx = ref(0)
  while maybeReorgDetected.contents === None && idx.contents < blockHashes->Array.length {
    let receivedBlock = blockHashes->Array.getUnsafe(idx.contents)
    if receivedBlock.blockNumber >= thresholdBlockNumber {
      let key = receivedBlock.blockNumber->Int.toString
      // The working copy contains both previously scanned blocks AND blocks
      // already written by earlier iterations of this same call, so a duplicate
      // block number with a mismatching hash inside `blockHashes` itself is
      // flagged as a reorg.
      switch dataByBlockNumberCopyInThreshold->Utils.Dict.dangerouslyGetNonOption(key) {
      | Some(scannedBlock) if scannedBlock.blockHash !== receivedBlock.blockHash =>
        maybeReorgDetected := Some({receivedBlock, scannedBlock})
      | _ => dataByBlockNumberCopyInThreshold->Dict.set(key, receivedBlock)
      }
    }
    idx := idx.contents + 1
  }

  switch maybeReorgDetected.contents {
  | Some(reorgDetected) => (
      shouldRollbackOnReorg
        ? self
        : make(~chainReorgCheckpoints=[], ~maxReorgDepth, ~shouldRollbackOnReorg),
      ReorgDetected(reorgDetected),
    )
  | None => (
      {
        maxReorgDepth,
        dataByBlockNumber: dataByBlockNumberCopyInThreshold,
        shouldRollbackOnReorg,
      },
      NoReorg,
    )
  }
}

/**
Returns the latest block number which matches block number and hashes in the provided array
If it doesn't exist in the reorg threshold it returns NotFound
*/
let getLatestValidScannedBlock = (
  reorgDetection: t,
  ~blockNumbersAndHashes: array<blockDataWithTimestamp>,
) => {
  let verifiedDataByBlockNumber = Dict.make()
  for idx in 0 to blockNumbersAndHashes->Array.length - 1 {
    let blockData = blockNumbersAndHashes->Array.getUnsafe(idx)
    verifiedDataByBlockNumber->Dict.set(blockData.blockNumber->Int.toString, blockData)
  }
  // Js engine automatically orders numeric object keys
  let ascBlockNumberKeys = verifiedDataByBlockNumber->Dict.keysToArray

  let getPrevScannedBlockNumber = idx =>
    ascBlockNumberKeys
    ->Belt.Array.get(idx - 1)
    ->Option.map(key => {
      (verifiedDataByBlockNumber->Dict.getUnsafe(key)).blockNumber
    })

  let rec loop = idx => {
    switch ascBlockNumberKeys->Belt.Array.get(idx) {
    | Some(blockNumberKey) =>
      switch reorgDetection.dataByBlockNumber->Utils.Dict.dangerouslyGetNonOption(blockNumberKey) {
      | Some(scannedBlock)
        if (verifiedDataByBlockNumber->Dict.getUnsafe(blockNumberKey)).blockHash ===
          scannedBlock.blockHash =>
        loop(idx + 1)
      | _ => getPrevScannedBlockNumber(idx)
      }
    | None => getPrevScannedBlockNumber(idx)
    }
  }
  loop(0)
}

/**
  Return a BlockNumbersAndHashes.t rolled back to where blockData is less
  than the provided blockNumber
  */
let rollbackToValidBlockNumber = (
  {dataByBlockNumber, maxReorgDepth, shouldRollbackOnReorg}: t,
  ~blockNumber: int,
) => {
  // Js engine automatically orders numeric object keys
  let ascBlockNumberKeys = dataByBlockNumber->Dict.keysToArray

  let newDataByBlockNumber = Dict.make()

  let rec loop = idx => {
    switch ascBlockNumberKeys->Belt.Array.get(idx) {
    | Some(blockNumberKey) => {
        let scannedBlock = dataByBlockNumber->Dict.getUnsafe(blockNumberKey)
        let shouldKeep = scannedBlock.blockNumber <= blockNumber
        if shouldKeep {
          newDataByBlockNumber->Dict.set(blockNumberKey, scannedBlock)
          loop(idx + 1)
        } else {
          ()
        }
      }
    | None => ()
    }
  }
  loop(0)

  {
    maxReorgDepth,
    dataByBlockNumber: newDataByBlockNumber,
    shouldRollbackOnReorg,
  }
}

let getThresholdBlockNumbersBelowBlock = (self: t, ~blockNumber: int, ~knownHeight) => {
  let arr = []

  // Js engine automatically orders numeric object keys
  let ascBlockNumberKeys = self.dataByBlockNumber->Dict.keysToArray
  let thresholdBlockNumber = knownHeight - self.maxReorgDepth

  for idx in 0 to ascBlockNumberKeys->Array.length - 1 {
    let blockNumberKey = ascBlockNumberKeys->Array.getUnsafe(idx)
    let scannedBlock = self.dataByBlockNumber->Dict.getUnsafe(blockNumberKey)
    let isInReorgThreshold = scannedBlock.blockNumber >= thresholdBlockNumber
    if isInReorgThreshold && scannedBlock.blockNumber < blockNumber {
      arr->Array.push(scannedBlock.blockNumber)
    }
  }
  arr
}

let getHashByBlockNumber = (reorgDetection: t, ~blockNumber) => {
  switch reorgDetection.dataByBlockNumber->Utils.Dict.dangerouslyGetByIntNonOption(blockNumber) {
  | Some(v) => Null.Value(v.blockHash)
  | None => Null.Null
  }
}
