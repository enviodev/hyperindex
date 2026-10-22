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

let topicFilterMatches = (
  filter: Internal.topicFilter,
  ~topicAt,
  ~isContractAddressAt: (int, ~contractName: string) => bool,
) => {
  let matchesAt = (topicConstraint: Internal.topicConstraint, position) =>
    switch topicConstraint {
    | Any => true
    | ContractAddresses({contractName}) => isContractAddressAt(position, ~contractName)
    | Values(values) =>
      switch topicAt(position) {
      | Some(topic) => values->Array.includes(topic)
      | None => false
      }
    }
  filter.topic0->matchesAt(0) &&
  filter.topic1->matchesAt(1) &&
  filter.topic2->matchesAt(2) &&
  filter.topic3->matchesAt(3)
}

let make = (
  ~items: array<Internal.item>,
  ~endBlock: int,
  ~chainId: ChainId.t,
  ~addressStore: AddressStore.t,
  ~ecosystem: Ecosystem.name=Evm,
  ~transactionStore: option<TransactionStore.t>=None,
  ~blockStore: option<BlockStore.t>=None,
): Source.t => {
  let reportedHeight = max(endBlock, 1)

  {
    name: "SimulateSource",
    sourceFor: Sync,
    chainId,
    poweredByHyperSync: false,
    pollingInterval: 0,
    getBlockHashes: (~blockNumbers as _, ~logger as _) => {
      Promise.resolve({
        Source.result: Ok(BlockStore.fromJs([], ~ecosystem)),
        requestStats: [],
      })
    },
    getHeightOrThrow: () => {
      // Report at least height 1 so the engine doesn't treat 0 as "no blocks available"
      Promise.resolve({Source.height: reportedHeight, requestStats: []})
    },
    getItemsOrThrow: (
      ~fromBlock,
      ~toBlock,
      ~addressSet,
      ~includeAllBlocks as _,
      ~knownHeight as _,
      ~partitionId as _,
      ~selection: FetchState.selection,
      ~itemsTarget as _,
      ~retry as _,
      ~logger as _,
    ) => {
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
      // event are independent and may sit in different partitions, so matching
      // on the shared event would let a sibling's items leak into this query.
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
          let isContractAddressAt = (position, ~contractName) =>
            switch eventConfig->indexedParamAt(position) {
            | Some(param) =>
              params
              ->Dict.getUnsafe(param.name)
              ->(Utils.magic: unknown => Address.t)
              ->isAddressAllowed(~contractName, ~blockNumber=eventItem.blockNumber)
            | None => false
            }
          registration.resolvedWhere.topicFilters->Array.some(filter =>
            filter->topicFilterMatches(
              ~topicAt=topicAt(eventConfig, ~params, ...),
              ~isContractAddressAt,
            )
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

      Promise.resolve({
        Source.knownHeight: reportedHeight,
        parsedQueueItems,
        // EVM/Fuel keep transaction and block inline. SVM simulate returns a
        // store page so materialize + activity attach run the same path as HyperSync.
        transactionStore,
        blockStore: blockStore->Option.getOr(BlockStore.fromJs([], ~ecosystem)),
        latestFetchedBlockNumber: toBlockQueried,
        stats: {
          totalTimeElapsed: 0.,
        },
        requestStats: [],
      })
    },
  }
}
