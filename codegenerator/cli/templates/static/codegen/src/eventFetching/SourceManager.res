open Belt

// Ideally the ChainFetcher name suits this better
// But currently the ChainFetcher module is immutable
// and handles both processing and fetching.
// So this module is to encapsulate the fetching logic only
// with a mutable state for easier reasoning and testing.
type t = {
  logger: Pino.t,
  endBlock: option<int>,
  maxPartitionConcurrency: int,
  mutable isWaitingForNewBlock: bool,
  // Should take into consideration partitions fetching for previous states (before rollback)
  mutable fetchingPartitionsCount: int,
}

let make = (~maxPartitionConcurrency, ~endBlock, ~logger) => {
  logger,
  endBlock,
  maxPartitionConcurrency,
  isWaitingForNewBlock: false,
  fetchingPartitionsCount: 0,
}

exception FromBlockIsHigherThanToBlock({fromBlock: int, toBlock: int})

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
  let {logger, endBlock, maxPartitionConcurrency} = sourceManager

  switch fetchState->FetchState.getNextQuery(
    ~endBlock,
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
    if !sourceManager.isWaitingForNewBlock {
      sourceManager.isWaitingForNewBlock = true
      let currentBlockHeight = await waitForNewBlock(~currentBlockHeight, ~logger)
      sourceManager.isWaitingForNewBlock = false
      onNewBlock(~currentBlockHeight)
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
