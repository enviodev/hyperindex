open Belt

// Ideally the ChainFetcher name suits this better
// But currently the ChainFetcher module is immutable
// and handles both processing and fetching.
// So this module is to encapsulate the fetching logic only
// with a mutable state for easier reasoning and testing.
type t = {
  sources: Utils.Set.t<Source.t>,
  maxPartitionConcurrency: int,
  newBlockFallbackStallTimeout: int,
  stalledPollingInterval: int,
  mutable activeSource: Source.t,
  mutable waitingForNewBlockStateId: option<int>,
  // Should take into consideration partitions fetching for previous states (before rollback)
  mutable fetchingPartitionsCount: int,
}

let getActiveSource = sourceManager => sourceManager.activeSource

let getNextActiveSource = sourceManager => {
  let temp = ref(None)
  sourceManager.sources->Utils.Set.forEach(source => {
    switch source.sourceFor {
    | Sync => temp := Some(source)
    | Fallback if temp.contents->Option.isNone => temp := Some(source)
    | Fallback => ()
    }
  })
  temp.contents
}

let make = (
  ~sources: array<Source.t>,
  ~maxPartitionConcurrency,
  ~newBlockFallbackStallTimeout=20_000,
  ~stalledPollingInterval=5_000,
) => {
  let initialActiveSource = switch sources->Js.Array2.find(source => source.sourceFor === Sync) {
  | None => Js.Exn.raiseError("Invalid configuration, no data-source for historical sync provided")
  | Some(source) => source
  }
  {
    maxPartitionConcurrency,
    sources: Utils.Set.fromArray(sources),
    activeSource: initialActiveSource,
    waitingForNewBlockStateId: None,
    fetchingPartitionsCount: 0,
    newBlockFallbackStallTimeout,
    stalledPollingInterval,
  }
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
  let {maxPartitionConcurrency} = sourceManager

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
      let currentBlockHeight = await waitForNewBlock(~currentBlockHeight)
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

type status = Active | Stalled | Done

let getSourceNewHeight = async (
  ~source: Source.t,
  ~currentBlockHeight,
  ~stalledPollingInterval,
  ~status: ref<status>,
  ~logger,
) => {
  let newHeight = ref(0)
  //Amount the retry interval is multiplied between each retry
  let backOffMultiplicative = 2
  let initalRetryIntervalMillis = 1000
  //Interval after which to retry request (multiplied by backOffMultiplicative between each retry)
  let retryIntervalMillis = ref(initalRetryIntervalMillis)

  while newHeight.contents <= currentBlockHeight && status.contents !== Done {
    try {
      let height = await source.getHeightOrThrow()
      newHeight := height
      if height <= currentBlockHeight {
        // Slowdown polling when the chain isn't progressing
        let delayMilliseconds = if status.contents === Stalled {
          retryIntervalMillis := stalledPollingInterval // Reset possible backOff
          stalledPollingInterval
        } else {
          retryIntervalMillis := initalRetryIntervalMillis // Reset possible backOff
          source.pollingInterval
        }
        await Time.resolvePromiseAfterDelay(~delayMilliseconds)
      }
    } catch {
    | exn =>
      logger->Logging.childTrace({
        "msg": `Height retrieval from ${source.name} source failed. Retrying in ${retryIntervalMillis.contents->Int.toString}ms.`,
        "source": source.name,
        "error": exn->ErrorHandling.prettifyExn,
      })
      await Time.resolvePromiseAfterDelay(
        ~delayMilliseconds=Pervasives.max(
          retryIntervalMillis.contents * backOffMultiplicative,
          60_000,
        ),
      )
    }
  }
  newHeight.contents
}

// Polls for a block height greater than the given block number to ensure a new block is available for indexing.
let waitForNewBlock = async (sourceManager: t, ~currentBlockHeight) => {
  let {stalledPollingInterval, sources} = sourceManager

  let logger = Logging.createChild(
    ~params={
      "chainId": sourceManager.activeSource.chain->ChainMap.Chain.toChainId,
      "currentBlockHeight": currentBlockHeight,
    },
  )
  logger->Logging.childTrace("Initiating check for new blocks.")

  let syncSources = []
  let fallbackSources = []
  sources->Utils.Set.forEach(source => {
    if (
      source.sourceFor === Sync ||
        // Even if the active source is a fallback, still include
        // it to the list. So we don't wait for a timeout again
        // if all main sync sources are still not valid
        source === sourceManager.activeSource
    ) {
      syncSources->Array.push(source)
    } else {
      fallbackSources->Array.push(source)
    }
  })

  let status = ref(Active)

  let (source, newBlockHeight) = await Promise.race(
    syncSources
    ->Array.map(async source => {
      (
        source,
        await getSourceNewHeight(
          ~source,
          ~currentBlockHeight,
          ~status,
          ~logger,
          ~stalledPollingInterval,
        ),
      )
    })
    ->Array.concat([
      Utils.delay(sourceManager.newBlockFallbackStallTimeout)->Promise.then(() => {
        if status.contents !== Done {
          status := Stalled

          switch fallbackSources {
          | [] =>
            logger->Logging.childError(
              `No new blocks detected within ${(sourceManager.newBlockFallbackStallTimeout / 1000)
                  ->Int.toString}s. Polling will continue at a reduced rate. For better reliability, refer to our RPC fallback guide: https://docs.envio.dev/docs/HyperIndex/rpc-sync`,
            )
          | _ =>
            logger->Logging.childWarn(
              `No new blocks detected within ${(sourceManager.newBlockFallbackStallTimeout / 1000)
                  ->Int.toString}s. Continuing polling with fallback RPC sources from the configuration.`,
            )
          }
        }
        // Promise.race will be forever pending if fallbackSources is empty
        // which is good for this use case
        Promise.race(
          fallbackSources->Array.map(async source => {
            (
              source,
              await getSourceNewHeight(
                ~source,
                ~currentBlockHeight,
                ~status,
                ~logger,
                ~stalledPollingInterval,
              ),
            )
          }),
        )
      }),
    ]),
  )

  sourceManager.activeSource = source

  // Show a higher level log if we displayed a warning/error after newBlockFallbackStallTimeout
  let log = status.contents === Stalled ? Logging.childInfo : Logging.childTrace
  logger->log({
    "msg": `New blocks successfully found.`,
    "source": source.name,
    "newBlockHeight": newBlockHeight,
  })

  status := Done

  newBlockHeight
}

let executeQuery = async (sourceManager: t, ~query: FetchState.query, ~currentBlockHeight) => {
  let toBlock = switch query.target {
  | Head => None
  | EndBlock({toBlock})
  | Merge({toBlock}) =>
    Some(toBlock)
  }

  let allAddresses = query.contractAddressMapping->ContractAddressingMap.getAllAddresses
  let addresses =
    allAddresses->Js.Array2.slice(~start=0, ~end_=3)->Array.map(addr => addr->Address.toString)
  let restCount = allAddresses->Array.length - addresses->Array.length
  if restCount > 0 {
    addresses->Js.Array2.push(`... and ${restCount->Int.toString} more`)->ignore
  }

  let responseRef = ref(None)

  while responseRef.contents->Option.isNone {
    let source = sourceManager.activeSource

    let logger = Logging.createChild(
      ~params={
        "chainId": source.chain->ChainMap.Chain.toChainId,
        "logType": "Block Range Query",
        "partitionId": query.partitionId,
        "source": source.name,
        "fromBlock": query.fromBlock,
        "toBlock": toBlock,
        "addresses": addresses,
      },
    )

    try {
      let response = await source.getItemsOrThrow(
        ~fromBlock=query.fromBlock,
        ~toBlock,
        ~contractAddressMapping=query.contractAddressMapping,
        ~partitionId=query.partitionId,
        ~currentBlockHeight,
        ~selection=query.selection,
        ~logger,
      )
      logger->Logging.childTrace({
        "msg": "Fetched block range from server",
        "latestFetchedBlockNumber": response.latestFetchedBlockNumber,
        "numEvents": response.parsedQueueItems->Array.length,
        "stats": response.stats,
      })
      responseRef := Some(response)
    } catch {
    | Source.GetItemsError(error) => {
        // TODO: When we start handling fetch failures,
        // we shouldn't delete the source from the set
        // but keep it for retries. Still need to delete
        // for cases like UnsupportedSelection which are
        // not retryable
        let notAlreadyDeleted = sourceManager.sources->Utils.Set.delete(source)

        // In case there are multiple partitions
        // failing at the same time. Log only once
        if notAlreadyDeleted {
          switch error {
          | UnsupportedSelection({message}) => logger->Logging.childError(message)
          | FailedGettingFieldSelection({message, blockNumber, logIndex})
          | FailedParsingItems({message, blockNumber, logIndex}) =>
            logger->Logging.childError({
              "msg": message,
              "blockNumber": blockNumber,
              "logIndex": logIndex,
            })
          }
        }

        switch sourceManager->getNextActiveSource {
        | None => {
            logger->Logging.childError(
              "The indexer doesn't have data-sources which can continue fetching. Please, check the error logs or reach out to the Envio team.",
            )
            // Hang until the process is terminated
            await Promise.make((_, _) => ())
          }
        | Some(nextSource) => {
            logger->Logging.childInfo({
              "msg": "Switching to another data-source",
              "source": nextSource.name,
            })
            sourceManager.activeSource = nextSource
            // Will loop because of while
          }
        }
      }
    // TODO: Handle more error cases and hang/retry instead of throwing
    | exn => exn->ErrorHandling.mkLogAndRaise(~logger, ~msg="Failed to fetch block Range")
    }
  }

  responseRef.contents->Option.getUnsafe
}
