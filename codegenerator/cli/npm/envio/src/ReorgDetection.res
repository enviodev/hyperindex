open Belt

type blockNumberAndHash = {
  //Block hash is used for actual comparison to test for reorg
  blockHash: string,
  blockNumber: int,
}

type blockData = {
  ...blockNumberAndHash,
  //Timestamp is needed for multichain to action reorgs across chains from given blocks to
  //ensure ordering is kept constant
  blockTimestamp: int,
}

type reorgGuard = {
  lastBlockScannedData: blockData,
  firstBlockParentNumberAndHash: option<blockNumberAndHash>,
}

type reorgDetected = {
  scannedBlock: blockData,
  reorgGuard: reorgGuard,
}

module LastBlockScannedHashes: {
  type t
  /**Instantiat t with existing data*/
  let makeWithData: (array<blockData>, ~confirmedBlockThreshold: int) => t

  /**Instantiat empty t with no block data*/
  let empty: (~confirmedBlockThreshold: int) => t

  /**Add the latest scanned block data to t*/
  let registerReorgGuard: (t, ~reorgGuard: reorgGuard) => result<t, reorgDetected>

  /** Given the head block number, find the earliest timestamp from the data where the data
      is still within the given block threshold from the head
  */
  let getEarlistTimestampInThreshold: (t, ~currentHeight: int) => option<int>

  /**
  Prunes the back of the unneeded data on the queue.

  In the case of a multichain indexer, pass in the earliest needed timestamp that
  occurs within the chains threshold. Ensure that we keep track of one range before that
  as this is that could be the target range block for a reorg
  */
  let pruneStaleBlockData: (
    t,
    ~currentHeight: int,
    ~earliestMultiChainTimestampInThreshold: option<int>,
  ) => t

  /**
  Returns the latest block data which matches block number and hashes in the provided array
  If it doesn't exist in the reorg threshold it returns None or the latest scanned block outside of the reorg threshold
  */
  let getLatestValidScannedBlock: (
    t,
    ~blockNumbersAndHashes: array<blockData>,
    ~currentHeight: int,
  ) => option<blockData>

  /**
  A record that holds the current height of a chain and the lastBlockScannedHashes,
  used for passing into getEarliestMultiChainTimestampInThreshold where these values 
  need to be zipped
  */
  type currentHeightAndLastBlockHashes = {
    lastBlockScannedHashes: t,
    currentHeight: int,
  }

  /**
  Finds the earliest timestamp that is withtin the confirmedBlockThreshold of
  each chain in a multi chain indexer. Returns None if its a single chain or if
  the list is empty
  */
  let getEarliestMultiChainTimestampInThreshold: array<currentHeightAndLastBlockHashes> => option<
    int,
  >

  let getThresholdBlockNumbers: (t, ~currentBlockHeight: int) => array<int>

