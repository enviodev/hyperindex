// Subgraph mode only. A subgraph's call handlers run on calls, which a log
// source never sees, so each source of a chain is wrapped: it fetches the logs
// of a query as before, and the calls of the same block range from a trace
// backend (`subgraph/calls-source.ts`). A call comes back as the event item it
// travels as for the rest of envio — partitioning, ordering, the register
// pass and rollback never tell it from a log.

type callRegistration = {
  index: int,
  contractName: string,
  eventName: string,
  selector: Nullable.t<string>,
  rank: int,
  isWildcard: bool,
  startBlock: Nullable.t<int>,
}

type request = {
  chainId: ChainId.t,
  fromBlock: int,
  toBlock: int,
  registrations: array<callRegistration>,
  addresses: dict<array<string>>,
  rpcUrls: array<string>,
}

type callItem = {
  registrationIndex: int,
  blockNumber: int,
  transactionIndex: int,
  traceAddress: array<int>,
  payload: Internal.eventPayload,
}

type response = {
  items: array<callItem>,
  latestFetchedBlockNumber: int,
  blocks: array<BlockStore.inputBlock>,
  knownHeight: Nullable.t<int>,
}

type installed = {
  fetchCalls: request => promise<response>,
  rpcUrls: array<string>,
}

let installed: ref<option<installed>> = ref(None)

let install = (~fetchCalls, ~rpcUrls) => {
  installed := Some({fetchCalls, rpcUrls})
}

// The block range one call query covers when the partition's own is open-ended.
let openEndedSpan = 1_000_000

let callRankOf = (registration: Internal.onEventRegistration) =>
  Internal.callRankOfEventName(registration.eventConfig.name)

// `__envio_call_<8 hex digits>_<function>`
let selectorOf = (registration: Internal.onEventRegistration) =>
  switch registration->callRankOf {
  | Some(1) =>
    Nullable.Value(
      "0x" ++ registration.eventConfig.name->String.slice(~start=13, ~end=21)->String.toLowerCase,
    )
  | _ => Nullable.null
  }

