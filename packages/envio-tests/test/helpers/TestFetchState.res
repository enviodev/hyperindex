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

let bufferedBlockNumbers = (fetchState: FetchState.t) =>
  fetchState->eventStoreOf->TestEventStore.blockNumbers

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

let handleQueryResult = (fetchState, ~query, ~latestFetchedBlock, ~page) =>
  fetchState
  ->FetchState.handleQueryResult(
    ~eventStore=fetchState->eventStoreOf,
    ~query,
    ~latestFetchedBlock,
    ~page,
  )
  ->keepStore(~from=fetchState)

let updateKnownHeight = (fetchState, ~knownHeight) =>
  fetchState
  ->FetchState.updateKnownHeight(~eventStore=fetchState->eventStoreOf, ~knownHeight)
  ->keepStore(~from=fetchState)

let getProgressPercentage = fetchState =>
  fetchState->FetchState.getProgressPercentage(~eventStore=fetchState->eventStoreOf)
