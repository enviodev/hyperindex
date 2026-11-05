type options = {
  chainId: ChainId.t,
  endpointUrl: string,
  // The chain's registrations, indexed by their sequential `index`.
  onEventRegistrations: array<Internal.evmOnEventRegistration>,
  onBlockRegistrations?: array<Internal.onBlockRegistration>,
  apiToken: option<string>,
  clientTimeoutMillis: int,
  lowercaseAddresses: bool,
  serializationFormat: HyperSyncClient.serializationFormat,
  enableQueryCaching: bool,
  logLevel: HyperSyncClient.logLevel,
  // The chain's address index; the client reads it while routing.
  addressStore: AddressStore.t,
  logger: Logger.t,
}

let make = (
  {
    chainId,
    endpointUrl,
    onEventRegistrations,
    ?onBlockRegistrations,
    apiToken,
    clientTimeoutMillis,
    lowercaseAddresses,
    serializationFormat,
    enableQueryCaching,
    logLevel,
    addressStore,
    logger,
  }: options,
): Source.t => {
  let onBlockRegistrations = onBlockRegistrations->Option.getOr([])

  let apiToken = apiToken->HyperSync.requireApiToken

  let client = switch HyperSyncClient.make(
    ~url=endpointUrl,
    ~apiToken,
    ~httpReqTimeoutMillis=clientTimeoutMillis,
    ~eventRegistrations=HyperSyncClient.Registration.fromOnEventRegistrations(onEventRegistrations),
    ~onBlockRegistrations,
    ~enableChecksumAddresses=!lowercaseAddresses,
    ~serializationFormat,
    ~enableQueryCaching,
    ~logLevel,
    ~addressStore,
  ) {
  | client => client
  | exception exn =>
    exn->ErrorHandling.mkLogAndRaise(
      ~logger,
      ~msg="Failed to instantiate the hypersync client, please double check your ABI",
    )
  }

  let decodeItemsPage = (
    page: NativeSource.page,
    ~knownHeight as _,
  ): Source.blockRangeFetchResponse => {
    let page = page->(Utils.magic: NativeSource.page => HyperSyncClient.itemsPage)
    let parsingTimeRef = Performance.now()
    let parsedQueueItems =
      page.eventItems
      ->EvmEventItem.toInternalItems(~onEventRegistrations, ~chainId)
      ->Array.concat(page.blockItems->BlockItem.toInternalItems(~onBlockRegistrations))
    let parsingTimeElapsed = parsingTimeRef->Performance.secondsSince
    {
      parsedQueueItems,
      transactionStore: Some(page.transactions),
      // The page store also carries the rollbackGuard's blocks (head block and
      // parent of the range's first block), inserted on the Rust side.
      blockStore: page.blocks,
      latestFetchedBlockNumber: page.toBlock,
      stats: {
        totalTimeElapsed: page.fetchSeconds +. parsingTimeElapsed,
        parsingTimeElapsed,
        pageFetchTime: page.fetchSeconds,
      },
      knownHeight: page.knownHeight,
      // Already reported by the source manager.
      requestStats: [],
    }
  }

  {
    name: "HyperSync",
    sourceFor: Sync,
    chainId,
    pollingInterval: HyperSync.pollingInterval,
    poweredByHyperSync: true,
    implementation: Rust({
      source: client.source(endpointUrl, apiToken, HyperSyncClient.userAgent()),
      decodeItemsPage,
    }),
  }
}
