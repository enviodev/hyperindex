type lastBlockScannedData = {
  //Block hash is used for actual comparison to test for reorg
  blockHash: string,
  blockNumber: int,
  //Timestamp is needed for multichain to action reorgs across chains from given blocks to
  //ensure ordering is kept constant
  blockTimestamp: int,
}

let getLastBlockScannedDataStub = (page: HyperSync.hyperSyncPage<'item>) => {
  let _ = page

  {
    blockNumber: 0,
    blockTimestamp: 0,
    blockHash: "0x1234",
  }
}

module LastBlockScannedHashes: {
  type t

  /**Instantiat t with existing data*/
  let makeWithData: (array<lastBlockScannedData>, ~confirmedBlockThreshold: int) => t

  /**Instantiat empty t with no block data*/
  let empty: (~confirmedBlockThreshold: int) => t

  /**Add the latest scanned block data to t*/
  let addLatestLastBlockData: (
    t,
    ~blockNumber: int,
    ~blockHash: string,
    ~blockTimestamp: int,
  ) => unit

  /**Read the latest last block scanned data at the from the front of the queue*/
  let getLatestLastBlockData: t => option<lastBlockScannedData>
  /** Given the head block number, find the earliest timestamp from the data where the data
      is still within the given block threshold from the head
  */
  let getEarlistTimestampInThreshold: (~currentHeight: int, t) => option<int>

  /**Prunes the back of the unneeded data on the queue*/
  let pruneStaleBlockData: (
    t,
    ~currentHeight: int,
    ~earliestMultiChainTimestampInThreshold: option<int>,
  ) => unit
} = {
  type t = {
    // Number of blocks behind head, we want to keep track
    // as a threshold for reorgs. If for eg. this is 200,
    // it means we are accounting for reorgs up to 200 blocks
    // behind the head
    confirmedBlockThreshold: int,
    // A cached list of recent blockdata to make comparison checks
    // for reorgs. Used like a DeQueue, but should be quite short data set
    // so using built in array for data structure.
    lastBlockDataQueue: array<lastBlockScannedData>,
  }

  //Instantiates LastBlockHashes.t
  let makeWithData = (lastBlockDataQueue, ~confirmedBlockThreshold) => {
    confirmedBlockThreshold,
    lastBlockDataQueue,
  }
  //Instantiates empty LastBlockHashes
  let empty = (~confirmedBlockThreshold) => makeWithData([], ~confirmedBlockThreshold)

  let getBack = (self: t) => self.lastBlockDataQueue->Belt.Array.get(0)
  let getSecondFromBack = (self: t) => self.lastBlockDataQueue->Belt.Array.get(1)
  let popBack = (self: t) => self.lastBlockDataQueue->Js.Array2.shift
  let getFront = (self: t) =>
    self.lastBlockDataQueue->Belt.Array.get(Array.length(self.lastBlockDataQueue) - 1)
  let pushFront = (self: t, blockData) => self.lastBlockDataQueue->Js.Array2.push(blockData)

  /** Given the head block number, find the earliest timestamp from the data where the data
      is still within the given block threshold from the head
  */
  let rec getEarlistTimestampInThresholdInternal = (
    // Always, starts from 0, optional parameter should not be applied where called
    ~fromIndex=0,
    // Always, starts with None, optional param should not be applied where called
    ~lastEarlistTimestamp=None,
    // The current block number at the head of the chain
    ~currentHeight,
    self: t,
  ): option<int> => {
    switch self.lastBlockDataQueue->Belt.Array.get(fromIndex) {
    | Some(lastBlockData) =>
      // If the blocknumber is in the threshold recurse with given blockdata's
      // timestamp , incrementing the from index
      if lastBlockData.blockNumber < currentHeight - self.confirmedBlockThreshold {
        self->getEarlistTimestampInThresholdInternal(
          ~fromIndex=fromIndex + 1,
          ~lastEarlistTimestamp=Some(lastBlockData.blockTimestamp),
          ~currentHeight,
        )
      } else {
        // If it's not in the threshold return the last earliest timestamp
        lastEarlistTimestamp
      }
    | None => lastEarlistTimestamp
    }
  }

  let getEarlistTimestampInThreshold = getEarlistTimestampInThresholdInternal(
    ~fromIndex=0,
    ~lastEarlistTimestamp=None,
  )

  // Adds the latest blockData to the end of the array
  let addLatestLastBlockData = (self: t, ~blockNumber, ~blockHash, ~blockTimestamp) =>
    self->pushFront({blockNumber, blockHash, blockTimestamp})->ignore

  let getLatestLastBlockData = getFront

  let blockDataIsPastThreshold = (
    blockData: lastBlockScannedData,
    ~currentHeight: int,
    ~confirmedBlockThreshold: int,
  ) => blockData.blockNumber < currentHeight - confirmedBlockThreshold

  //Prunes the back of the unneeded data on the queue
  let rec pruneStaleBlockData = (
    self: t,
    ~currentHeight,
    ~earliestMultiChainTimestampInThreshold: option<int>,
  ) => {
    switch earliestMultiChainTimestampInThreshold {
    // If there is no "earlist multichain timestamp in threshold"
    // simply prune the earliest block in the case that the block is
    // outside of the confirmedBlockThreshold
    | None => self->pruneEarliestBlockData(~currentHeight, ~earliestMultiChainTimestampInThreshold)
    | Some(timestampThresholdNeeded) =>
      self
      ->getSecondFromBack
      ->Belt.Option.map(secondFromBack => {
        // Ony prune in the case where the second lastBlockData from the back
        // Has an earlier timestamp than the timestampThresholdNeeded (this is
        // the earliest timestamp across all chains where the lastBlockData is
        // still within the confirmedBlockThreshold)
        if secondFromBack.blockTimestamp < timestampThresholdNeeded {
          self->pruneEarliestBlockData(~currentHeight, ~earliestMultiChainTimestampInThreshold)
        }
      })
      ->ignore
    }
  }
  and pruneEarliestBlockData = (self: t, ~currentHeight, ~earliestMultiChainTimestampInThreshold) =>
    self
    ->getBack
    ->Belt.Option.map(earliestLastBlockData => {
      // In the case that back is past the threshold, remove it and
      // recurse
      if (
        earliestLastBlockData->blockDataIsPastThreshold(
          ~currentHeight,
          ~confirmedBlockThreshold=self.confirmedBlockThreshold,
        )
      ) {
        // Data at the back is stale, pop it off
        self->popBack->ignore
        // Recurse to check the next item
        self->pruneStaleBlockData(~currentHeight, ~earliestMultiChainTimestampInThreshold)
      }
    })
    ->ignore
}
