// A fetch state next to its chain's event store, the way ChainState holds the
// two. Tests step a fetch state through many transitions; this keeps each
// version paired with the store it was built against, so a test doesn't pass
// the store to every call. A record built by hand, or by spreading another,
// has no store until `pair` gives it one.
let stores: WeakMap.t<FetchState.t, EventStore.t> = WeakMap.make()

let pair = (fetchState: FetchState.t, ~eventStore: EventStore.t) => {
  stores->WeakMap.set(fetchState, eventStore)->ignore
  fetchState
}

let eventStoreOf = (fetchState: FetchState.t) =>
  switch stores->WeakMap.get(fetchState) {
  | Some(eventStore) => eventStore
  | None =>
    JsError.throwWithMessage(
      "This fetch state has no event store. Build it with a TestFetchState transition, or give it one with TestFetchState.pair.",
    )
  }

// Pairs the result of a transition with the store its input had.
let keepStore = (next: FetchState.t, ~from: FetchState.t) =>
  next->pair(~eventStore=from->eventStoreOf)

// A changed copy of a fetch state, on the same store.
let update = (fetchState: FetchState.t, change: FetchState.t => FetchState.t) =>
  fetchState->change->keepStore(~from=fetchState)

// Rows name block handlers by their index into the chain's full list, which the
// fetch state keeps only the generated ones of.
let contextOf = (fetchState: FetchState.t): StoredItems.context => {
  let onBlockRegistrations = []
  fetchState.onBlockRegistrations->Array.forEach(registration =>
    onBlockRegistrations->Array.setUnsafe(registration.index, registration)
  )
  {chainId: fetchState.chainId, onEventRegistrations: [], onBlockRegistrations}
}

let bufferedItems = (fetchState: FetchState.t): array<Internal.item> =>
  fetchState->eventStoreOf->TestEventStore.itemsOf(~context=fetchState->contextOf)

// Puts `items` in the fetch state's store, as an applied response would.
let withItems = (fetchState: FetchState.t, items: array<Internal.item>) => {
  fetchState->eventStoreOf->EventStore.merge(TestEventStore.pageOf(items))
  fetchState
}

let bufferSize = (fetchState: FetchState.t) => fetchState->eventStoreOf->EventStore.length

let make = (
  ~startBlock,
  ~endBlock,
  ~onEventRegistrations,
  ~addressStore,
  ~addressRows,
  ~maxAddrInPartition,
  ~chainId,
  ~onNotice,
  ~maxOnBlockBufferSize,
  ~knownHeight,
  ~progressBlockNumber=?,
  ~onBlockRegistrations=?,
  ~blockLag=?,
  ~blockThrottle=?,
  ~firstEventBlock=?,
  ~clientFilterAddressThreshold=?,
  ~isResumed=?,
) => {
  let eventStore = EventStore.make()
  FetchState.make(
    ~startBlock,
    ~endBlock,
    ~onEventRegistrations,
    ~addressStore,
    ~eventStore,
    ~addressRows,
    ~maxAddrInPartition,
    ~chainId,
    ~onNotice,
    ~maxOnBlockBufferSize,
    ~knownHeight,
    ~progressBlockNumber?,
    ~onBlockRegistrations?,
    ~blockLag?,
    ~blockThrottle?,
    ~firstEventBlock?,
    ~clientFilterAddressThreshold?,
    ~isResumed?,
  )->pair(~eventStore)
}

let updateInternal = (fetchState, ~optimizedPartitions=?, ~blockLag=?, ~knownHeight=?) =>
  fetchState
  ->FetchState.updateInternal(
    ~eventStore=fetchState->eventStoreOf,
    ~optimizedPartitions?,
    ~blockLag?,
    ~knownHeight?,
  )
  ->keepStore(~from=fetchState)

let handleQueryResult = (fetchState, ~query, ~latestFetchedBlock, ~page) =>
  fetchState
  ->FetchState.handleQueryResult(
    ~eventStore=fetchState->eventStoreOf,
    ~query,
    ~latestFetchedBlock,
    ~page,
  )
  ->keepStore(~from=fetchState)

let registerDynamicContracts = (
  fetchState,
  ~addressStore,
  ~onNotice,
  ~claimCeiling=?,
  registrations,
) =>
  fetchState
  ->FetchState.registerDynamicContracts(
    ~addressStore,
    ~eventStore=fetchState->eventStoreOf,
    ~onNotice,
    ~claimCeiling?,
    registrations,
  )
  ->keepStore(~from=fetchState)

let updateKnownHeight = (fetchState, ~knownHeight) =>
  fetchState
  ->FetchState.updateKnownHeight(~eventStore=fetchState->eventStoreOf, ~knownHeight)
  ->keepStore(~from=fetchState)

let rollback = (
  fetchState,
  ~rolledBackAddressStore,
  ~targetBlockNumber,
): FetchState.rollbackResult => {
  let result =
    fetchState->FetchState.rollback(
      ~rolledBackAddressStore,
      ~eventStore=fetchState->eventStoreOf,
      ~targetBlockNumber,
    )
  {...result, fetchState: result.fetchState->keepStore(~from=fetchState)}
}

let getReadyItemsCount = (fetchState, ~targetSize, ~fromItem) =>
  fetchState->FetchState.getReadyItemsCount(
    ~eventStore=fetchState->eventStoreOf,
    ~targetSize,
    ~fromItem,
  )

let bufferReadyCount = fetchState =>
  fetchState->FetchState.bufferReadyCount(~eventStore=fetchState->eventStoreOf)

let getProgressBlockNumberAt = (fetchState, ~index) =>
  fetchState->FetchState.getProgressBlockNumberAt(~eventStore=fetchState->eventStoreOf, ~index)

let getProgressPercentage = fetchState =>
  fetchState->FetchState.getProgressPercentage(~eventStore=fetchState->eventStoreOf)

let isActivelyIndexing = fetchState =>
  fetchState->FetchState.isActivelyIndexing(~eventStore=fetchState->eventStoreOf)

let isReadyToEnterReorgThreshold = (~tolerance, fetchState) =>
  fetchState->FetchState.isReadyToEnterReorgThreshold(
    ~tolerance,
    ~eventStore=fetchState->eventStoreOf,
  )

let sortForBatch = (fetchStates, ~batchSizeTarget) =>
  fetchStates->FetchState.sortForBatch(
    ~fetchStateOf=fetchState => fetchState,
    ~eventStoreOf,
    ~batchSizeTarget,
  )

let resetPendingQueries = fetchState =>
  fetchState->FetchState.resetPendingQueries->keepStore(~from=fetchState)
