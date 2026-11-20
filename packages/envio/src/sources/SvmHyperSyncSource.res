open Source

type options = {
  chainId: ChainId.t,
  endpointUrl: string,
  apiToken: option<string>,
  clientTimeoutMillis: int,
  // The chain's compiled registrations, read by the client while matching.
  chainBuffer: ChainBuffer.t,
}

let make = ({chainId, endpointUrl, apiToken, clientTimeoutMillis, chainBuffer}: options): t => {
  let name = "SvmHyperSync"

  let apiToken = apiToken->HyperSync.requireApiToken

  let client = SvmHyperSyncClient.make(
    ~url=endpointUrl,
    ~apiToken,
    ~httpReqTimeoutMillis=clientTimeoutMillis,
    ~chainBuffer,
  )

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressSet as _,
    ~reorgableFrom,
    ~knownHeight,
    ~partitionId as _,
    ~selection: FetchState.selection,
    ~retry,
    ~logger as _,
  ) => {
    let totalTimeRef = Performance.now()
    let pageFetchRef = Performance.now()

    let fetchStats = () => RequestStat.single(~method="getInstructions", ~sentAt=pageFetchRef)

    let query: SvmHyperSyncClient.Items.query = {
      fromSlot: fromBlock,
      toSlot: selection->FetchState.sourceToBlock(~toBlock, ~knownHeight),
      onEventRegistrationIndexes: selection.onEventRegistrations->Array.map(reg => reg.index),
      onBlockRegistrationIndexes: selection.onBlockRegistrations->Array.map(reg => reg.index),
      ?reorgableFrom,
    }

    let (resp, page) = try await client.getItems(~query) catch {
    | exn =>
      // A rate limit or a replica behind the head is recoverable and has its own
      // backoff and failover, so it must not be buried in a generic retry.
      HyperSync.reraiseIfRecoverable(exn)
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            requestStats: fetchStats(),
            exn,
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: WithBackoff({
              message: `Unexpected issue while fetching instructions from SVM HyperSync. Attempt a retry.`,
              backoffMillis: switch retry {
              | 0 => 500
              | _ => 1000 * retry
              },
            }),
          }),
        ),
      )
    }
    let pageFetchTime = pageFetchRef->Performance.secondsSince
    let requestStats = fetchStats()

    let highestSlot = resp.nextSlot - 1

    let totalTimeElapsed = totalTimeRef->Performance.secondsSince

    {
      // Its slots' (slot, blockhash) pairs also drive reorg detection on merge.
      page,
      latestFetchedBlockNumber: highestSlot,
      stats: {totalTimeElapsed, pageFetchTime},
      knownHeight,
      requestStats,
    }
  }

  // Called through the client rather than passed as a value: the client is a
  // napi class, so a detached method reference loses the instance it belongs to.
  let getBlockHashes = HyperSync.makeGetBlockHashes(~query=(~blockNumbers) =>
    client.getBlockHashes(~blockNumbers)
  )

  {
    name,
    sourceFor: Sync,
    chainId,
    pollingInterval: HyperSync.pollingInterval,
    poweredByHyperSync: true,
    getBlockHashes,
    getHeightOrThrow: async () => {
      let timer = Performance.now()
      let height = await client.getHeight()
      let seconds = timer->Performance.secondsSince
      {height, requestStats: [{method: "getHeight", seconds}]}
    },
    getItemsOrThrow,
    createHeightSubscription: (~clock, ~onHeight, ~onStatus) =>
      HyperSyncSSE.subscribe(~clock, ~hyperSyncUrl=endpointUrl, ~apiToken, ~onHeight, ~onStatus),
  }
}
