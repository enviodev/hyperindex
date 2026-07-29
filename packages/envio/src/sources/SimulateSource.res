let make = (
  ~items: array<Internal.item>,
  ~endBlock: int,
  ~chainId: ChainId.t,
  ~addressStore: AddressStore.t,
): Source.t => {
  let reportedHeight = max(endBlock, 1)

  {
    name: "SimulateSource",
    sourceFor: Sync,
    chainId,
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
      ~addressSet,
      ~knownHeight as _,
      ~partitionId as _,
      ~selection: FetchState.selection,
      ~itemsTarget as _,
      ~retry as _,
      ~logger as _,
    ) => {
      // Mirror a real backend: return only the items this query would match —
      // in the block range, part of the selection, at or after the
      // registration's own start block, and passing the same address gates a
      // real source applies natively while routing (the emitter must be
      // registered for the event's contract at or before the item's block, and
      // any address-valued param filter must hold). Overlapping queries may
      // return the same item more than once; the buffer dedups it.
      let toBlockQueried = switch toBlock {
      | Some(toBlock) => toBlock
      | None => reportedHeight
      }
      // By registration index, not `eventConfig.id`: two registrations of the
      // same event are independent and may sit in different partitions, so
      // matching on the shared event id would let a sibling's items leak into
      // this query.
      let selectionRegistrationIndexes = Utils.Set.make()
      selection.onEventRegistrations->Array.forEach(reg =>
        selectionRegistrationIndexes->Utils.Set.add(reg.index)->ignore
      )

      // A client-filtered contract is queried address-free, so this partition
      // holds none of its addresses and only the chain-wide store can answer
      // for it — exactly the fallback every real source's router makes.
      let isAddressAllowed = (address, ~contractName, ~blockNumber) =>
        switch selection.clientFilteredContracts {
        | Some(contractNames) if contractNames->Array.includes(contractName) =>
          addressStore->AddressStore.isIndexedAt(address, contractName, blockNumber)
        | _ => addressSet->AddressSet.containsAt(address, contractName, blockNumber)
        }

      // The registration's own start block, which the contract-wide address gate
      // can't express. Every native router applies it while routing.
      let hasStarted = (onEventRegistration: Internal.onEventRegistration, ~blockNumber) =>
        switch onEventRegistration.startBlock {
        | Some(startBlock) => blockNumber >= startBlock
        | None => true
        }

      let parsedQueueItems = items->Array.filter(item => {
        let eventItem = item->Internal.castUnsafeEventItem
        let {blockNumber, onEventRegistration} = eventItem
        if blockNumber < fromBlock || blockNumber > toBlockQueried {
          false
        } else if !(selectionRegistrationIndexes->Utils.Set.has(onEventRegistration.index)) {
          false
        } else if !(onEventRegistration->hasStarted(~blockNumber)) {
          false
        } else {
          let contractName = onEventRegistration.eventConfig.contractName
          let emitterAllowed =
            onEventRegistration.isWildcard ||
            eventItem.payload
            ->Internal.getPayloadSrcAddress
            ->isAddressAllowed(~contractName, ~blockNumber)
          emitterAllowed &&
          switch onEventRegistration.addressFilterParamGroups {
          | None
          | Some([]) => true
          | Some(groups) =>
            let params = eventItem.payload->Internal.getPayloadAddressParams
            groups->Array.some(group =>
              group->Array.every(
                name => params->Dict.getUnsafe(name)->isAddressAllowed(~contractName, ~blockNumber),
              )
            )
          }
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
