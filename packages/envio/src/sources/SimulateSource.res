let make = (~items: array<Internal.item>, ~endBlock: int, ~chain: ChainMap.Chain.t): Source.t => {
  // getItemsOrThrow might be called multiple times with different partition ids.
  // Return all items on the first call and empty on subsequent calls to prevent
  // duplicate event processing.
  let delivered = ref(false)

  {
    name: "SimulateSource",
    sourceFor: Sync,
    chain,
    poweredByHyperSync: false,
    pollingInterval: 0,
    getBlockHashes: (~blockNumbers as _, ~logger as _) => {
      Utils.Promise.resolve(Ok([]))
    },
    getHeightOrThrow: () => {
      // Report at least height 1 so the engine doesn't treat 0 as "no blocks available"
      Utils.Promise.resolve(max(endBlock, 1))
    },
    getItemsOrThrow: (
      ~fromBlock as _,
      ~toBlock as _,
      ~addressesByContractName as _,
      ~indexingContracts as _,
      ~knownHeight as _,
      ~partitionId as _,
      ~selection as _,
      ~retry as _,
      ~logger as _,
    ) => {
      // Return all items on first call, empty on subsequent calls
      let result = if delivered.contents {
        []
      } else {
        delivered := true
        items
      }

      let reportedHeight = max(endBlock, 1)
      Utils.Promise.resolve({
        Source.knownHeight: reportedHeight,
        reorgGuard: {
          rangeLastBlock: {
            blockHash: "0x0000000000000000000000000000000000000000000000000000000000000000",
            blockNumber: reportedHeight,
          },
          prevRangeLastBlock: None,
        },
        parsedQueueItems: result,
        fromBlockQueried: 0,
        latestFetchedBlockNumber: reportedHeight,
        latestFetchedBlockTimestamp: 0,
        stats: {
          totalTimeElapsed: 0.,
        },
      })
    },
  }
}
