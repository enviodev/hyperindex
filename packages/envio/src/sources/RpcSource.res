open Source

type options = {
  sourceFor: Source.sourceFor,
  syncConfig: Config.sourceSync,
  url: string,
  chainId: ChainId.t,
  // The chain's registrations, indexed by their sequential `index`.
  onEventRegistrations: array<Internal.evmOnEventRegistration>,
  onBlockRegistrations?: array<Internal.onBlockRegistration>,
  lowercaseAddresses: bool,
  // The chain's address index; the client reads it while routing.
  addressStore: AddressStore.t,
  // Read by the client while planning; the pages it returns are separate, and
  // the caller merges them.
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
    ?onBlockRegistrations,
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
  let onBlockRegistrations = onBlockRegistrations->Option.getOr([])

  let rpcClient = EvmRpcClient.make(
    ~url,
    ~eventRegistrations=HyperSyncClient.Registration.fromOnEventRegistrations(onEventRegistrations),
    ~onBlockRegistrations,
    ~checksumAddresses=!lowercaseAddresses,
    ~syncConfig,
    ~headers?,
    ~addressStore,
  )

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressSet,
    ~reorgableFrom,
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

    if (
      selection.onEventRegistrations->Utils.Array.isEmpty &&
        selection.onBlockRegistrations->Utils.Array.isEmpty
    ) {
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
        onEventRegistrationIndexes: selection.onEventRegistrations->Array.map(reg => reg.index),
        onBlockRegistrationIndexes: selection.onBlockRegistrations->Array.map(reg => reg.index),
        clientFilteredContracts: selection.clientFilteredContracts,
        retry,
        ?reorgableFrom,
      },
      addressSet,
      blockStore,
      transactionStore,
    )
    let pageFetchTime = pageFetchTimeRef->Performance.secondsSince

    // The cause travels as a real error so it reaches the logs the way every
    // other source's does. Absent where the message is the whole story.
    let exn =
      result.providerMessage->Option.map(message => JsError.make(message)->JsExn.anyToExnInternal)

    let failedGettingItems = (decision): exn => Source.GetItemsError(
      FailedGettingItems({
        requestStats: result.requestStats,
        ?exn,
        attemptedToBlock: result.toBlock,
        retry: decision,
      }),
    )

    let missing = field =>
      JsError.throwWithMessage(
        `The RPC client returned a "${(result.kind :> string)}" outcome without a ${field}. Please, report to the Envio team.`,
      )

    switch result.kind {
    | Ok => ()
    | FieldSelection =>
      throw(
        Source.GetItemsError(
          FailedGettingFieldSelection({
            requestStats: result.requestStats,
            message: switch result.message {
            | Some(message) => message
            | None => missing("message")
            },
            ?exn,
            blockNumber: switch result.blockNumber {
            | Some(blockNumber) => blockNumber
            | None => missing("blockNumber")
            },
          }),
        ),
      )
    | BehindHead =>
      throw(
        Source.SourceBehindHead({
          blockNumber: switch result.blockNumber {
          | Some(blockNumber) => blockNumber
          | None => missing("blockNumber")
          },
          requestStats: result.requestStats,
        }),
      )
    | SuggestedToBlock =>
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
    | Unavailable =>
      throw(
        failedGettingItems(
          ImpossibleForTheQuery({
            message: switch result.message {
            | Some(message) => message
            | None => missing("message")
            },
          }),
        ),
      )
    | Backoff =>
      throw(
        failedGettingItems(
          WithBackoff({
            message: switch result.message {
            | Some(message) => message
            | None => missing("message")
            },
            backoffMillis: switch result.backoffMillis {
            | Some(backoffMillis) => backoffMillis
            | None => missing("backoffMillis")
            },
          }),
        ),
      )
    }

    let parsingTimeRef = Performance.now()
    let parsedQueueItems =
      result.eventItems
      ->EvmEventItem.toInternalItems(~onEventRegistrations, ~chainId)
      ->Array.concat(result.blockItems->BlockItem.toInternalItems(~onBlockRegistrations))
    let parsingTimeElapsed = parsingTimeRef->Performance.secondsSince

    {
      parsedQueueItems,
      transactionStore: Some(pageTransactionStore),
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

  let getBlockHashes = async (~blockNumbers, ~logger as _) => {
    let (result, pageBlockStore) = await rpcClient.getBlockHashes(blockNumbers)
    {
      Source.result: switch (result.message, result.behindHeadBlock) {
      | (None, _) => Ok(pageBlockStore)
      | (Some(_), Some(blockNumber)) =>
        Error(Source.SourceBehindHead({blockNumber, requestStats: result.requestStats}))
      | (Some(message), None) => Error(JsError.make(message)->JsExn.anyToExnInternal)
      },
      requestStats: result.requestStats,
    }
  }

  let createHeightSubscription =
    ws->Option.map(wsUrl =>
      (~onHeight, ~onStatus) => EvmRpcWs.subscribe(~wsUrl, ~onHeight, ~onStatus)
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
