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

module LastBlockScannedHashes: {
  type t
  /**Instantiat t with existing data*/
  let makeWithData: (array<blockData>, ~confirmedBlockThreshold: int) => t

  /**Instantiat empty t with no block data*/
  let empty: (~confirmedBlockThreshold: int) => t

  /**Add the latest scanned block data to t*/
  let addLatestLastBlockData: (t, ~lastBlockScannedData: blockData) => t

  /**Read the latest last block scanned data at the from the front of the queue*/
  let getLatestLastBlockData: t => option<blockData>
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
  let rollBackToValidHash: (t, ~blockNumbersAndHashes: array<blockData>) => result<t, exn>

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

  let getThresholdBlockNumbers: (t, ~currentBlockHeight: int) => array<int>

  let hasReorgOccurred: (t, ~reorgGuard: reorgGuard) => bool

  /**
  Return a BlockNumbersAndHashes.t rolled back to where blockData is less
  than the provided blockNumber
  */
  let rollBackToBlockNumberLt: (~blockNumber: int, t) => t
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
    lastBlockScannedDataList: list<blockData>,
  }

  //Instantiates LastBlockHashes.t
  let makeWithDataInternal = (lastBlockScannedDataList, ~confirmedBlockThreshold) => {
    confirmedBlockThreshold,
    lastBlockScannedDataList,
  }

  let makeWithData = (lastBlockScannedDataListArr, ~confirmedBlockThreshold) =>
    lastBlockScannedDataListArr
    ->Belt.List.fromArray
    ->Belt.List.reverse
    ->makeWithDataInternal(~confirmedBlockThreshold)
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
    reversedLastBlockDataList: list<blockData>,
  ): option<int> => {
    switch reversedLastBlockDataList {
    | list{lastBlockScannedData, ...tail} =>
      // If the blocknumber is not in the threshold recurse with given blockdata's
      // timestamp , incrementing the from index
      if lastBlockScannedData.blockNumber >= currentHeight - confirmedBlockThreshold {
        // If it's in the threshold return the last earliest timestamp
        Some(lastBlockScannedData.blockTimestamp)
      } else {
        tail->getEarlistTimestampInThresholdInternal(~currentHeight, ~confirmedBlockThreshold)
      }
    | list{} => None
    }
  }

  let getEarlistTimestampInThreshold = (
    ~currentHeight,
    {lastBlockScannedDataList, confirmedBlockThreshold}: t,
  ) =>
    lastBlockScannedDataList
    ->Belt.List.reverse
    ->getEarlistTimestampInThresholdInternal(~currentHeight, ~confirmedBlockThreshold)

  /**
  Inserts last scanned blockData in its positional order of blockNumber. Adds would usually
  be always appending to the head with a new last scanned blockData but could be earlier in the
  case of a dynamic contract.
  */
  let rec addLatestLastBlockDataInternal = (
    ~lastBlockScannedData,
    //Default empty, accumRev would be each item part of lastBlockScannedDataList that has
    //a higher blockNumber than lastBlockScannedData
    ~accumRev=list{},
    lastBlockScannedDataList,
  ) => {
    switch lastBlockScannedDataList {
    | list{head, ...tail} =>
      if head.blockNumber <= lastBlockScannedData.blockNumber {
        Belt.List.reverseConcat(accumRev, list{lastBlockScannedData, ...lastBlockScannedDataList})
      } else {
        tail->addLatestLastBlockDataInternal(
          ~lastBlockScannedData,
          ~accumRev=list{head, ...accumRev},
        )
      }
    | list{} => Belt.List.reverseConcat(accumRev, list{lastBlockScannedData})
    }
  }

  // Adds the latest blockData to the head of the list
  let addLatestLastBlockData = (
    {confirmedBlockThreshold, lastBlockScannedDataList}: t,
    ~lastBlockScannedData,
  ) =>
    lastBlockScannedDataList
    ->addLatestLastBlockDataInternal(~lastBlockScannedData)
    ->makeWithDataInternal(~confirmedBlockThreshold)

  let getLatestLastBlockData = (self: t) => self.lastBlockScannedDataList->Belt.List.head

  let blockDataIsPastThreshold = (
    lastBlockScannedData: blockData,
    ~currentHeight: int,
    ~confirmedBlockThreshold: int,
  ) => lastBlockScannedData.blockNumber < currentHeight - confirmedBlockThreshold

  type rec trampoline<'a> = Data('a) | Callback(unit => trampoline<'a>)

  /**
    Trampolines are a method of handling mutual recursions without the risk of hitting stack limits

    Tail Call Optimization is not possible on mutually recursive functions and so this is a manual optizimation

    (note: this implementation of "trampoline" uses a tail call and so TCO tranfsorms it to a while loop in JS)
  */
  let rec trampoline = value =>
    switch value {
    | Data(v) => v
    | Callback(fn) => fn()->trampoline
    }

  //Prunes the back of the unneeded data on the queue
  let rec pruneStaleBlockDataInternal = (
    ~currentHeight,
    ~earliestMultiChainTimestampInThreshold,
    ~confirmedBlockThreshold,
    lastBlockScannedDataListReversed: list<blockData>,
  ) => {
    switch earliestMultiChainTimestampInThreshold {
    // If there is no "earlist multichain timestamp in threshold"
    // simply prune the earliest block in the case that the block is
    // outside of the confirmedBlockThreshold
    | None =>
      Callback(
        () =>
          lastBlockScannedDataListReversed->pruneEarliestBlockData(
            ~currentHeight,
            ~earliestMultiChainTimestampInThreshold,
            ~confirmedBlockThreshold,
          ),
      )
    | Some(timestampThresholdNeeded) =>
      switch lastBlockScannedDataListReversed {
      | list{_head, second, ..._tail} =>
        // Ony prune in the case where the second lastBlockScannedData from the back
        // Has an earlier timestamp than the timestampThresholdNeeded (this is
        // the earliest timestamp across all chains where the lastBlockScannedData is
        // still within the confirmedBlockThreshold)
        if second.blockTimestamp < timestampThresholdNeeded {
          Callback(
            () =>
              lastBlockScannedDataListReversed->pruneEarliestBlockData(
                ~currentHeight,
                ~earliestMultiChainTimestampInThreshold,
                ~confirmedBlockThreshold,
              ),
          )
        } else {
          Data(lastBlockScannedDataListReversed)
        }
      | list{_} | list{} => Data(lastBlockScannedDataListReversed)
      }
    }
  }
  and pruneEarliestBlockData = (
    lastBlockScannedDataListReversed: list<blockData>,
    ~currentHeight,
    ~earliestMultiChainTimestampInThreshold,
    ~confirmedBlockThreshold,
  ) => {
    switch lastBlockScannedDataListReversed {
    | list{earliestLastBlockData, ...tail} =>
      // In the case that back is past the threshold, remove it and
      // recurse
      if earliestLastBlockData->blockDataIsPastThreshold(~currentHeight, ~confirmedBlockThreshold) {
        // Recurse to check the next item
        Callback(
          () =>
            tail->pruneStaleBlockDataInternal(
              ~currentHeight,
              ~earliestMultiChainTimestampInThreshold,
              ~confirmedBlockThreshold,
            ),
        )
      } else {
        Data(lastBlockScannedDataListReversed)
      }
    | list{} => Data(list{})
    }
  }

  //Prunes the back of the unneeded data on the queue
  let pruneStaleBlockData = (
    ~currentHeight,
    ~earliestMultiChainTimestampInThreshold=?,
    {confirmedBlockThreshold, lastBlockScannedDataList}: t,
  ) => {
    trampoline(
      lastBlockScannedDataList
      ->Belt.List.reverse
      ->pruneStaleBlockDataInternal(
        ~confirmedBlockThreshold,
        ~currentHeight,
        ~earliestMultiChainTimestampInThreshold,
      ),
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
    latestBlockScannedData: list<blockData>,
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
  let rollBackToValidHash = (self: t, ~blockNumbersAndHashes: array<blockData>) => {
    let {confirmedBlockThreshold, lastBlockScannedDataList} = self
    let latestBlockHashes =
      blockNumbersAndHashes
      ->Belt.Array.map(({blockNumber, blockHash}) => (blockNumber, blockHash))
      ->Belt.Map.Int.fromArray

    lastBlockScannedDataList
    ->rollBackToValidHashInternal(~latestBlockHashes)
    ->Belt.Result.map(list => list->makeWithDataInternal(~confirmedBlockThreshold))
  }

  let min = (arrInt: array<int>) => {
    arrInt->Belt.Array.reduce(None, (current, val) => {
      switch current {
      | None => Some(val)
      | Some(current) => Js.Math.min_int(current, val)->Some
      }
    })
  }

  let rec rollBackToBlockNumberLtInternal = (
    ~blockNumber: int,
    latestBlockScannedData: list<blockData>,
  ) => {
    switch latestBlockScannedData {
    | list{} => list{}
    | list{head, ...tail} =>
      if head.blockNumber < blockNumber {
        latestBlockScannedData
      } else {
        tail->rollBackToBlockNumberLtInternal(~blockNumber)
      }
    }
  }

  /**
  Return a BlockNumbersAndHashes.t rolled back to where blockData is less
  than the provided blockNumber
  */
  let rollBackToBlockNumberLt = (~blockNumber: int, self: t) => {
    let {confirmedBlockThreshold, lastBlockScannedDataList} = self
    lastBlockScannedDataList
    ->rollBackToBlockNumberLtInternal(~blockNumber)
    ->makeWithDataInternal(~confirmedBlockThreshold)
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

  let getThresholdBlockNumbers = (self: t, ~currentBlockHeight) => {
    let blockNumbers = []
    self.lastBlockScannedDataList->Belt.List.reduceReverseU((), ((), v) => {
      if v.blockNumber >= currentBlockHeight - self.confirmedBlockThreshold {
        blockNumbers->Belt.Array.push(v.blockNumber)
      }
    })
    blockNumbers
  }

  /**
  Checks whether reorg has occured by comparing the parent hash with the last saved block hash.
  */
  let rec hasReorgOccurredInternal = (lastBlockScannedDataList, ~reorgGuard: reorgGuard) => {
    switch lastBlockScannedDataList {
    | list{head, ...tail} =>
      switch reorgGuard {
      | {lastBlockScannedData} if lastBlockScannedData.blockNumber == head.blockNumber =>
        lastBlockScannedData.blockHash != head.blockHash
      //If parentHash is None, either it's the genesis block (no reorg)
      //Or its already confirmed so no Reorg
      | {firstBlockParentNumberAndHash: None} => false
      | {
          firstBlockParentNumberAndHash: Some({
            blockHash: parentHash,
            blockNumber: parentBlockNumber,
          }),
        } =>
        if parentBlockNumber == head.blockNumber {
          parentHash != head.blockHash
        } else {
          //if block numbers do not match, this is a dynamic contract case and should recurse
          //through the list to look for a matching block or nothing to validate
          tail->hasReorgOccurredInternal(~reorgGuard)
        }
      }
    //If recentLastBlockData is None, we have not yet saved blockData to compare against
    | _ => false
    }
  }

  let hasReorgOccurred = (lastBlockScannedHashes: t, ~reorgGuard: reorgGuard) =>
    lastBlockScannedHashes.lastBlockScannedDataList->hasReorgOccurredInternal(~reorgGuard)
}