  /**
  Return a BlockNumbersAndHashes.t rolled back to where blockData is less
  than the provided blockNumber
  */
  let rollBackToBlockNumberLt: (t, ~blockNumber: int) => t
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
  }

  let makeWithData = (blocks, ~confirmedBlockThreshold) => {
    let dataByBlockNumber = Js.Dict.empty()

    blocks->Belt.Array.forEach(block => {
      dataByBlockNumber->Js.Dict.set(block.blockNumber->Js.Int.toString, block)
    })

    {
      confirmedBlockThreshold,
      dataByBlockNumber,
    }
  }
  //Instantiates empty LastBlockHashes
  let empty = (~confirmedBlockThreshold) => {
    confirmedBlockThreshold,
    dataByBlockNumber: Js.Dict.empty(),
  }

  let getEarliestBlockDataInThreshold = (
    {dataByBlockNumber, confirmedBlockThreshold}: t,
    ~currentHeight,
  ) => {
    // Js engine automatically orders numeric object keys
    let ascBlockNumberKeys = dataByBlockNumber->Js.Dict.keys
    let thresholdBlockNumber = currentHeight - confirmedBlockThreshold
    let rec loop = idx => {
      switch ascBlockNumberKeys->Belt.Array.get(idx) {
      | Some(blockNumberKey) =>
        let scannedBlock = dataByBlockNumber->Js.Dict.unsafeGet(blockNumberKey)
        if scannedBlock.blockNumber >= thresholdBlockNumber {
          scannedBlock->Some
        } else {
          loop(idx + 1)
        }
      | None => None
      }
    }
    loop(0)
  }

  /** Given the head block number, find the earliest timestamp from the data where the data
      is still within the given block threshold from the head
  */
  let getEarlistTimestampInThreshold = (self: t, ~currentHeight) =>
    self->getEarliestBlockDataInThreshold(~currentHeight)->Option.map(d => d.blockTimestamp)

  // Adds the latest blockData to the head of the list
  let registerReorgGuard = (
    {confirmedBlockThreshold, dataByBlockNumber} as self: t,
    ~reorgGuard: reorgGuard,
  ) => {
    let {lastBlockScannedData, firstBlockParentNumberAndHash} = reorgGuard

    switch dataByBlockNumber->Utils.Dict.dangerouslyGetNonOption(
      lastBlockScannedData.blockNumber->Int.toString,
    ) {
    | Some(scannedBlock) if scannedBlock.blockHash !== lastBlockScannedData.blockHash =>
      Error({
        reorgGuard,
        scannedBlock,
      })
    | _ as maybeScannedData =>
      let updatedSelf = if maybeScannedData === None {
        {
          confirmedBlockThreshold,
          dataByBlockNumber: dataByBlockNumber->Utils.Dict.updateImmutable(
            lastBlockScannedData.blockNumber->Int.toString,
            lastBlockScannedData,
          ),
        }
      } else {
        self
      }

      switch firstBlockParentNumberAndHash {
      //If parentHash is None, either it's the genesis block (no reorg)
      //Or its already confirmed so no Reorg
      | None => Ok(updatedSelf)
      | Some(firstBlockParentNumberAndHash) =>
        switch dataByBlockNumber->Utils.Dict.dangerouslyGetNonOption(
          firstBlockParentNumberAndHash.blockNumber->Int.toString,
        ) {
        | Some(scannedBlock)
          if scannedBlock.blockHash !== firstBlockParentNumberAndHash.blockHash =>
          Error({
            reorgGuard,
            scannedBlock,
          })
        | _ => Ok(updatedSelf)
        }
      }
    }
  }

  //Prunes the back of the unneeded data on the queue
  let pruneStaleBlockData = (
    {confirmedBlockThreshold, dataByBlockNumber}: t,
    ~currentHeight,
    ~earliestMultiChainTimestampInThreshold,
  ) => {
    // Js engine automatically orders numeric object keys
    let ascBlockNumberKeys = dataByBlockNumber->Js.Dict.keys
    let thresholdBlockNumber = currentHeight - confirmedBlockThreshold

    let dataByBlockNumberCopy = dataByBlockNumber->Utils.Dict.shallowCopy

    let rec loop = idx => {
      switch ascBlockNumberKeys->Belt.Array.get(idx) {
      | Some(blockNumberKey) => {
          let scannedBlock = dataByBlockNumber->Js.Dict.unsafeGet(blockNumberKey)
          let isInReorgThreshold = scannedBlock.blockNumber >= thresholdBlockNumber
          let shouldPrune = switch earliestMultiChainTimestampInThreshold {
          | None => !isInReorgThreshold
          | Some(timestampThresholdNeeded) =>
            switch ascBlockNumberKeys
            ->Belt.Array.get(idx + 1)
            ->Option.map(blockNumberKey => dataByBlockNumber->Js.Dict.unsafeGet(blockNumberKey)) {
            // Ony prune in the case where the second lastBlockScannedData from the back
            // Has an earlier timestamp than the timestampThresholdNeeded (this is
            // the earliest timestamp across all chains where the lastBlockScannedData is
            // still within the confirmedBlockThreshold)
            | Some(nextScannedBlock) => nextScannedBlock.blockTimestamp < timestampThresholdNeeded
            | None => false
            }
          }
          if shouldPrune {
            dataByBlockNumberCopy->Utils.Dict.deleteInPlace(blockNumberKey)
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
      dataByBlockNumber: dataByBlockNumberCopy,
    }
  }

  let getLatestValidScannedBlock = (
    {confirmedBlockThreshold, dataByBlockNumber}: t,
    ~blockNumbersAndHashes: array<blockData>,
    ~currentHeight,
  ) => {
    let verifiedDataByBlockNumber = Js.Dict.empty()
    blockNumbersAndHashes->Array.forEach(blockData => {
      verifiedDataByBlockNumber->Js.Dict.set(blockData.blockNumber->Int.toString, blockData)
    })

    // Js engine automatically orders numeric object keys
    let ascBlockNumberKeys = dataByBlockNumber->Js.Dict.keys
    let thresholdBlockNumber = currentHeight - confirmedBlockThreshold

    let getPrevScannedBlock = idx =>
      ascBlockNumberKeys
      ->Belt.Array.get(idx - 1)
      ->Option.flatMap(key => dataByBlockNumber->Utils.Dict.dangerouslyGetNonOption(key))

    let rec loop = idx => {
      switch ascBlockNumberKeys->Belt.Array.get(idx) {
      | Some(blockNumberKey) =>
        let scannedBlock = dataByBlockNumber->Js.Dict.unsafeGet(blockNumberKey)
        let isInReorgThreshold = scannedBlock.blockNumber >= thresholdBlockNumber
        if isInReorgThreshold {
          switch verifiedDataByBlockNumber->Utils.Dict.dangerouslyGetNonOption(blockNumberKey) {
          | None =>
            Js.Exn.raiseError(
              `Unexpected case. Couldn't find verified hash for block number ${blockNumberKey}`,
            )
          | Some(verifiedBlockData) if verifiedBlockData.blockHash === scannedBlock.blockHash =>
            loop(idx + 1)
          | Some(_) => getPrevScannedBlock(idx)
          }
        } else {
          loop(idx + 1)
        }
      | None => getPrevScannedBlock(idx)
      }
    }
    loop(0)
  }

  /**
  Return a BlockNumbersAndHashes.t rolled back to where blockData is less
  than the provided blockNumber
  */
  let rollBackToBlockNumberLt = (
    {dataByBlockNumber, confirmedBlockThreshold}: t,
    ~blockNumber: int,
  ) => {
    // Js engine automatically orders numeric object keys
    let ascBlockNumberKeys = dataByBlockNumber->Js.Dict.keys

    let newDataByBlockNumber = dataByBlockNumber->Utils.Dict.shallowCopy

    let rec loop = idx => {
      switch ascBlockNumberKeys->Belt.Array.get(idx) {
      | Some(blockNumberKey) => {
          let scannedBlock = dataByBlockNumber->Js.Dict.unsafeGet(blockNumberKey)
          let shouldKeep = scannedBlock.blockNumber < blockNumber
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
    }
  }

  type currentHeightAndLastBlockHashes = {
    lastBlockScannedHashes: t,
    currentHeight: int,
  }

  let min = (arrInt: array<int>) => {
    arrInt->Belt.Array.reduce(None, (current, val) => {
      switch current {
      | None => Some(val)
      | Some(current) => Js.Math.min_int(current, val)->Some
      }
    })
  }

  /**
  Find the the earliest block time across multiple instances of self where the block timestamp
  falls within its own confirmed block threshold

  Return None if there is only one chain (since we don't want to take this val into account for a
  single chain indexer) or if there are no chains (should never be the case)
  */
  let getEarliestMultiChainTimestampInThreshold = (
    multiSelf: array<currentHeightAndLastBlockHashes>,
  ) => {
    switch multiSelf {
    | [_singleVal] =>
      //In the case where there is only one chain, return none as there would be no need to aggregate
      //or keep track of the lowest timestamp. The chain can purge as far back as its confirmed block range
      None
    | multiSelf =>
      multiSelf
      ->Belt.Array.keepMap(({currentHeight, lastBlockScannedHashes}) => {
        lastBlockScannedHashes->getEarlistTimestampInThreshold(~currentHeight)
      })
      ->min
    }
  }

  let getThresholdBlockNumbers = (
    {dataByBlockNumber, confirmedBlockThreshold}: t,
    ~currentBlockHeight,
  ) => {
    let blockNumbers = []

    // Js engine automatically orders numeric object keys
    let ascBlockNumberKeys = dataByBlockNumber->Js.Dict.keys
    let thresholdBlockNumber = currentBlockHeight - confirmedBlockThreshold

    let rec loop = idx => {
      switch ascBlockNumberKeys->Belt.Array.get(idx) {
      | Some(blockNumberKey) => {
          let scannedBlock = dataByBlockNumber->Js.Dict.unsafeGet(blockNumberKey)
          if scannedBlock.blockNumber >= thresholdBlockNumber {
            blockNumbers->Array.push(scannedBlock.blockNumber)
          }
          loop(idx + 1)
        }
      | None => ()
      }
    }
    loop(0)

    blockNumbers
  }
}
