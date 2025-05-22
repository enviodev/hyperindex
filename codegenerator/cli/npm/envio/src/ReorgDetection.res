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
  lastBlockScannedData: blockData,
  firstBlockParentNumberAndHash: option<blockData>,
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
    ~lastScannedReorgDetectedBlock: blockData=?,
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
    lastScannedReorgDetectedBlock: option<blockData>,
  }

  let makeWithData = (blocks, ~confirmedBlockThreshold, ~lastScannedReorgDetectedBlock=?) => {
    let dataByBlockNumber = Js.Dict.empty()

    blocks->Belt.Array.forEach(block => {
      dataByBlockNumber->Js.Dict.set(block.blockNumber->Js.Int.toString, block)
    })

    {
      confirmedBlockThreshold,
      dataByBlockNumber,
      lastScannedReorgDetectedBlock,
    }
  }
  //Instantiates empty LastBlockHashes
  let empty = (~confirmedBlockThreshold) => {
    confirmedBlockThreshold,
    dataByBlockNumber: Js.Dict.empty(),
    lastScannedReorgDetectedBlock: None,
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

    let {lastBlockScannedData, firstBlockParentNumberAndHash} = reorgGuard

    let maybeReorgDetected = switch dataByBlockNumberCopyInThreshold->Utils.Dict.dangerouslyGetNonOption(
      lastBlockScannedData.blockNumber->Int.toString,
    ) {
    | Some(scannedBlock) if scannedBlock.blockHash !== lastBlockScannedData.blockHash =>
      Some({
        receivedBlock: lastBlockScannedData,
        scannedBlock,
      })
    | _ =>
      switch firstBlockParentNumberAndHash {
      //If parentHash is None, then it's the genesis block (no reorg)
      //Need to check that parentHash matches because of the dynamic contracts
      | None => None
      | Some(firstBlockParentNumberAndHash) =>
        switch dataByBlockNumberCopyInThreshold->Utils.Dict.dangerouslyGetNonOption(
          firstBlockParentNumberAndHash.blockNumber->Int.toString,
        ) {
        | Some(scannedBlock)
          if scannedBlock.blockHash !== firstBlockParentNumberAndHash.blockHash =>
          Some({
            receivedBlock: firstBlockParentNumberAndHash,
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
              lastScannedReorgDetectedBlock: Some(reorgDetected.scannedBlock),
            }
          : empty(~confirmedBlockThreshold),
        ReorgDetected(reorgDetected),
      )
    | None => {
        dataByBlockNumberCopyInThreshold->Js.Dict.set(
          lastBlockScannedData.blockNumber->Int.toString,
          lastBlockScannedData,
        )
        switch firstBlockParentNumberAndHash {
        | None => ()
        | Some(firstBlockParentNumberAndHash) =>
          dataByBlockNumberCopyInThreshold->Js.Dict.set(
            firstBlockParentNumberAndHash.blockNumber->Int.toString,
            firstBlockParentNumberAndHash,
          )
        }

        (
          {
            confirmedBlockThreshold,
            dataByBlockNumber: dataByBlockNumberCopyInThreshold,
            lastScannedReorgDetectedBlock: None,
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
  ) => {
    let verifiedDataByBlockNumber = Js.Dict.empty()
    for idx in 0 to blockNumbersAndHashes->Array.length - 1 {
      let blockData = blockNumbersAndHashes->Array.getUnsafe(idx)
      verifiedDataByBlockNumber->Js.Dict.set(blockData.blockNumber->Int.toString, blockData)
    }

    let isAlreadyReorgedResponse = switch self.lastScannedReorgDetectedBlock {
    | Some(lastScannedReorgDetectedBlock) =>
      switch verifiedDataByBlockNumber->Utils.Dict.dangerouslyGetNonOption(
        lastScannedReorgDetectedBlock.blockNumber->Int.toString,
      ) {
      | Some(verifiedBlockData) =>
        verifiedBlockData.blockHash === lastScannedReorgDetectedBlock.blockHash
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
      lastScannedReorgDetectedBlock: None,
    }
  }

  let getThresholdBlockNumbers = (self: t, ~currentBlockHeight) => {
    let dataByBlockNumberCopyInThreshold =
      self->getDataByBlockNumberCopyInThreshold(~currentBlockHeight)

    dataByBlockNumberCopyInThreshold->Js.Dict.values->Js.Array2.map(v => v.blockNumber)
  }
}
