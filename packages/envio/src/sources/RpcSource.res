open Source

type options = {
  sourceFor: Source.sourceFor,
  syncConfig: Config.sourceSync,
  url: string,
  chainId: ChainId.t,
  // The chain's registrations, indexed by their sequential `index`.
  onEventRegistrations: array<Internal.evmOnEventRegistration>,
  lowercaseAddresses: bool,
  // The chain's address index; the client reads it while routing.
  addressStore: AddressStore.t,
  // The chain's stores as they stand. The client reads them to skip a block or
  // transaction another partition already fetched for the same fields; the
  // pages it returns are separate and the caller merges them.
  blockStore: BlockStore.t,
  transactionStore: TransactionStore.t,
  ws?: string,
  headers?: dict<string>,
}

let make = (
  {
    sourceFor,
    syncConfig,
    url,
    chainId,
    onEventRegistrations,
    lowercaseAddresses,
    addressStore,
    blockStore,
    transactionStore,
    ?ws,
    ?headers,
  }: options,
): t => {
  let urlHost = switch Utils.Url.getHostFromUrl(url) {
  | None =>
    JsError.throwWithMessage(
      `The RPC url for chain ${chainId->ChainId.toString} is in incorrect format. The RPC url needs to start with either http:// or https://`,
    )
  | Some(host) => host
  }
  let name = `RPC (${urlHost})`

  let rpcClient = EvmRpcClient.make(
    ~url,
    ~eventRegistrations=HyperSyncClient.Registration.fromOnEventRegistrations(onEventRegistrations),
    ~checksumAddresses=!lowercaseAddresses,
    ~syncConfig,
    ~headers?,
    ~addressStore,
  )

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressSet,
    ~knownHeight,
    ~partitionId,
    ~selection: FetchState.selection,
    ~itemsTarget as _,
    ~retry,
    ~logger as _,
  ) => {
    let totalTimeRef = Performance.now()

    // Always have a toBlock for an RPC worker
    let toBlock = switch toBlock {
    | Some(toBlock) => Pervasives.min(toBlock, knownHeight)
    | None => knownHeight
    }

    if selection.onEventRegistrations->Utils.Array.isEmpty {
      throw(
        Source.GetItemsError(
          UnsupportedSelection({
            message: "Invalid events configuration for the partition. Nothing to fetch. Please, report to the Envio team.",
          }),
        ),
      )
    }

    let pageFetchTimeRef = Performance.now()
    let (result, pageBlockStore, pageTransactionStore) = await rpcClient.getNextPage(
      {
        fromBlock,
        toBlockCeiling: toBlock,
        partitionId,
        registrationIndexes: selection.onEventRegistrations->Array.map(reg => reg.index),
        clientFilteredContracts: selection.clientFilteredContracts,
        retry,
      },
      addressSet,
      blockStore,
      transactionStore,
    )
    let pageFetchTime = pageFetchTimeRef->Performance.secondsSince

    let failedGettingItems = (retry): exn => Source.GetItemsError(
      FailedGettingItems({
        requestStats: result.requestStats,
        // The provider's own message travels as a real error so it still
        // reaches the logs, and so callers have one place to read it from.
        exn: switch result.errorMessage {
        | Some(message) => JsError.make(message)->JsExn.anyToExnInternal
        | None => %raw(`null`)
        },
        attemptedToBlock: result.toBlock,
        retry,
      }),
    )

    let missing = field =>
      JsError.throwWithMessage(
        `The RPC client returned a "${result.kind}" outcome without a ${field}. Please, report to the Envio team.`,
      )

    switch result.kind {
    | "ok" => ()
    | "fieldSelection" =>
      throw(
        Source.GetItemsError(
          FailedGettingFieldSelection({
            requestStats: result.requestStats,
            message: result.message->Option.getOr(
              "Failed getting selected fields. Please double-check your RPC provider returns correct data.",
            ),
            exn: %raw(`null`),
            blockNumber: result.blockNumber->Option.getOr(result.toBlock),
            // The failure is about a field of the block or its transactions,
            // not about one log within it.
            logIndex: 0,
          }),
        ),
      )
    | "suggestedToBlock" =>
      throw(
        failedGettingItems(
          WithSuggestedToBlock({
            toBlock: switch result.retryToBlock {
            | Some(toBlock) => toBlock
            | None => missing("retryToBlock")
            },
          }),
        ),
      )
    | "backoff" =>
      throw(
        failedGettingItems(
          WithBackoff({
            message: result.message->Option.getOr("Retrying the block range."),
            backoffMillis: switch result.backoffMillis {
            | Some(backoffMillis) => backoffMillis
            | None => missing("backoffMillis")
            },
          }),
        ),
      )
    // Anything else is the addon and this module disagreeing, which no retry
    // recovers from.
    | kind =>
      JsError.throwWithMessage(
        `The RPC client returned an unrecognised outcome "${kind}". Please, report to the Envio team.`,
      )
    }

    let parsingTimeRef = Performance.now()
    let parsedQueueItems =
      result.items->EvmEventItem.toInternalItems(~onEventRegistrations, ~chainId)
    let parsingTimeElapsed = parsingTimeRef->Performance.secondsSince

    {
      parsedQueueItems,
      transactionStore: Some(pageTransactionStore),
      // Carries the blocks this range read, its boundary blocks, and every
      // log's own block hash, all assembled on the Rust side.
      blockStore: pageBlockStore,
      latestFetchedBlockNumber: result.toBlock,
      stats: {
        totalTimeElapsed: totalTimeRef->Performance.secondsSince,
        parsingTimeElapsed,
        pageFetchTime,
      },
      knownHeight,
      requestStats: result.requestStats,
    }
  }

  let getBlockHashes = async (~blockNumbers, ~logger as _currentlyUnusedLogger) => {
    let (result, pageBlockStore) = await rpcClient.getBlockHashes(blockNumbers)
    {
      Source.result: switch result.message {
      | None => Ok(pageBlockStore)
      | Some(message) => Error(JsError.make(message)->JsExn.anyToExnInternal)
      },
      requestStats: result.requestStats,
    }
  }

  let createHeightSubscription =
    ws->Option.map(wsUrl =>
      (~onHeight) => RpcWebSocketHeightStream.subscribe(~wsUrl, ~chainId, ~onHeight)
    )

  {
    name,
    sourceFor,
    chainId,
    poweredByHyperSync: false,
    pollingInterval: syncConfig.pollingInterval,
    getBlockHashes,
    onReorg: () => rpcClient.onReorg(),
    getHeightOrThrow: async () => {
      let (height, requestStats) = await rpcClient.getHeight()
      {height, requestStats}
    },
    getItemsOrThrow,
    ?createHeightSubscription,
  }
}
