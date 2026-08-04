open Source

// Surfaced by HyperSyncClient.getHeight (Rust) when HyperSync rejects the API
// token. The corrupted-token test feeds the real server error through this
// check so it can't silently drift away from what getHeightOrThrow guards on.
let isUnauthorizedError = (message: string) => message->String.includes("401 Unauthorized")

type options = {
  chain: ChainMap.Chain.t,
  endpointUrl: string,
  // The chain's registrations, indexed by their sequential `index`.
  onEventRegistrations: array<Internal.evmOnEventRegistration>,
  apiToken: option<string>,
  clientTimeoutMillis: int,
  lowercaseAddresses: bool,
  serializationFormat: HyperSyncClient.serializationFormat,
  enableQueryCaching: bool,
  logLevel: HyperSyncClient.logLevel,
}

let make = (
  {
    chain,
    endpointUrl,
    onEventRegistrations,
    apiToken,
    clientTimeoutMillis,
    lowercaseAddresses,
    serializationFormat,
    enableQueryCaching,
    logLevel,
  }: options,
): t => {
  let name = "HyperSync"

  let apiToken = switch apiToken {
  | Some(token) => token
  | None =>
    JsError.throwWithMessage(`An Envio API token is required for using HyperSync as a data-source.
Set the ENVIO_API_TOKEN environment variable in your .env file.
Learn more or get a free Envio API token at: https://envio.dev/app/api-tokens`)
  }

  let client = switch HyperSyncClient.make(
    ~url=endpointUrl,
    ~apiToken,
    ~httpReqTimeoutMillis=clientTimeoutMillis,
    ~eventRegistrations=HyperSyncClient.Registration.fromOnEventRegistrations(onEventRegistrations),
    ~enableChecksumAddresses=!lowercaseAddresses,
    ~serializationFormat,
    ~enableQueryCaching,
    ~logLevel,
  ) {
  | client => client
  | exception exn =>
    exn->ErrorHandling.mkLogAndRaise(
      ~msg="Failed to instantiate the hypersync client, please double check your ABI",
    )
  }

  let makeEventBatchQueueItem = (
    item: HyperSyncClient.EventItems.item,
    ~onEventRegistration: Internal.evmOnEventRegistration,
  ): Internal.item => {
    let {transactionIndex, logIndex, srcAddress} = item

    Internal.Event({
      onEventRegistration: (onEventRegistration :> Internal.onEventRegistration),
      chain,
      blockNumber: item.blockNumber,
      logIndex,
      transactionIndex,
      // `block` and `transaction` are omitted; they're materialised from the
      // per-chain stores onto the payload at batch prep.
      payload: {
        contractName: onEventRegistration.eventConfig.contractName,
        eventName: onEventRegistration.eventConfig.name,
        chainId: chain->ChainMap.Chain.toChainId,
        params: item.params,
        srcAddress,
        logIndex,
      }->Evm.fromPayload,
    })
  }

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressesByContractName,
    ~contractNameByAddress as _,
    ~knownHeight,
    ~partitionId as _,
    ~selection: FetchState.selection,
    ~itemsTarget,
    ~retry,
    ~logger as _,
  ) => {
    let totalTimeRef = Performance.now()

    let startFetchingBatchTimeRef = Performance.now()

    //fetch batch
    let pageUnsafe = try await HyperSync.GetLogs.query(
      ~client,
      ~fromBlock,
      ~toBlock,
      ~maxNumLogs=itemsTarget,
      ~registrationIndexes=selection.onEventRegistrations->Array.map(reg => reg.index),
      ~addressesByContractName,
    ) catch {
    | HyperSync.GetLogs.Error(error) =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            exn: %raw(`null`),
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: switch error {
            | WrongInstance =>
              let backoffMillis = switch retry {
              | 0 => 100
              | _ => 500 * retry
              }
              WithBackoff({
                message: `Block #${fromBlock->Int.toString} not found in HyperSync. HyperSync has multiple instances and it's possible that they drift independently slightly from the head. Indexing should continue correctly after retrying the query in ${backoffMillis->Int.toString}ms.`,
                backoffMillis,
              })
            | UnexpectedMissingParams({missingParams}) =>
              ImpossibleForTheQuery({
                message: `Source returned invalid data with missing required fields: ${missingParams->Array.joinUnsafe(
                    ", ",
                  )}`,
              })
            },
          }),
        ),
      )
    | Source.RateLimited(_) as exn => throw(exn)
    | exn =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            exn,
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: WithBackoff({
              message: `Unexpected issue while fetching events from HyperSync client. Attempt a retry.`,
              backoffMillis: switch retry {
              | 0 => 500
              | _ => 1000 * retry
              },
            }),
          }),
        ),
      )
    }

    let pageFetchTime = startFetchingBatchTimeRef->Performance.secondsSince
    let requestStats = [{Source.method: "getLogs", seconds: pageFetchTime}]

    //set height and next from block
    let knownHeight = pageUnsafe.archiveHeight

    //The heighest (biggest) blocknumber that was accounted for in
    //Our query. Not necessarily the blocknumber of the last log returned
    //In the query
    let heighestBlockQueried = pageUnsafe.nextBlock - 1

    let parsingTimeRef = Performance.now()

    //Parse page items into queue items
    let parsedQueueItems = []

    // Block headers are returned once per number; items reference them by blockNumber.
    let blocksByNumber = Utils.Map.make()
    pageUnsafe.blocks->Array.forEach(block => {
      blocksByNumber->Utils.Map.set(block.number, block)->ignore
    })
    let getBlock = blockNumber => blocksByNumber->Utils.Map.unsafeGet(blockNumber)

    pageUnsafe.items->Array.forEach(item => {
      let onEventRegistration = onEventRegistrations->Array.getUnsafe(item.onEventRegistrationIndex)
      parsedQueueItems
      ->Array.push(makeEventBatchQueueItem(item, ~onEventRegistration))
      ->ignore
    })

    let parsingTimeElapsed = parsingTimeRef->Performance.secondsSince

    // Best-effort timestamp for the queried-range head: the last item if it
    // happens to be in the range's last block. 0 is a tolerated placeholder
    // otherwise (FetchState already uses 0 in several spots).
    let latestFetchedBlockTimestamp = switch pageUnsafe.items->Array.get(
      pageUnsafe.items->Array.length - 1,
    ) {
    | Some(item) if item.blockNumber == heighestBlockQueried => getBlock(item.blockNumber).timestamp
    | _ => 0
    }

    let totalTimeElapsed = totalTimeRef->Performance.secondsSince

    let stats = {
      totalTimeElapsed,
      parsingTimeElapsed,
      pageFetchTime,
    }

    {
      latestFetchedBlockTimestamp,
      parsedQueueItems,
      transactionStore: Some(pageUnsafe.transactionStore),
      // The page store also carries the rollbackGuard's blocks (head block and
      // parent of the range's first block), inserted on the Rust side.
      blockStore: pageUnsafe.blockStore,
      latestFetchedBlockNumber: heighestBlockQueried,
      stats,
      knownHeight,
      fromBlockQueried: fromBlock,
      requestStats,
    }
  }

  let getBlockHashes = async (~blockNumbers, ~logger as _) => {
    let (result, requestStats) = try {
      let (blockStore, requestStats) = await client.getBlockHashes(~blockNumbers)
      (Ok(blockStore), requestStats)
    } catch {
    | exn => {
        let failure = exn->Source.unpackNativeRequestFailure
        (Error(failure->HyperSync.mapRateLimitedFailure), failure.requestStats)
      }
    }
    {Source.result, requestStats}
  }

  {
    name,
    sourceFor: Sync,
    chain,
    pollingInterval: 100,
    poweredByHyperSync: true,
    getBlockHashes,
    getHeightOrThrow: async () => {
      let timerRef = Performance.now()
      let height = try {
        await client.getHeight()
      } catch {
      | JsExn(e) =>
        switch e->JsExn.message {
        | Some(message) if message->isUnauthorizedError =>
          Logging.error(`Your ENVIO_API_TOKEN was rejected by HyperSync (401 Unauthorized). The indexer will not be able to fetch events. Update the token and try again using 'envio start' or 'envio dev'. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens`)
          // Retrying an unauthorized request can never succeed, so block forever
          let _ = await Promise.make((_, _) => ())
          0
        | _ => throw(JsExn(e))
        }
      }
      let seconds = timerRef->Performance.secondsSince
      {height, requestStats: [{method: "getHeight", seconds}]}
    },
    getItemsOrThrow,
    createHeightSubscription: (~onHeight) =>
      HyperSyncHeightStream.subscribe(
        ~hyperSyncUrl=endpointUrl,
        ~apiToken,
        ~chainId=chain->ChainMap.Chain.toChainId,
        ~onHeight,
      ),
  }
}
