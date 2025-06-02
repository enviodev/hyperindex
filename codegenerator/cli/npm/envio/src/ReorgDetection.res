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
type validBlockError = NotFound | AlreadyReorgedHashes
type validBlockResult = result<blockDataWithTimestamp, validBlockError>

module LastBlockScannedHashes: {
  type t
  /**Instantiat t with existing data*/
  let makeWithData: (
    array<blockData>,
    ~confirmedBlockThreshold: int,
    ~detectedReorgBlock: blockData=?,
  ) => t

  /**Instantiat empty t with no block data*/
  let empty: (~confirmedBlockThreshold: int) => t

  /** Registers a new reorg guard, prunes unneeded data, and returns the updated state.
   * Resets internal state if shouldRollbackOnReorg is false (detect-only mode)
   */
  let registerReorgGuard: (
    t,
    ~reorgGuard: reorgGuard,
    ~currentBlockHeight: int,
    ~shouldRollbackOnReorg: bool,
  ) => (t, reorgResult)

  /**
  Returns the latest block data which matches block number and hashes in the provided array
  If it doesn't exist in the reorg threshold it returns None or the latest scanned block outside of the reorg threshold
  */
  let getLatestValidScannedBlock: (
    t,
    ~blockNumbersAndHashes: array<blockDataWithTimestamp>,
    ~currentBlockHeight: int,
    ~skipReorgDuplicationCheck: bool=?,
  ) => validBlockResult

  let getThresholdBlockNumbers: (t, ~currentBlockHeight: int) => array<int>

