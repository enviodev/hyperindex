let indexedParamAt = (eventConfig: Internal.evmEventConfig, position) => {
  let index = switch eventConfig.sighash {
  | Some(_) => position - 1
  | None => position
  }
  eventConfig.paramsMetadata->Array.filter(param => param.indexed)->Array.get(index)
}

// The topic a log of this event carries at `position`, encoded from the
// simulated item's params with the same encoder a `where` value goes through.
// A value that doesn't encode has no topic, so it matches no filter value.
let topicAt = (eventConfig: Internal.evmEventConfig, ~params: dict<unknown>, position) =>
  switch eventConfig.sighash {
  | Some(sighash) if position === 0 => Some(sighash->EvmTypes.Hex.fromStringUnsafe)
  | _ =>
    eventConfig
    ->indexedParamAt(position)
    ->Option.flatMap(param =>
      try Some(
        EventConfigBuilder.getTopicEncoder(param.abiType)(params->Dict.getUnsafe(param.name)),
      ) catch {
      | _ => None
      }
    )
  }

// A block item for every block in [fromBlock, toBlock] a selected registration
// runs on, each carrying its block inline — the way `block_selection.rs` routes
// a real source's blocks. One the simulated chain has no block for is skipped.
let blockItems = (
  onBlockRegistrations: array<Internal.onBlockRegistration>,
  ~fromBlock,
  ~toBlock,
  ~getBlock,
) => {
  let items = []
  if onBlockRegistrations->Utils.Array.notEmpty {
    for blockNumber in fromBlock to toBlock {
      let running =
        onBlockRegistrations->Array.filter(reg =>
          reg->BlockItem.runsOn(~blockNumber, ~chainStartBlock=0)
        )
      if running->Utils.Array.notEmpty {
        let block = getBlock(blockNumber)
        running->Array.forEach(onBlockRegistration =>
          items->Array.push(
            Internal.Block({
              onBlockRegistration,
              blockNumber,
              ?block,
              skipped: ?(block->Option.isNone ? Some(true) : None),
            }),
          )
        )
      }
    }
  }
  items
}

let make = (
  ~items: array<Internal.item>,
  ~getBlock: int => option<Internal.eventBlock>,
  ~endBlock: int,
  ~chainId: ChainId.t,
  ~addressStore: AddressStore.t,
  ~ecosystem: Ecosystem.name=Evm,
  // Rows the items read from the buffer rather than carry: SVM transactions,
  // their account activity, and slots. Handed over with the first response.
  ~page: option<BufferPage.t>=None,
  // The chain's block handlers, which a request names by index.
  ~onBlockRegistrations: array<Internal.onBlockRegistration>=[],
): Source.t => {
  let reportedHeight = max(endBlock, 1)

  {
    name: "SimulateSource",
    sourceFor: Sync,
    chainId,
    poweredByHyperSync: false,
    pollingInterval: 0,
    getBlockHashes: Some(
      _ => Promise.resolve({Source.result: Ok(BufferPage.empty(~ecosystem)), requestStats: []}),
    ),
    // At least height 1, so the engine doesn't treat 0 as "no blocks available".
    getHeight: () => Promise.resolve({Source.result: Ok(reportedHeight), requestStats: []}),
    getItems: (~request, ~toBlock, ~retry as _, ~reorgableFrom as _, ~knownHeight as _) => {
      let fromBlock = request->IndexingPlan.Request.fromBlock
      let selection = request->IndexingPlan.Request.selection(~toBlock)
      // Mirror a real backend: return only the items this query would match —
      // in the block range, part of the selection, at or after the
      // registration's own start block, matching one of its `where.params`
      // alternatives, and emitted by an address registered for the event's
      // contract at or before the item's block. Overlapping queries may return
      // the same item more than once; the buffer dedups it.
      let toBlockQueried = switch toBlock {
      | Some(toBlock) => toBlock
      | None => reportedHeight
      }
      // By registration index, not by event: two registrations of the same
      // event are independent and may be in different requests, so matching on
      // the shared event would let a sibling's items leak into this one.
      let selectionRegistrationIndexes = Utils.Set.fromArray(selection.onEventRegistrationIndexes)

      // A contract fetched address-free has none of its addresses in the
      // request, so only the chain-wide store can answer for it, as matching
      // does for every source.
      let isAddressAllowed = (address, ~contractName, ~blockNumber) =>
        selection.addressFreeContracts->Array.includes(contractName)
          ? addressStore->AddressStore.isIndexedAt(address, contractName, blockNumber)
          : request->IndexingPlan.Request.containsAddressAt(address, ~contractName, ~blockNumber)

      // The registration's own start block, which the contract-wide address gate
      // can't express. Matching applies it for every other source.
      let hasStarted = (onEventRegistration: Internal.onEventRegistration, ~blockNumber) =>
        switch onEventRegistration.startBlock {
        | Some(startBlock) => blockNumber >= startBlock
        | None => true
        }

      // Real sources select logs by topic, so an item must match one of the
      // `where.params` alternatives: a static value by its encoding, and
      // `chain.<Contract>.addresses` by the contract's registered addresses.
      let topicFiltersMatch = (eventItem: Internal.eventItem) =>
        switch ecosystem {
        | Evm =>
          let registration =
            eventItem.onEventRegistration->(
              Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration
            )
          let eventConfig =
            registration.eventConfig->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)
          let params = eventItem.payload->Internal.getPayloadParams
          let matchesAt = (topicConstraint: Internal.topicConstraint, position) =>
            switch topicConstraint {
            | Any => true
            | ContractAddresses({contractName}) =>
              switch eventConfig->indexedParamAt(position) {
              | Some(param) =>
                params
                ->Dict.getUnsafe(param.name)
                ->(Utils.magic: unknown => Address.t)
                ->isAddressAllowed(~contractName, ~blockNumber=eventItem.blockNumber)
              | None => false
              }
            | Values(values) =>
              switch eventConfig->topicAt(~params, position) {
              | Some(topic) => values->Array.includes(topic)
              | None => false
              }
            }
          registration.resolvedWhere.topicFilters->Array.some(filter =>
            filter.topic0->matchesAt(0) &&
            filter.topic1->matchesAt(1) &&
            filter.topic2->matchesAt(2) &&
            filter.topic3->matchesAt(3)
          )
        | Fuel | Svm => true
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
        } else if !topicFiltersMatch(eventItem) {
          false
        } else {
          onEventRegistration.isWildcard ||
          eventItem.payload
          ->Internal.getPayloadSrcAddress
          ->isAddressAllowed(
            ~contractName=onEventRegistration.eventConfig.contractName,
            ~blockNumber,
          )
        }
      })

      let responsePage = BufferPage.fromItems(
        parsedQueueItems->Array.concat(
          onBlockRegistrations
          ->Array.filter(registration =>
            selection.onBlockRegistrationIndexes->Array.includes(registration.index)
          )
          ->blockItems(
            ~fromBlock,
            ~toBlock=toBlockQueried,
            ~getBlock,
          ),
        ),
        ~blocks=[],
        ~ecosystem,
      )
      // Appending moves the rows, so only the first response carries them.
      switch page {
      | Some(page) => responsePage->BufferPage.append(page)
      | None => ()
      }
      Promise.resolve({
        Source.result: Ok({
          Source.knownHeight: Some(reportedHeight),
          // EVM/Fuel keep transaction and block inline. SVM simulate adds a
          // page of them so the items read them as a HyperSync page's do.
          page: responsePage,
          latestFetchedBlockNumber: toBlockQueried,
        }),
        requestStats: [],
      })
    },
  }
}
