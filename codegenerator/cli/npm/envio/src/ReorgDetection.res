open Belt

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

type reorgGuard = {
  rangeLastBlock: blockData,
  prevRangeLastBlock: option<blockData>,
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
  let dataByBlockNumber = Js.Dict.empty()

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

let getDataByBlockNumberCopyInThreshold = (
  {dataByBlockNumber, maxReorgDepth}: t,
  ~currentBlockHeight,
) => {
  // Js engine automatically orders numeric object keys
  let ascBlockNumberKeys = dataByBlockNumber->Js.Dict.keys
  let thresholdBlockNumber = currentBlockHeight - maxReorgDepth

  let copy = Js.Dict.empty()

  for idx in 0 to ascBlockNumberKeys->Array.length - 1 {
    let blockNumberKey = ascBlockNumberKeys->Js.Array2.unsafe_get(idx)
    let scannedBlock = dataByBlockNumber->Js.Dict.unsafeGet(blockNumberKey)
    let isInReorgThreshold = scannedBlock.blockNumber >= thresholdBlockNumber
    if isInReorgThreshold {
      copy->Js.Dict.set(blockNumberKey, scannedBlock)
    }
  }

  copy
}

/** Registers a new reorg guard, prunes unneeded data, and returns the updated state.
 * Resets internal state if shouldRollbackOnReorg is false (detect-only mode)
  */
let registerReorgGuard = (
  {maxReorgDepth, shouldRollbackOnReorg} as self: t,
  ~reorgGuard: reorgGuard,
  ~currentBlockHeight,
) => {
  let dataByBlockNumberCopyInThreshold =
    self->getDataByBlockNumberCopyInThreshold(~currentBlockHeight)

  let {rangeLastBlock, prevRangeLastBlock} = reorgGuard

  let maybeReorgDetected = switch dataByBlockNumberCopyInThreshold->Utils.Dict.dangerouslyGetNonOption(
    rangeLastBlock.blockNumber->Int.toString,
  ) {
  | Some(scannedBlock) if scannedBlock.blockHash !== rangeLastBlock.blockHash =>
    Some({
      receivedBlock: rangeLastBlock,
      scannedBlock,
    })
  | _ =>
    switch prevRangeLastBlock {
    //If parentHash is None, then it's the genesis block (no reorg)
    //Need to check that parentHash matches because of the dynamic contracts
    | None => None
    | Some(prevRangeLastBlock) =>
      switch dataByBlockNumberCopyInThreshold->Utils.Dict.dangerouslyGetNonOption(
        prevRangeLastBlock.blockNumber->Int.toString,
      ) {
      | Some(scannedBlock) if scannedBlock.blockHash !== prevRangeLastBlock.blockHash =>
        Some({
          receivedBlock: prevRangeLastBlock,
          scannedBlock,
        })
      | _ => None
      }
    }
  }

  switch maybeReorgDetected {
  | Some(reorgDetected) => (
      shouldRollbackOnReorg
        ? self
        : make(~chainReorgCheckpoints=[], ~maxReorgDepth, ~shouldRollbackOnReorg),
      ReorgDetected(reorgDetected),
    )
  | None => {
      dataByBlockNumberCopyInThreshold->Js.Dict.set(
        rangeLastBlock.blockNumber->Int.toString,
        rangeLastBlock,
      )
      switch prevRangeLastBlock {
      | None => ()
      | Some(prevRangeLastBlock) =>
        dataByBlockNumberCopyInThreshold->Js.Dict.set(
          prevRangeLastBlock.blockNumber->Int.toString,
          prevRangeLastBlock,
        )
      }

      (
        {
          maxReorgDepth,
          dataByBlockNumber: dataByBlockNumberCopyInThreshold,
          shouldRollbackOnReorg,
        },
        NoReorg,
      )
    }
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
  let verifiedDataByBlockNumber = Js.Dict.empty()
  for idx in 0 to blockNumbersAndHashes->Array.length - 1 {
    let blockData = blockNumbersAndHashes->Array.getUnsafe(idx)
    verifiedDataByBlockNumber->Js.Dict.set(blockData.blockNumber->Int.toString, blockData)
  }
  // Js engine automatically orders numeric object keys
  let ascBlockNumberKeys = verifiedDataByBlockNumber->Js.Dict.keys

  let getPrevScannedBlockNumber = idx =>
    ascBlockNumberKeys
    ->Belt.Array.get(idx - 1)
    ->Option.map(key => {
      (verifiedDataByBlockNumber->Js.Dict.unsafeGet(key)).blockNumber
    })

  let rec loop = idx => {
    switch ascBlockNumberKeys->Belt.Array.get(idx) {
    | Some(blockNumberKey) =>
      switch reorgDetection.dataByBlockNumber->Utils.Dict.dangerouslyGetNonOption(blockNumberKey) {
      | Some(scannedBlock)
        if (verifiedDataByBlockNumber->Js.Dict.unsafeGet(blockNumberKey)).blockHash ===
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
  let ascBlockNumberKeys = dataByBlockNumber->Js.Dict.keys

  let newDataByBlockNumber = Js.Dict.empty()

  let rec loop = idx => {
    switch ascBlockNumberKeys->Belt.Array.get(idx) {
    | Some(blockNumberKey) => {
        let scannedBlock = dataByBlockNumber->Js.Dict.unsafeGet(blockNumberKey)
        let shouldKeep = scannedBlock.blockNumber <= blockNumber
        if shouldKeep {
          newDataByBlockNumber->Js.Dict.set(blockNumberKey, scannedBlock)
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

let getThresholdBlockNumbersBelowBlock = (self: t, ~blockNumber: int, ~currentBlockHeight) => {
  let arr = []

  // Js engine automatically orders numeric object keys
  let ascBlockNumberKeys = self.dataByBlockNumber->Js.Dict.keys
  let thresholdBlockNumber = currentBlockHeight - self.maxReorgDepth

  for idx in 0 to ascBlockNumberKeys->Array.length - 1 {
    let blockNumberKey = ascBlockNumberKeys->Js.Array2.unsafe_get(idx)
    let scannedBlock = self.dataByBlockNumber->Js.Dict.unsafeGet(blockNumberKey)
    let isInReorgThreshold = scannedBlock.blockNumber >= thresholdBlockNumber
    if isInReorgThreshold && scannedBlock.blockNumber < blockNumber {
      arr->Array.push(scannedBlock.blockNumber)
    }
  }
  arr
}

let getHashByBlockNumber = (reorgDetection: t, ~blockNumber) => {
  switch reorgDetection.dataByBlockNumber->Utils.Dict.dangerouslyGetByIntNonOption(blockNumber) {
  | Some(v) => Js.Null.Value(v.blockHash)
  | None => Js.Null.Null
  }
}
