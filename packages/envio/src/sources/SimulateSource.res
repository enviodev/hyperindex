let make = (~items: array<Internal.item>, ~endBlock: int, ~chain: ChainMap.Chain.t): Source.t => {
  let reportedHeight = max(endBlock, 1)

  {
    name: "SimulateSource",
    simulateItems: items,
    sourceFor: Sync,
    chain,
    poweredByHyperSync: false,
    pollingInterval: 0,
    getBlockHashes: (~blockNumbers as _, ~logger as _) => {
      Promise.resolve({Source.result: Ok([]), requestStats: []})
    },
    getHeightOrThrow: () => {
      // Report at least height 1 so the engine doesn't treat 0 as "no blocks available"
      Promise.resolve({Source.height: reportedHeight, requestStats: []})
    },
    getItemsOrThrow: (
      ~fromBlock,
      ~toBlock,
      ~addressesByContractName as _,
      ~contractNameByAddress,
      ~knownHeight as _,
      ~partitionId as _,
      ~selection: FetchState.selection,
      ~itemsTarget as _,
      ~retry as _,
      ~logger as _,
    ) => {
      // Mirror a real backend: return only the items this query would match —
      // in the block range, part of the selection, and (for non-wildcard events)
      // emitted by an address the partition is querying. Wildcard events are
      // over-fetched regardless of srcAddress, leaving the client-side address
      // filter to gate them exactly as it does for a HyperSync response. Overlapping
      // queries may return the same item more than once; the buffer dedups it.
      let toBlockQueried = switch toBlock {
      | Some(toBlock) => toBlock
      | None => reportedHeight
      }
      let selectionEventIds = Utils.Set.make()
      selection.onEventRegistrations->Array.forEach(reg =>
        selectionEventIds->Utils.Set.add(reg.eventConfig.id)->ignore
      )

      let parsedQueueItems = items->Array.filter(item => {
        let eventItem = item->Internal.castUnsafeEventItem
        let {blockNumber, onEventRegistration} = eventItem
        if blockNumber < fromBlock || blockNumber > toBlockQueried {
          false
        } else if !(selectionEventIds->Utils.Set.has(onEventRegistration.eventConfig.id)) {
          false
        } else if onEventRegistration.isWildcard {
          true
        } else {
          let sa = eventItem.payload->Internal.getPayloadSrcAddress->Address.toString
          contractNameByAddress->Utils.Dict.dangerouslyGetNonOption(sa)->Option.isSome
        }
      })

      Promise.resolve({
        Source.knownHeight: reportedHeight,
        blockHashes: [],
        parsedQueueItems,
        // Simulate keeps the transaction and block inline on the payload; no store pages.
        transactionStore: None,
        blockStore: None,
        fromBlockQueried: fromBlock,
        latestFetchedBlockNumber: toBlockQueried,
        latestFetchedBlockTimestamp: 0,
        stats: {
          totalTimeElapsed: 0.,
        },
        requestStats: [],
      })
    },
  }
}
