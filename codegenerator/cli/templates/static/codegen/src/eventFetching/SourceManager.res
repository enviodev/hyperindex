open Belt

let toQueryId = (query: FetchState.nextQuery) => {
  query.fetchStateRegisterId->FetchState.registerIdToString ++ "-" ++ query.fromBlock->Int.toString
}

// Can't simply store fetching partitions, since fetchBatch
// can be called with old chainFetchers after isFetching was set to false,
// but state isn't still updated with fetched data.
// This is temporary until all fetching logic moved to mutable state,
// but for now prevent fetching the same partition twice with the same query,
// using lastFetchedQueryId (aka idempotency key)
type partitionFetchingState = {
  isFetching: bool,
  lastFetchedQueryId?: string,
}

// Ideally the ChainFetcher name suits this better
// But currently the ChainFetcher module is immutable
// and handles both processing and fetching.
// So this module is to encapsulate the fetching logic only
// with a mutable state for easier reasoning and testing.
type t = {
  logger: Pino.t,
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

let make = (~maxPartitionConcurrency, ~logger) => {
  logger,
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

let fetchBatch = async (
  sourceManager: t,
  ~allPartitions: PartitionedFetchState.allPartitions,
  ~currentBlockHeight,
  ~executePartitionQuery,
  ~waitForNewBlock,
  ~onNewBlock,
  ~maxPerChainQueueSize,
  ~setMergedPartitions,
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
    let {logger, allPartitionsFetchingState, maxPartitionConcurrency} = sourceManager

    let fetchingPartitions = Utils.Set.make()
    // Js.Array2.forEachi automatically skips empty items
    allPartitionsFetchingState->Js.Array2.forEachi(({isFetching}, partitionId) => {
      if isFetching {
        let _ = fetchingPartitions->Utils.Set.add(partitionId)
      }
    })
    let readyPartitions =
      allPartitions->PartitionedFetchState.getReadyPartitions(
        ~maxPerChainQueueSize,
        ~fetchingPartitions,
      )

    let mergedPartitions = Js.Dict.empty()
    let hasQueryWaitingForNewBlock = ref(false)
    let queries = readyPartitions->Array.keepMap(fetchState => {
      let mergedFetchState = fetchState->FetchState.mergeRegistersBeforeNextQuery
      if mergedFetchState !== fetchState {
        mergedPartitions->Js.Dict.set(fetchState.partitionId->(Utils.magic: int => string), mergedFetchState)
      }
      switch mergedFetchState->FetchState.getNextQuery {
      | Done => None
      | NextQuery(nextQuery) =>
        switch allPartitionsFetchingState->Belt.Array.get(fetchState.partitionId) {
        // Deduplicate queries when fetchBatch is called after
        // isFetching was set to false, but state isn't updated with fetched data
        | Some({lastFetchedQueryId}) if lastFetchedQueryId === toQueryId(nextQuery) => None
        | _ => {
            let {fromBlock, toBlock} = nextQuery
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
        }
      }
    })
    setMergedPartitions(mergedPartitions)

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
          let _ = queries->Js.Array2.sortInPlaceWith((a, b) => a.fromBlock - b.fromBlock)
          queries->Js.Array2.slice(~start=0, ~end_=maxQueriesNumber)
        } else {
          queries
        }
        let _ =
          await slicedQueries
          ->Array.map(async query => {
            let partitionId = query.partitionId
            sourceManager.fetchingPartitionsCount = sourceManager.fetchingPartitionsCount + 1
            allPartitionsFetchingState->Js.Array2.unsafe_set(
              partitionId,
              {
                isFetching: true,
              },
            )
            let data = await query->executePartitionQuery
            sourceManager.fetchingPartitionsCount = sourceManager.fetchingPartitionsCount - 1
            allPartitionsFetchingState->Js.Array2.unsafe_set(
              partitionId,
              {
                isFetching: false,
                lastFetchedQueryId: toQueryId(query),
              },
            )
            data
          })
          ->Promise.all
      }
    }
  }
}
