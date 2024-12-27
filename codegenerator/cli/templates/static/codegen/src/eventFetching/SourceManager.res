open Belt

// Can't simply store fetching partitions, since fetchNext
// can be called with old chainFetchers after isFetching was set to false,
// but state isn't still updated with fetched data.
type partitionFetchingState = {
  isFetching: bool,
  prevFetchedIdempotencyKey?: int,
}

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
  mutable allPartitionsFetchingState: array<partitionFetchingState>,
  // Don't use fetchingPartitions size, but have a separate counter
  // to take into consideration partitions fetching for previous states (before rollback)
  mutable fetchingPartitionsCount: int,
  // Keep track on the current state id
  // to work with correct state during rollbacks & preRegistration
  mutable currentStateId: int,
}

let make = (~maxPartitionConcurrency, ~endBlock, ~logger) => {
  logger,
  endBlock,
  maxPartitionConcurrency,
  isWaitingForNewBlock: false,
  // Don't prefill with empty partitionFetchingState,
  // since partitions might be added with the lifetime of the application.
  // So lazily create fetchingState, when we execute a new partition
  allPartitionsFetchingState: [],
  currentStateId: 0,
  fetchingPartitionsCount: 0,
}

exception FromBlockIsHigherThanToBlock({fromBlock: int, toBlock: int})

let fetchNext = async (
  sourceManager: t,
  ~allPartitions: PartitionedFetchState.allPartitions,
  ~currentBlockHeight,
  ~executeQuery,
  ~waitForNewBlock,
  ~onNewBlock,
  ~maxPerChainQueueSize,
  ~stateId,
) => {
  if stateId < sourceManager.currentStateId {
    ()
  } else {
    if stateId != sourceManager.currentStateId {
      sourceManager.currentStateId = stateId

      // Reset instead of clear, so updating state from partitions from prev state doesn't corrupt data
      sourceManager.allPartitionsFetchingState = []
    }
    let {logger, endBlock, allPartitionsFetchingState, maxPartitionConcurrency} = sourceManager

    let readyPartitions =
      allPartitions
      ->PartitionedFetchState.getReadyPartitions(~maxPerChainQueueSize)
      ->Js.Array2.filter(fetchState => {
        switch allPartitionsFetchingState->Belt.Array.get(fetchState.partitionId) {
        | Some({isFetching: true}) => false
        // Deduplicate queries when fetchNext is called after
        // isFetching was set to false, but state isn't updated with fetched data
        | Some({prevFetchedIdempotencyKey}) => prevFetchedIdempotencyKey < fetchState.responseCount
        | _ => true
        }
      })

    let hasQueryWaitingForNewBlock = ref(false)
    let queries = readyPartitions->Array.keepMap(fetchState => {
      fetchState
      ->FetchState.getNextQuery(~endBlock)
      ->Option.flatMap(nextQuery => {
        switch nextQuery {
        | MergeQuery(_) => Some(nextQuery)
        | PartitionQuery(query) =>
          let {fromBlock, toBlock} = query
          if fromBlock > currentBlockHeight {
            hasQueryWaitingForNewBlock := true
            None
          } else {
            switch toBlock {
            | Some(toBlock) if toBlock < fromBlock =>
              //This is an invalid case. We should never arrive at this match arm but it would be
              //detrimental if it were the case.
              FromBlockIsHigherThanToBlock({fromBlock, toBlock})->ErrorHandling.mkLogAndRaise(
                ~logger,
                ~msg="Unexpected error getting next query in partition",
              )
            | _ => ()
            }
            Some(nextQuery)
          }
        }
      })
    })

    switch (queries, currentBlockHeight) {
    | ([], _)
    | // For the case with currentBlockHeight=0 we should
    // force getting the known chain block, even if there are no ready queries
    (_, 0) =>
      if (
        sourceManager.isWaitingForNewBlock ||
        (!hasQueryWaitingForNewBlock.contents && currentBlockHeight !== 0)
      ) {
        // Do nothing if there are no queries which should wait,
        // or we are already waiting. Explicitely with if/else, so it's not lost
        ()
      } else {
        sourceManager.isWaitingForNewBlock = true
        let currentBlockHeight = await waitForNewBlock(~currentBlockHeight, ~logger)
        sourceManager.isWaitingForNewBlock = false
        onNewBlock(~currentBlockHeight)
      }
    | (queries, _) =>
      let maxQueriesNumber = maxPartitionConcurrency - sourceManager.fetchingPartitionsCount
      if maxQueriesNumber > 0 {
        let slicedQueries = if queries->Js.Array2.length > maxQueriesNumber {
          let _ = queries->Js.Array2.sortInPlaceWith((a, b) =>
            switch (a, b) {
            | (MergeQuery(_), MergeQuery(_)) => 0
            | (MergeQuery(_), PartitionQuery(_)) => -1
            | (PartitionQuery(_), MergeQuery(_)) => 1
            | (PartitionQuery(a), PartitionQuery(b)) => a.fromBlock - b.fromBlock
            }
          )
          queries->Js.Array2.slice(~start=0, ~end_=maxQueriesNumber)
        } else {
          queries
        }
        let _ =
          await slicedQueries
          ->Array.map(async query => {
            switch query {
            | PartitionQuery({partitionId, idempotencyKey})
            | MergeQuery({partitionId, idempotencyKey}) => {
                sourceManager.fetchingPartitionsCount = sourceManager.fetchingPartitionsCount + 1
                allPartitionsFetchingState->Js.Array2.unsafe_set(
                  partitionId,
                  {
                    isFetching: true,
                  },
                )
                let data = await query->executeQuery
                sourceManager.fetchingPartitionsCount = sourceManager.fetchingPartitionsCount - 1
                allPartitionsFetchingState->Js.Array2.unsafe_set(
                  partitionId,
                  {
                    isFetching: false,
                    prevFetchedIdempotencyKey: idempotencyKey,
                  },
                )
                data
              }
            }
          })
          ->Promise.all
      }
    }
  }
}
