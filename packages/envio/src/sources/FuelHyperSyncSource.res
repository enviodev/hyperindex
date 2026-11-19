open Source

type options = {
  chainId: ChainId.t,
  endpointUrl: string,
  apiToken: option<string>,
  // The chain's compiled registrations, read by the client while matching.
  chainBuffer: ChainBuffer.t,
  logger: Logger.t,
}

let make = ({chainId, endpointUrl, apiToken, chainBuffer, logger}: options): t => {
  let name = "HyperFuel"

  // Per source, so one rejected token is reported once rather than on every
  // height retry for the life of the process.
  let unauthorizedWarned = ref(false)
  let apiToken = apiToken->HyperSync.requireApiToken

  let client = switch FuelHyperSyncClient.make({url: endpointUrl, apiToken}, ~chainBuffer) {
  | client => client
  | exception exn =>
    exn->ErrorHandling.mkLogAndRaise(~logger, ~msg="Failed to instantiate the HyperFuel client")
  }

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressSet,
    ~reorgableFrom as _,
    ~knownHeight,
    ~partitionId as _,
    ~selection: FetchState.selection,
    ~itemsTarget as _,
    ~retry,
    ~logger as _,
  ) => {
    let totalTimeRef = Performance.now()

    let startFetchingBatchTimeRef = Performance.now()

    let fetchStats = () => RequestStat.single(~method="getLogs", ~sentAt=startFetchingBatchTimeRef)

    //fetch batch
    let pageUnsafe = try await FuelHyperSync.GetLogs.query(
      ~client,
      ~fromBlock,
      ~toBlock,
      ~registrationIndexes=selection.onEventRegistrations->Array.map(reg => reg.index),
      ~addressSet,
      ~clientFilteredContracts=selection.clientFilteredContracts,
    ) catch {
    | FuelHyperSync.GetLogs.Error(WrongInstance) =>
      throw(Source.SourceBehindHead({blockNumber: fromBlock, requestStats: fetchStats()}))
    | FuelHyperSync.GetLogs.Error(UnexpectedMissingParams({missingParams})) =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            requestStats: fetchStats(),
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: ImpossibleForTheQuery({
              message: `Source returned invalid data with missing required fields: ${missingParams->Array.joinUnsafe(
                  ", ",
                )}`,
            }),
          }),
        ),
      )
    | exn =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            requestStats: fetchStats(),
            exn,
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: WithBackoff({
              message: `Unexpected issue while fetching events from HyperFuel client. Attempt a retry.`,
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

    let totalTimeElapsed = totalTimeRef->Performance.secondsSince

    let stats = {
      totalTimeElapsed,
      pageFetchTime,
    }

    {
      // Fuel keeps the transaction inline on the item; the page's blocks drive
      // reorg detection (Fuel never rolls back, so it's detect-only logging).
      page: pageUnsafe.page,
      latestFetchedBlockNumber: heighestBlockQueried,
      stats,
      knownHeight,
      requestStats,
    }
  }

  let getBlockHashes = (~blockNumbers as _, ~logger as _) =>
    JsError.throwWithMessage("HyperFuel does not support getting block hashes")

  {
    name,
    sourceFor: Sync,
    chainId,
    getBlockHashes,
    pollingInterval: HyperSync.pollingInterval,
    poweredByHyperSync: true,
    getHeightOrThrow: async () => {
      let timerRef = Performance.now()
      let height = try await client->FuelHyperSyncClient.getHeight catch {
      | exn =>
        exn->HyperSync.rethrowLoggingUnauthorized(
          ~logger,
          ~warned=unauthorizedWarned,
          ~product="HyperFuel",
        )
      }
      let seconds = timerRef->Performance.secondsSince
      {height, requestStats: [{method: "getHeight", seconds}]}
    },
    getItemsOrThrow,
  }
}
