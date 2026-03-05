open Belt

let make = (~items: array<Internal.item>, ~endBlock: int, ~chain: ChainMap.Chain.t): Source.t => {
  name: "SimulateSource",
  sourceFor: Sync,
  chain,
  poweredByHyperSync: false,
  pollingInterval: 0,
  getBlockHashes: (~blockNumbers as _, ~logger as _) => {
    Promise.resolve(Ok([]))
  },
  getHeightOrThrow: () => {
    Promise.resolve(endBlock)
  },
  getItemsOrThrow: (
    ~fromBlock,
    ~toBlock as _,
    ~addressesByContractName as _,
    ~indexingContracts as _,
    ~knownHeight as _,
    ~partitionId as _,
    ~selection as _,
    ~retry as _,
    ~logger as _,
  ) => {
    let filteredItems = []
    for i in 0 to items->Array.length - 1 {
      let item = items->Js.Array2.unsafe_get(i)
      let blockNumber = item->Internal.getItemBlockNumber
      if blockNumber >= fromBlock && blockNumber <= endBlock {
        filteredItems->Array.push(item)->ignore
      }
    }

    let latestFetchedBlockNumber = endBlock
    Promise.resolve({
      Source.knownHeight: endBlock,
      reorgGuard: {
        rangeLastBlock: {
          blockHash: "0x0000000000000000000000000000000000000000000000000000000000000000",
          blockNumber: latestFetchedBlockNumber,
        },
        prevRangeLastBlock: None,
      },
      parsedQueueItems: filteredItems,
      fromBlockQueried: fromBlock,
      latestFetchedBlockNumber,
      latestFetchedBlockTimestamp: 0,
      stats: {
        totalTimeElapsed: 0,
      },
    })
  },
}
