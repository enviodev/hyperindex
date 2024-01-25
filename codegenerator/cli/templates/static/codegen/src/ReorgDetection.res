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

let getParentHashStub = (page: HyperSync.hyperSyncPage<'item>) => {
  let _ = page
  let blockHash = "0x1234"
  Some(blockHash)
}

module LastBlockScannedHashes: {
  type t
  /**Instantiat t with existing data*/
  let makeWithData: (array<lastBlockScannedData>, ~confirmedBlockThreshold: int) => t

  /**Instantiat empty t with no block data*/
  let empty: (~confirmedBlockThreshold: int) => t

  /**Add the latest scanned block data to t*/
  let addLatestLastBlockData: (t, ~lastBlockScannedData: lastBlockScannedData) => t

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

  /**
  Return a BlockNumbersAndHashes.t rolled back to where hashes
  match the provided blockNumberAndHashes
  */
  let rollBackToValidHash: (
    t,
    ~blockNumbersAndHashes: array<HyperSync.blockNumberAndHash>,
  ) => result<t, exn>

  /**
  A record that holds the current height of a chain and the lastBlockScannedHashes,
  used for passing into getEarliestMultiChainTimestampInThreshold where these values 
  need to be zipped
  */
  type currentHeightAndLastBlockHashes = {
    currentHeight: int,
    lastBlockScannedHashes: t,
  }

  /**
  Finds the earliest timestamp that is withtin the confirmedBlockThreshold of
  each chain in a multi chain indexer. Returns None if its a single chain or if
  the list is empty
  */
  let getEarliestMultiChainTimestampInThreshold: array<currentHeightAndLastBlockHashes> => option<
    int,
  >

  let getAllBlockNumbers: t => Belt.Array.t<int>
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
    ~lastBlockScannedData,
  ) =>
    lastBlockDataList
    ->Belt.List.add(lastBlockScannedData)
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

  /**
  Return a BlockNumbersAndHashes.t rolled back to where hashes
  match the provided blockNumberAndHashes
  */
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

  let min = (arrInt: array<int>) => {
    arrInt->Belt.Array.reduce(None, (current, val) => {
      switch current {
      | None => Some(val)
      | Some(current) => Js.Math.min_int(current, val)->Some
      }
    })
  }

  type currentHeightAndLastBlockHashes = {
    currentHeight: int,
    lastBlockScannedHashes: t,
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

  let getAllBlockNumbers = (self: t) =>
    self.lastBlockDataList->Belt.List.reduceReverse([], (acc, v) => {
      Belt.Array.concat(acc, [v.blockNumber])
    })
}
