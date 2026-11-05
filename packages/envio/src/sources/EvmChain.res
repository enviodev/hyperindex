type rpc = {
  url: string,
  sourceFor: Source.sourceFor,
  syncConfig?: Config.sourceSyncOptions,
  ws?: string,
  headers?: dict<string>,
}

let getSyncConfig = (
  {
    ?initialBlockInterval,
    ?backoffMultiplicative,
    ?accelerationAdditive,
    ?intervalCeiling,
    ?backoffMillis,
    ?queryTimeoutMillis,
    ?fallbackStallTimeout,
    ?pollingInterval,
  }: Config.sourceSyncOptions,
): Config.sourceSync => {
  // A backfill page can span thousands of blocks, so a slow answer is still
  // worth waiting for. Near the head a read covers a block or a few, and a
  // provider that hasn't answered in 10s is better retried. A configured
  // timeout applies to both.
  let (queryTimeoutMillis, headQueryTimeoutMillis) = switch queryTimeoutMillis {
  | Some(queryTimeoutMillis) => (queryTimeoutMillis, queryTimeoutMillis)
  | None => (30_000, 10_000)
  }
  {
    initialBlockInterval: Env.Configurable.SyncConfig.initialBlockInterval->Option.getOr(
      initialBlockInterval->Option.getOr(10_000),
    ),
    backoffMultiplicative: Env.Configurable.SyncConfig.backoffMultiplicative->Option.getOr(
      backoffMultiplicative->Option.getOr(0.8),
    ),
    accelerationAdditive: Env.Configurable.SyncConfig.accelerationAdditive->Option.getOr(
      accelerationAdditive->Option.getOr(500),
    ),
    intervalCeiling: Env.Configurable.SyncConfig.intervalCeiling->Option.getOr(
      intervalCeiling->Option.getOr(10_000),
    ),
    backoffMillis: backoffMillis->Option.getOr(2000),
    queryTimeoutMillis,
    headQueryTimeoutMillis,
    fallbackStallTimeout: fallbackStallTimeout->Option.getOr(queryTimeoutMillis / 2),
    pollingInterval: pollingInterval->Option.getOr(1000),
  }
}

let makeSources = (
  ~chainId,
  ~onEventRegistrations: array<Internal.evmOnEventRegistration>,
  ~onBlockRegistrations,
  ~hyperSync,
  ~rpcs: array<rpc>,
  ~lowercaseAddresses,
  ~addressStore,
  ~blockStore,
  ~transactionStore,
  ~logger,
  ~maxAddressesPerRequest,
) => {
  let sources = switch hyperSync {
  | Some(endpointUrl) => [
      EvmHyperSyncSource.make({
        chainId,
        endpointUrl,
        onEventRegistrations,
        onBlockRegistrations,
        apiToken: Env.envioApiToken,
        clientTimeoutMillis: Env.hyperSyncClientTimeoutMillis,
        lowercaseAddresses,
        serializationFormat: Env.hypersyncClientSerializationFormat,
        enableQueryCaching: Env.hypersyncClientEnableQueryCaching,
        logLevel: Env.hypersyncLogLevel,
        addressStore,
        logger,
      }),
    ]
  | _ => []
  }
  rpcs->Array.forEach(({?syncConfig, url, sourceFor, ?ws, ?headers}) => {
    let source = RpcSource.make({
      chainId,
      sourceFor,
      syncConfig: getSyncConfig(syncConfig->Option.getOr({})),
      url,
      onEventRegistrations,
      onBlockRegistrations,
      lowercaseAddresses,
      addressStore,
      blockStore,
      transactionStore,
      ?ws,
      ?headers,
      maxAddressesPerRequest,
      logger,
    })
    let _ = sources->Array.push(source)
  })

  sources
}
