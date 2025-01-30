open Belt

// Ideally the ChainFetcher name suits this better
// But currently the ChainFetcher module is immutable
// and handles both processing and fetching.
// So this module is to encapsulate the fetching logic only
// with a mutable state for easier reasoning and testing.
type t = {
  logger: Pino.t,
  maxPartitionConcurrency: int,
  mutable waitingForNewBlockStateId: option<int>,
  // Should take into consideration partitions fetching for previous states (before rollback)
  mutable fetchingPartitionsCount: int,
}

let make = (~maxPartitionConcurrency, ~logger) => {
  logger,
  maxPartitionConcurrency,
  waitingForNewBlockStateId: None,
  fetchingPartitionsCount: 0,
}

let fetchNext = async (
  sourceManager: t,
  ~fetchState: FetchState.t,
  ~currentBlockHeight,
  ~executeQuery,
  ~waitForNewBlock,
  ~onNewBlock,
  ~maxPerChainQueueSize,
  ~stateId,
) => {
  let {logger, maxPartitionConcurrency} = sourceManager

  switch fetchState->FetchState.getNextQuery(
    ~concurrencyLimit={
      maxPartitionConcurrency - sourceManager.fetchingPartitionsCount
    },
    ~maxQueueSize=maxPerChainQueueSize,
    ~currentBlockHeight,
    ~stateId,
  ) {
  | ReachedMaxConcurrency
  | NothingToQuery => ()
  | WaitingForNewBlock =>
    switch sourceManager.waitingForNewBlockStateId {
    | Some(waitingStateId) if waitingStateId >= stateId => ()
    | Some(_) // Case for the prev state before a rollback
    | None =>
      sourceManager.waitingForNewBlockStateId = Some(stateId)
      let currentBlockHeight = await waitForNewBlock(~currentBlockHeight, ~logger)
      switch sourceManager.waitingForNewBlockStateId {
        | Some(waitingStateId) if waitingStateId === stateId => {
          sourceManager.waitingForNewBlockStateId = None
          onNewBlock(~currentBlockHeight)
        }
        | Some(_) // Don't reset it if we are waiting for another state
        | None => ()
      }
    }
  | Ready(queries) => {
      fetchState->FetchState.startFetchingQueries(~queries, ~stateId)
      sourceManager.fetchingPartitionsCount =
        sourceManager.fetchingPartitionsCount + queries->Array.length
      let _ =
        await queries
        ->Array.map(q => {
          let promise = q->executeQuery
          let _ = promise->Promise.thenResolve(_ => {
            sourceManager.fetchingPartitionsCount = sourceManager.fetchingPartitionsCount - 1
          })
          promise
        })
        ->Promise.all
    }
  }
}
