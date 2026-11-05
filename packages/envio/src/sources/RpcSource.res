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
): Source.t => {
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

  let decodeItemsPage = (page: NativeSource.page, ~knownHeight): Source.blockRangeFetchResponse => {
    let page = page->(Utils.magic: NativeSource.page => EvmRpcClient.itemsPage)
    let parsingTimeRef = Performance.now()
    let parsedQueueItems =
      page.eventItems
      ->EvmEventItem.toInternalItems(~onEventRegistrations, ~chainId)
      ->Array.concat(page.blockItems->BlockItem.toInternalItems(~onBlockRegistrations))
    let parsingTimeElapsed = parsingTimeRef->Performance.secondsSince
    {
      parsedQueueItems,
      transactionStore: Some(page.transactions),
      blockStore: page.blocks,
      latestFetchedBlockNumber: page.toBlock,
      stats: {
        totalTimeElapsed: page.fetchSeconds +. parsingTimeElapsed,
        parsingTimeElapsed,
        pageFetchTime: page.fetchSeconds,
      },
      knownHeight,
      // Already reported by the source manager.
      requestStats: [],
    }
  }

  {
    name,
    sourceFor,
    chainId,
    poweredByHyperSync: false,
    pollingInterval: syncConfig.pollingInterval,
    implementation: Rust({
      source: rpcClient.source(blockStore, transactionStore, ws->Nullable.fromOption),
      decodeItemsPage,
    }),
  }
}