let wrap = (
  source: Source.t,
  ~addressStore: AddressStore.t,
  ~ecosystem: Ecosystem.name,
  installed: installed,
): Source.t => {
  ...source,
  getItemsOrThrow: async (
    ~fromBlock,
    ~toBlock,
    ~addressSet,
    ~includeAllBlocks,
    ~knownHeight,
    ~partitionId,
    ~selection: FetchState.selection,
    ~itemsTarget,
    ~retry,
    ~logger,
  ) => {
    let callRegistrations =
      selection.onEventRegistrations->Array.filter(registration =>
        registration->callRankOf->Option.isSome
      )
    if callRegistrations->Utils.Array.isEmpty {
      await source.getItemsOrThrow(
        ~fromBlock,
        ~toBlock,
        ~addressSet,
        ~includeAllBlocks,
        ~knownHeight,
        ~partitionId,
        ~selection,
        ~itemsTarget,
        ~retry,
        ~logger,
      )
    } else {
      let logRegistrations =
        selection.onEventRegistrations->Array.filter(registration =>
          registration->callRankOf->Option.isNone
        )
      let logs = if logRegistrations->Utils.Array.isEmpty {
        None
      } else {
        Some(
          await source.getItemsOrThrow(
            ~fromBlock,
            ~toBlock,
            ~addressSet,
            ~includeAllBlocks,
            ~knownHeight,
            ~partitionId,
            ~selection={...selection, onEventRegistrations: logRegistrations},
            ~itemsTarget,
            ~retry,
            ~logger,
          ),
        )
      }

      // Calls are asked for only as far as the logs were: a source may stop a
      // page short, and the two have to agree on where the answer ends.
      let rangeEnd = switch (logs, toBlock) {
      | (Some(logs), _) => logs.latestFetchedBlockNumber
      | (None, Some(toBlock)) => toBlock
      | (None, None) => Math.Int.min(knownHeight, fromBlock + openEndedSpan)
      }

      let clientFiltered = contractName =>
        switch selection.clientFilteredContracts {
        | Some(contractNames) => contractNames->Array.includes(contractName)
        | None => false
        }
      let addresses = Dict.make()
      callRegistrations->Array.forEach(registration => {
        let contractName = registration.eventConfig.contractName
        if !registration.isWildcard && addresses->Dict.get(contractName)->Option.isNone {
          addresses->Dict.set(
            contractName,
            clientFiltered(contractName)
              ? addressStore->AddressStore.contractAddresses(contractName, ~shouldChecksum=false)
              : addressSet->AddressSet.addressesOf(contractName),
          )
        }
      })

      let startedAt = Performance.now()
      let response = try await installed.fetchCalls({
        chainId: source.chainId,
        fromBlock,
        toBlock: rangeEnd,
        registrations: callRegistrations->Array.map(registration => {
          index: registration.index,
          contractName: registration.eventConfig.contractName,
          eventName: registration.eventConfig.name,
          selector: registration->selectorOf,
          rank: registration->callRankOf->Option.getOr(1),
          isWildcard: registration.isWildcard,
          startBlock: registration.startBlock->Nullable.fromOption,
        }),
        addresses: addresses->(Utils.magic: dict<array<Address.t>> => dict<array<string>>),
        rpcUrls: installed.rpcUrls,
      }) catch {
      | exn =>
        throw(
          Source.GetItemsError(
            Source.FailedGettingItems({
              exn,
              attemptedToBlock: rangeEnd,
              retry: WithBackoff({
                message: `Failed reading the calls of blocks ${fromBlock->Int.toString} to ${rangeEnd->Int.toString}. Attempt a retry.`,
                backoffMillis: switch retry {
                | 0 => 500
                | _ => 1000 * retry
                },
              }),
              requestStats: [],
            }),
          ),
        )
      }
      let callSeconds = startedAt->Performance.secondsSince

      let registrationByIndex = Dict.make()
      callRegistrations->Array.forEach(registration =>
        registrationByIndex->Dict.set(registration.index->Int.toString, registration)
      )
      let latest = response.latestFetchedBlockNumber
      let callItems = response.items->Array.filterMap(callItem => {
        let registration =
          registrationByIndex->Dict.getUnsafe(callItem.registrationIndex->Int.toString)
        let contractName = registration.eventConfig.contractName
        // The partition's own slice of the contract's addresses, as a log's
        // router applies it; a client-filtered contract answers to the store.
        let ownsCall =
          registration.isWildcard || {
            let address = callItem.payload->Internal.getPayloadSrcAddress
            if clientFiltered(contractName) {
              addressStore->AddressStore.isIndexedAt(address, contractName, callItem.blockNumber)
            } else {
              addressSet->AddressSet.containsAt(address, contractName, callItem.blockNumber)
            }
          }
        if callItem.blockNumber <= latest && ownsCall {
          let item = Internal.Event({
            onEventRegistration: registration,
            chainId: source.chainId,
            blockNumber: callItem.blockNumber,
            logIndex: 0,
            orderPath: callItem.traceAddress,
            transactionIndex: callItem.transactionIndex,
            payload: callItem.payload,
          })
          item->Internal.markItemCall(~rank=registration->callRankOf->Option.getOr(1))
          Some(item)
        } else {
          None
        }
      })

      let callBlocks = BlockStore.fromJs(response.blocks, ~ecosystem)
      let callRequestStat = {Source.method: "getCalls", seconds: callSeconds}
      switch logs {
      | Some(logs) =>
        logs.blockStore->BlockStore.appendPage(callBlocks)
        {
          ...logs,
          parsedQueueItems: Array.concat(
            logs.parsedQueueItems->Array.filter(item =>
              item->Internal.getItemBlockNumber <= latest
            ),
            callItems,
          ),
          latestFetchedBlockNumber: Math.Int.min(logs.latestFetchedBlockNumber, latest),
          requestStats: Array.concat(logs.requestStats, [callRequestStat]),
        }
      | None => {
          Source.knownHeight: response.knownHeight->Nullable.getOr(knownHeight),
          parsedQueueItems: callItems,
          transactionStore: None,
          blockStore: callBlocks,
          latestFetchedBlockNumber: latest,
          stats: {totalTimeElapsed: callSeconds},
          requestStats: [callRequestStat],
        }
      }
    }
  },
}

// Wraps every source of a chain when its registrations hold a call trigger
// and the subgraph runtime has installed the backend that reads them.
let wrapSources = (
  sources: array<Source.t>,
  ~onEventRegistrations: array<Internal.onEventRegistration>,
  ~addressStore,
  ~ecosystem,
) =>
  switch installed.contents {
  | Some(installed)
    if onEventRegistrations->Array.some(registration => registration->callRankOf->Option.isSome) =>
    sources->Array.map(source => source->wrap(~addressStore, ~ecosystem, installed))
  | _ => sources
  }
