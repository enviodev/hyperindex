open Source

// Surfaced by the HyperSync client (Rust) when HyperSync rejects the API
// token. The corrupted-token test feeds the real server error (from the query
// endpoint; the edge no longer 401s malformed tokens on /height) through this
// check so it can't silently drift away from what getHeightOrThrow guards on.
let isUnauthorizedError = (message: string) => message->String.includes("401 Unauthorized")

type options = {
  chainId: ChainId.t,
  endpointUrl: string,
  // The chain's registrations, indexed by their sequential `index`.
  onEventRegistrations: array<Internal.evmOnEventRegistration>,
  apiToken: option<string>,
  clientTimeoutMillis: int,
  lowercaseAddresses: bool,
  serializationFormat: HyperSyncClient.serializationFormat,
  enableQueryCaching: bool,
  logLevel: HyperSyncClient.logLevel,
  // The chain's address index; the client reads it while routing.
  addressStore: AddressStore.t,
}

let make = (
  {
    chainId,
    endpointUrl,
    onEventRegistrations,
    apiToken,
    clientTimeoutMillis,
    lowercaseAddresses,
    serializationFormat,
    enableQueryCaching,
    logLevel,
    addressStore,
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
    ~addressStore,
  ) {
  | client => client
  | exception exn =>
    exn->ErrorHandling.mkLogAndRaise(
      ~msg="Failed to instantiate the hypersync client, please double check your ABI",
    )
  }

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressSet,
    ~knownHeight,
    ~partitionId as _,
    ~selection: FetchState.selection,
    ~itemsTarget,
    ~retry,
    ~logger as _,
  ) => {
    let totalTimeRef = Performance.now()

    let startFetchingBatchTimeRef = Performance.now()

    // Every way out of the fetch carries its timing: the request was made,
    // and is billed, whether or not it answered.
    let fetchStats = () => [
      {Source.method: "getLogs", seconds: startFetchingBatchTimeRef->Performance.secondsSince},
    ]

    //fetch batch
    let pageUnsafe = try await HyperSync.GetLogs.query(
      ~client,
      ~fromBlock,
      ~toBlock,
      ~maxNumLogs=itemsTarget,
      ~registrationIndexes=selection.onEventRegistrations->Array.map(reg => reg.index),
      ~addressSet,
      ~clientFilteredContracts=selection.clientFilteredContracts,
    ) catch {
    | HyperSync.GetLogs.Error(WrongInstance) =>
      throw(Source.SourceBehindHead({blockNumber: fromBlock, requestStats: fetchStats()}))
    | HyperSync.GetLogs.Error(UnexpectedMissingParams({missingParams})) =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            requestStats: fetchStats(),
            exn: %raw(`null`),
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: ImpossibleForTheQuery({
              message: `Source returned invalid data with missing required fields: ${missingParams->Array.joinUnsafe(
                  ", ",
                )}`,
            }),
          }),
        ),
      )
    | (Source.RateLimited(_) | Source.SourceBehindHead(_)) as exn => throw(exn)
    | exn =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            requestStats: fetchStats(),
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
    let requestStats = fetchStats()

    //set height and next from block
    let knownHeight = pageUnsafe.archiveHeight

    //The heighest (biggest) blocknumber that was accounted for in
    //Our query. Not necessarily the blocknumber of the last log returned
    //In the query
    let heighestBlockQueried = pageUnsafe.nextBlock - 1

    let parsingTimeRef = Performance.now()

    let parsedQueueItems =
      pageUnsafe.items->EvmEventItem.toInternalItems(~onEventRegistrations, ~chainId)

    let parsingTimeElapsed = parsingTimeRef->Performance.secondsSince

    let totalTimeElapsed = totalTimeRef->Performance.secondsSince

    let stats = {
      totalTimeElapsed,
      parsingTimeElapsed,
      pageFetchTime,
    }

    {
      parsedQueueItems,
      transactionStore: Some(pageUnsafe.transactionStore),
      // The page store also carries the rollbackGuard's blocks (head block and
      // parent of the range's first block), inserted on the Rust side.
      blockStore: pageUnsafe.blockStore,
      latestFetchedBlockNumber: heighestBlockQueried,
      stats,
      knownHeight,
      requestStats,
    }
  }

  // Called through the client rather than passed as a value: the client is a
  // napi class, so a detached method reference loses the instance it belongs to.
  let getBlockHashes = HyperSync.makeGetBlockHashes(
    ~query=(~blockNumbers) => client.getBlockHashes(~blockNumbers),
  )

  {
    name,
    sourceFor: Sync,
    chainId,
    pollingInterval: HyperSync.pollingInterval,
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
    createHeightSubscription: (~onHeight, ~onStatus) =>
      HyperSyncSSE.subscribe(~hyperSyncUrl=endpointUrl, ~apiToken, ~onHeight, ~onStatus),
  }
}
