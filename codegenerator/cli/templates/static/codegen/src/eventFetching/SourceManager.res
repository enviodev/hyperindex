open Belt

// Can't simply store fetching partitions, since fetchNext
// can be called with old chainFetchers after isFetching was set to false,
// but state isn't still updated with fetched data.
type partitionFetchingState = {
  mutable isFetching: bool,
  mutable lockedCount: int,
  mutable prevFetchedIdempotencyKey: option<int>,
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
  mutable partitionsFetchingState: dict<partitionFetchingState>,
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
  partitionsFetchingState: Js.Dict.empty(),
  currentStateId: 0,
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
  if stateId < sourceManager.currentStateId {
    ()
  } else {
    if stateId != sourceManager.currentStateId {
      sourceManager.currentStateId = stateId

      // Reset instead of clear, so updating state from partitions from prev state doesn't corrupt data
      sourceManager.partitionsFetchingState = Js.Dict.empty()
    }
    let {logger, endBlock, partitionsFetchingState, maxPartitionConcurrency} = sourceManager

    let waitForNewBlock = async () => {
      if !sourceManager.isWaitingForNewBlock {
        sourceManager.isWaitingForNewBlock = true
        let currentBlockHeight = await waitForNewBlock(~currentBlockHeight, ~logger)
        sourceManager.isWaitingForNewBlock = false
        onNewBlock(~currentBlockHeight)
      }
    }

    let getFetchingState = partitionId => {
      switch partitionsFetchingState->Utils.Dict.dangerouslyGetNonOption(partitionId) {
      | Some(f) => f
      | None => {
          let f = {
            isFetching: false,
            lockedCount: 0,
            prevFetchedIdempotencyKey: None,
          }
          partitionsFetchingState->Js.Dict.set(partitionId, f)
          f
        }
      }
    }

    // For the case with currentBlockHeight=0 we should
    // force getting the known chain block, even if there are no ready queries
    if currentBlockHeight === 0 {
      await waitForNewBlock()
    } else {
      switch fetchState->FetchState.getNextQuery(
        ~endBlock,
        ~concurrencyLimit={
          maxPartitionConcurrency - sourceManager.fetchingPartitionsCount
        },
        ~maxQueueSize=maxPerChainQueueSize,
        ~currentBlockHeight,
        ~checkPartitionStatus=register => {
          switch partitionsFetchingState->Utils.Dict.dangerouslyGetNonOption(register.id) {
          | Some({isFetching: true}) => Fetching
          | Some({prevFetchedIdempotencyKey: Some(prevFetchedIdempotencyKey)})
            if prevFetchedIdempotencyKey >= register.idempotencyKey =>
            Fetching
          | Some({lockedCount}) if lockedCount > 0 => Locked
          | _ => Available
          }
        },
      ) {
      | ReachedMaxConcurrency
      | ReachedMaxBufferSize
      | NothingToQuery => ()
      | WaitingForNewBlock => await waitForNewBlock()
      | Ready(queries) => {
          let _ =
            await queries
            ->Array.map(async query => {
              switch query {
              | PartitionQuery({partitionId, idempotencyKey})
              | MergeQuery({partitionId, idempotencyKey}) => {
                  let fetchingStateToLock = switch query {
                  | MergeQuery({intoPartitionId}) => Some(getFetchingState(intoPartitionId))
                  | PartitionQuery(_) => None
                  }
                  let fetchingState = getFetchingState(partitionId)

                  sourceManager.fetchingPartitionsCount = sourceManager.fetchingPartitionsCount + 1
                  fetchingState.isFetching = true
                  fetchingStateToLock->Option.forEach(f => f.lockedCount = f.lockedCount + 1)
                  let data = await query->executeQuery
                  sourceManager.fetchingPartitionsCount = sourceManager.fetchingPartitionsCount - 1
                  fetchingState.isFetching = false
                  fetchingState.prevFetchedIdempotencyKey = Some(idempotencyKey)
                  fetchingStateToLock->Option.forEach(f => f.lockedCount = f.lockedCount - 1)
                  data
                }
              }
            })
            ->Promise.all
        }
      }
    }
  }
}
