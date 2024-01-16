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
  let addLatestLastBlockData: (t, ~blockNumber: int, ~blockHash: string, ~blockTimestamp: int) => t

  /**Read the latest last block scanned data at the from the front of the queue*/
  let getLatestLastBlockData: t => option<lastBlockScannedData>
  /** Given the head block number, find the earliest timestamp from the data where the data
      is still within the given block threshold from the head
  */
  let getEarlistTimestampInThreshold: (~currentHeight: int, t) => option<int>

  /**
  Prunes the back of the unneeded data on the queue.

  In the case of a multichain indexer, pass in the earliest needed timestamp that
  occurs within the chains threshold. Ensure that we keep track of one range before that
  as this is that could be the target range block for a reorg
  */
  let pruneStaleBlockData: (
    ~currentHeight: int,
    ~earliestMultiChainTimestampInThreshold: int=?,
    t,
  ) => t

  let rollBackToValidHash: (
    t,
    ~blockNumbersAndHashes: array<HyperSync.blockNumberAndHash>,
  ) => result<t, exn>
} = {
  type t = {
    // Number of blocks behind head, we want to keep track
    // as a threshold for reorgs. If for eg. this is 200,
    // it means we are accounting for reorgs up to 200 blocks
    // behind the head
    confirmedBlockThreshold: int,
    // A cached list of recent blockdata to make comparison checks
    // for reorgs. Should be quite short data set
    // so using built in array for data structure.
    lastBlockDataList: list<lastBlockScannedData>,
  }

  //Instantiates LastBlockHashes.t
  let makeWithDataInternal = (lastBlockDataList, ~confirmedBlockThreshold) => {
    confirmedBlockThreshold,
    lastBlockDataList,
  }

  let makeWithData = lastBlockDataListArr =>
    lastBlockDataListArr->Belt.List.fromArray->Belt.List.reverse->makeWithDataInternal
  //Instantiates empty LastBlockHashes
  let empty = (~confirmedBlockThreshold) => makeWithDataInternal(list{}, ~confirmedBlockThreshold)

  /** Given the head block number, find the earliest timestamp from the data where the data
      is still within the given block threshold from the head
  */
  let rec getEarlistTimestampInThresholdInternal = (
    // The current block number at the head of the chain
    ~currentHeight,
    ~confirmedBlockThreshold,
    //reversed so that head to tail is earlist to latest
    reversedLastBlockDataList: list<lastBlockScannedData>,
  ): option<int> => {
    switch reversedLastBlockDataList {
    | list{lastBlockData, ...tail} =>
      // If the blocknumber is not in the threshold recurse with given blockdata's
      // timestamp , incrementing the from index
      if lastBlockData.blockNumber >= currentHeight - confirmedBlockThreshold {
        // If it's in the threshold return the last earliest timestamp
        Some(lastBlockData.blockTimestamp)
      } else {
        tail->getEarlistTimestampInThresholdInternal(~currentHeight, ~confirmedBlockThreshold)
      }
    | list{} => None
    }
  }

  let getEarlistTimestampInThreshold = (
    ~currentHeight,
    {lastBlockDataList, confirmedBlockThreshold}: t,
  ) =>
    lastBlockDataList
    ->Belt.List.reverse
    ->getEarlistTimestampInThresholdInternal(~currentHeight, ~confirmedBlockThreshold)

  // Adds the latest blockData to the end of the array
  let addLatestLastBlockData = (
    {confirmedBlockThreshold, lastBlockDataList}: t,
    ~blockNumber,
    ~blockHash,
    ~blockTimestamp,
  ) =>
    lastBlockDataList
    ->Belt.List.add({blockNumber, blockHash, blockTimestamp})
    ->makeWithDataInternal(~confirmedBlockThreshold)

  let getLatestLastBlockData = (self: t) => self.lastBlockDataList->Belt.List.head

  let blockDataIsPastThreshold = (
    blockData: lastBlockScannedData,
    ~currentHeight: int,
    ~confirmedBlockThreshold: int,
  ) => blockData.blockNumber < currentHeight - confirmedBlockThreshold

  //Prunes the back of the unneeded data on the queue
  let rec pruneStaleBlockDataInternal = (
    ~currentHeight,
    ~earliestMultiChainTimestampInThreshold,
    ~confirmedBlockThreshold,
    lastBlockDataListReversed: list<lastBlockScannedData>,
  ) => {
    switch earliestMultiChainTimestampInThreshold {
    // If there is no "earlist multichain timestamp in threshold"
    // simply prune the earliest block in the case that the block is
    // outside of the confirmedBlockThreshold
    | None =>
      lastBlockDataListReversed->pruneEarliestBlockData(
        ~currentHeight,
        ~earliestMultiChainTimestampInThreshold,
        ~confirmedBlockThreshold,
      )
    | Some(timestampThresholdNeeded) =>
      switch lastBlockDataListReversed {
      | list{_head, second, ..._tail} =>
        // Ony prune in the case where the second lastBlockData from the back
        // Has an earlier timestamp than the timestampThresholdNeeded (this is
        // the earliest timestamp across all chains where the lastBlockData is
        // still within the confirmedBlockThreshold)
        if second.blockTimestamp < timestampThresholdNeeded {
          lastBlockDataListReversed->pruneEarliestBlockData(
            ~currentHeight,
            ~earliestMultiChainTimestampInThreshold,
            ~confirmedBlockThreshold,
          )
        } else {
          lastBlockDataListReversed
        }
      | list{_} | list{} => lastBlockDataListReversed
      }
    }
  }
  and pruneEarliestBlockData = (
    ~currentHeight,
    ~earliestMultiChainTimestampInThreshold,
    ~confirmedBlockThreshold,
    lastBlockDataListReversed: list<lastBlockScannedData>,
  ) => {
    switch lastBlockDataListReversed {
    | list{earliestLastBlockData, ...tail} =>
      // In the case that back is past the threshold, remove it and
      // recurse
      if earliestLastBlockData->blockDataIsPastThreshold(~currentHeight, ~confirmedBlockThreshold) {
        // Recurse to check the next item
        tail->pruneStaleBlockDataInternal(
          ~currentHeight,
          ~earliestMultiChainTimestampInThreshold,
          ~confirmedBlockThreshold,
        )
      } else {
        lastBlockDataListReversed
      }
    | list{} => list{}
    }
  }

  //Prunes the back of the unneeded data on the queue
  let pruneStaleBlockData = (
    ~currentHeight,
    ~earliestMultiChainTimestampInThreshold=?,
    {confirmedBlockThreshold, lastBlockDataList}: t,
  ) => {
    lastBlockDataList
    ->Belt.List.reverse
    ->pruneStaleBlockDataInternal(
      ~confirmedBlockThreshold,
      ~currentHeight,
      ~earliestMultiChainTimestampInThreshold,
    )
    ->Belt.List.reverse
    ->makeWithDataInternal(~confirmedBlockThreshold)
  }

  type blockNumberToHashMap = Belt.Map.Int.t<string>
  exception BlockNotIncludedInMap(int)

  let doBlockHashesMatch = (lastBlockScannedData, ~latestBlockHashes: blockNumberToHashMap) => {
    let {blockNumber, blockHash} = lastBlockScannedData
    let matchingBlock = latestBlockHashes->Belt.Map.Int.get(blockNumber)

    switch matchingBlock {
    | None => Error(BlockNotIncludedInMap(blockNumber))
    | Some(latestBlockHash) => Ok(blockHash == latestBlockHash)
    }
  }
  let rec rollBackToValidHashInternal = (
    latestBlockScannedData: list<lastBlockScannedData>,
    ~latestBlockHashes: blockNumberToHashMap,
  ) => {
    switch latestBlockScannedData {
    | list{} => Ok(list{}) //Nothing on the front to rollback to
    | list{lastBlockScannedData, ...tail} =>
      lastBlockScannedData
      ->doBlockHashesMatch(~latestBlockHashes)
      ->Belt.Result.flatMap(blockHashesDoMatch => {
        if blockHashesDoMatch {
          Ok(list{lastBlockScannedData, ...tail})
        } else {
          tail->rollBackToValidHashInternal(~latestBlockHashes)
        }
      })
    }
  }

  let rollBackToValidHash = (
    self: t,
    ~blockNumbersAndHashes: array<HyperSync.blockNumberAndHash>,
  ) => {
    let {confirmedBlockThreshold, lastBlockDataList} = self
    let latestBlockHashes =
      blockNumbersAndHashes
      ->Belt.Array.map(({blockNumber, hash}) => (blockNumber, hash))
      ->Belt.Map.Int.fromArray

    lastBlockDataList
    ->rollBackToValidHashInternal(~latestBlockHashes)
    ->Belt.Result.map(makeWithDataInternal(~confirmedBlockThreshold))
  }
}
