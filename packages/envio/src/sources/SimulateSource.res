let make = (~items: array<Internal.item>, ~endBlock: int, ~chain: ChainMap.Chain.t): Source.t => {
  let reportedHeight = max(endBlock, 1)

  // Each item is delivered once, by the query that would first return it on a
  // real source. Retried or overlapping queries skip already-delivered items.
  let deliveredKeys = Utils.Set.make()
  let itemKey = (item: Internal.item) =>
    `${item->Internal.getItemBlockNumber->Int.toString}:${item
      ->Internal.getItemLogIndex
      ->Int.toString}`

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
      // filter to gate them exactly as it does for a HyperSync response.
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
        if deliveredKeys->Utils.Set.has(itemKey(item)) {
          false
        } else if blockNumber < fromBlock || blockNumber > toBlockQueried {
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
      parsedQueueItems->Array.forEach(item => deliveredKeys->Utils.Set.add(itemKey(item))->ignore)

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