  let rollbackToValidBlockNumber: (t, ~blockNumber: int) => t
} = {
  type t = {
    // Number of blocks behind head, we want to keep track
    // as a threshold for reorgs. If for eg. this is 200,
    // it means we are accounting for reorgs up to 200 blocks
    // behind the head
    confirmedBlockThreshold: int,
    // A hash map of recent blockdata by block number to make comparison checks
    // for reorgs.
    dataByBlockNumber: dict<blockData>,
    // The latest block which detected a reorg
    // and should never be valid.
    // We keep track of this to avoid responses
    // with the stale data from other data-source instances.
    detectedReorgBlock: option<blockData>,
  }

  let makeWithData = (blocks, ~confirmedBlockThreshold, ~detectedReorgBlock=?) => {
    let dataByBlockNumber = Js.Dict.empty()

    blocks->Belt.Array.forEach(block => {
      dataByBlockNumber->Js.Dict.set(block.blockNumber->Js.Int.toString, block)
    })

    {
      confirmedBlockThreshold,
      dataByBlockNumber,
      detectedReorgBlock,
    }
  }
  //Instantiates empty LastBlockHashes
  let empty = (~confirmedBlockThreshold) => {
    confirmedBlockThreshold,
    dataByBlockNumber: Js.Dict.empty(),
    detectedReorgBlock: None,
  }

  let getDataByBlockNumberCopyInThreshold = (
    {dataByBlockNumber, confirmedBlockThreshold}: t,
    ~currentBlockHeight,
  ) => {
    // Js engine automatically orders numeric object keys
    let ascBlockNumberKeys = dataByBlockNumber->Js.Dict.keys
    let thresholdBlockNumber = currentBlockHeight - confirmedBlockThreshold

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

  let registerReorgGuard = (
    {confirmedBlockThreshold} as self: t,
    ~reorgGuard: reorgGuard,
    ~currentBlockHeight,
    ~shouldRollbackOnReorg,
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
          ? {
              ...self,
              detectedReorgBlock: Some(reorgDetected.scannedBlock),
            }
          : empty(~confirmedBlockThreshold),
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
            confirmedBlockThreshold,
            dataByBlockNumber: dataByBlockNumberCopyInThreshold,
            detectedReorgBlock: None,
          },
          NoReorg,
        )
      }
    }
  }

  let getLatestValidScannedBlock = (
    self: t,
    ~blockNumbersAndHashes: array<blockDataWithTimestamp>,
    ~currentBlockHeight,
    ~skipReorgDuplicationCheck=false,
  ) => {
    let verifiedDataByBlockNumber = Js.Dict.empty()
    for idx in 0 to blockNumbersAndHashes->Array.length - 1 {
      let blockData = blockNumbersAndHashes->Array.getUnsafe(idx)
      verifiedDataByBlockNumber->Js.Dict.set(blockData.blockNumber->Int.toString, blockData)
    }

    /*
     Let's say we indexed block X with hash A.
     The next query we got the block X with hash B.
     We assume that the hash A is reorged since we received it earlier than B.
     So when we try to detect the reorg depth, we consider hash A as already invalid,
     and retry the block hashes query if we receive one. (since it could come from a different instance and cause a double reorg)
     But the assumption that A is reorged might be wrong sometimes,
     for example if we got B from instance which didn't handle a reorg A.
     Theoretically, it's possible with high partition concurrency.
     So to handle this and prevent entering an infinite loop,
     we can skip the reorg duplication check if we're sure that the block hashes query
     is not coming from a different instance. (let's say we tried several times)
 */
    let isAlreadyReorgedResponse = skipReorgDuplicationCheck
      ? false
      : switch self.detectedReorgBlock {
        | Some(detectedReorgBlock) =>
          switch verifiedDataByBlockNumber->Utils.Dict.dangerouslyGetNonOption(
            detectedReorgBlock.blockNumber->Int.toString,
          ) {
          | Some(verifiedBlockData) => verifiedBlockData.blockHash === detectedReorgBlock.blockHash
          | None => false
          }
        | None => false
        }

    if isAlreadyReorgedResponse {
      Error(AlreadyReorgedHashes)
    } else {
      let dataByBlockNumber = self->getDataByBlockNumberCopyInThreshold(~currentBlockHeight)
      // Js engine automatically orders numeric object keys
      let ascBlockNumberKeys = dataByBlockNumber->Js.Dict.keys

      let getPrevScannedBlock = idx =>
        switch ascBlockNumberKeys
        ->Belt.Array.get(idx - 1)
        ->Option.flatMap(key => {
          // We should already validate that the block number is verified at the point
          verifiedDataByBlockNumber->Utils.Dict.dangerouslyGetNonOption(key)
        }) {
        | Some(data) => Ok(data)
        | None => Error(NotFound)
        }

      let rec loop = idx => {
        switch ascBlockNumberKeys->Belt.Array.get(idx) {
        | Some(blockNumberKey) =>
          let scannedBlock = dataByBlockNumber->Js.Dict.unsafeGet(blockNumberKey)
          switch verifiedDataByBlockNumber->Utils.Dict.dangerouslyGetNonOption(blockNumberKey) {
          | None =>
            Js.Exn.raiseError(
              `Unexpected case. Couldn't find verified hash for block number ${blockNumberKey}`,
            )
          | Some(verifiedBlockData) if verifiedBlockData.blockHash === scannedBlock.blockHash =>
            loop(idx + 1)
          | Some(_) => getPrevScannedBlock(idx)
          }
        | None => getPrevScannedBlock(idx)
        }
      }
      loop(0)
    }
  }

  /**
  Return a BlockNumbersAndHashes.t rolled back to where blockData is less
  than the provided blockNumber
  */
  let rollbackToValidBlockNumber = (
    {dataByBlockNumber, confirmedBlockThreshold}: t,
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
      confirmedBlockThreshold,
      dataByBlockNumber: newDataByBlockNumber,
      detectedReorgBlock: None,
    }
  }

  let getThresholdBlockNumbers = (self: t, ~currentBlockHeight) => {
    let dataByBlockNumberCopyInThreshold =
      self->getDataByBlockNumberCopyInThreshold(~currentBlockHeight)

    dataByBlockNumberCopyInThreshold->Js.Dict.values->Js.Array2.map(v => v.blockNumber)
  }
}
