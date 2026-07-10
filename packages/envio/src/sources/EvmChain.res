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
  let queryTimeoutMillis = queryTimeoutMillis->Option.getOr(20_000)
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
    fallbackStallTimeout: fallbackStallTimeout->Option.getOr(queryTimeoutMillis / 2),
    pollingInterval: pollingInterval->Option.getOr(1000),
  }
}

let makeSources = (
  ~chain,
  ~onEventRegistrations: array<Internal.evmOnEventRegistration>,
  ~hyperSync,
  ~rpcs: array<rpc>,
  ~lowercaseAddresses,
) => {
  // The index <-> array-position invariant is what lets sources resolve
  // Rust-routed items back to their registration, so enforce it here where
  // the clients and the lookup array are built (test configs bypass
  // HandlerRegister's assignment).
  let onEventRegistrations = onEventRegistrations->Array.mapWithIndex((reg, i) => {
    ...reg,
    index: i,
  })

  let sources = switch hyperSync {
  | Some(endpointUrl) => [
      HyperSyncSource.make({
        chain,
        endpointUrl,
        onEventRegistrations,
        apiToken: Env.envioApiToken,
        clientTimeoutMillis: Env.hyperSyncClientTimeoutMillis,
        lowercaseAddresses,
        serializationFormat: Env.hypersyncClientSerializationFormat,
        enableQueryCaching: Env.hypersyncClientEnableQueryCaching,
        logLevel: Env.hypersyncLogLevel,
      }),
    ]
  | _ => []
  }
  rpcs->Array.forEach(({?syncConfig, url, sourceFor, ?ws, ?headers}) => {
    let source = RpcSource.make({
      chain,
      sourceFor,
      syncConfig: getSyncConfig(syncConfig->Option.getOr({})),
      url,
      onEventRegistrations,
      lowercaseAddresses,
      ?ws,
      ?headers,
    })
    let _ = sources->Array.push(source)
  })

  sources
}
