// Fetch-state transitions as tests step through them, with the arguments a
// test rarely cares about defaulted.
let make = (
  ~startBlock,
  ~endBlock,
  ~onEventRegistrations,
  ~addressStore,
  ~addressRows,
  ~maxAddrInPartition,
  ~chainId,
  ~onNotice,
  ~knownHeight,
  ~progressBlockNumber=?,
  ~onBlockRegistrations=?,
  ~blockLag=?,
  ~blockThrottle=?,
  ~firstEventBlock=?,
  ~clientFilterAddressThreshold=?,
  ~isResumed=?,
) =>
  FetchState.make(
    ~startBlock,
    ~endBlock,
    ~onEventRegistrations,
    ~addressStore,
    ~addressRows,
    ~maxAddrInPartition,
    ~chainId,
    ~onNotice,
    ~knownHeight,
    ~progressBlockNumber?,
    ~onBlockRegistrations?,
    ~blockLag?,
    ~blockThrottle?,
    ~firstEventBlock?,
    ~clientFilterAddressThreshold?,
    ~isResumed?,
  )

let handleQueryResult = (
  fetchState,
  ~query,
  ~latestFetchedBlock,
  ~itemsCount=0,
  ~registeringBlockNumbers=[],
) =>
  fetchState->FetchState.handleQueryResult(
    ~query,
    ~latestFetchedBlock,
    ~itemsCount,
    ~registeringBlockNumbers,
  )

let updateKnownHeight = (fetchState, ~knownHeight) =>
  fetchState->FetchState.updateKnownHeight(~knownHeight)
