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

let collectEventParams = (onEventRegistrations: array<Internal.evmOnEventRegistration>): array<
  HyperSyncClient.Decoder.eventParamsInput,
> => {
  let result = []
  onEventRegistrations->Array.forEach(reg => {
    let event = reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)
    result
    ->Array.push({
      HyperSyncClient.Decoder.id: reg.id,
      sighash: event.sighash,
      topicCount: event.topicCount,
      eventName: event.name,
      contractName: event.contractName,
      isWildcard: reg.isWildcard,
      params: event.paramsMetadata,
    })
    ->ignore
  })
  result
}

let makeSources = (
  ~chain,
  ~onEventRegistrations: array<Internal.evmOnEventRegistration>,
  ~hyperSync,
  ~rpcs: array<rpc>,
  ~lowercaseAddresses,
) => {
  // The id <-> array-index invariant is what lets sources resolve Rust-routed
  // items back to their registration, so enforce it here where the clients and
  // the lookup array are built (test configs bypass HandlerRegister's
  // assignment).
  let onEventRegistrations = onEventRegistrations->Array.mapWithIndex((reg, i) => {
    ...reg,
    id: i,
  })

  let allEventParams = collectEventParams(onEventRegistrations)

  let sources = switch hyperSync {
  | Some(endpointUrl) => [
      HyperSyncSource.make({
        chain,
        endpointUrl,
        allEventParams,
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
      allEventParams,
      lowercaseAddresses,
      ?ws,
      ?headers,
    })
    let _ = sources->Array.push(source)
  })

  sources
}
