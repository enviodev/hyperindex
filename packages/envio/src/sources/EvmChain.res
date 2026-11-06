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
  // RPC's block range already shrinks after a timeout, so waiting longer than
  // 30s on a backfill read mostly delays that.
  let {nearHeadMillis, backfillMillis} = Source.makeRequestTimeouts(
    ~configuredMillis=queryTimeoutMillis,
    ~backfillMillis=30_000,
  )
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
    queryTimeoutMillis: backfillMillis,
    nearHeadQueryTimeoutMillis: nearHeadMillis,
    fallbackStallTimeout: fallbackStallTimeout->Option.getOr(backfillMillis / 2),
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
        requestTimeouts: Source.makeRequestTimeouts(
          ~configuredMillis=Env.hyperSyncClientTimeoutMillis,
          ~backfillMillis=Source.hyperSyncBackfillTimeoutMillis,
        ),
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
