type rpc = {
  url: string,
  sourceFor: Source.sourceFor,
  syncConfig?: Config.sourceSyncOptions,
  ws?: string,
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
    // After an RPC error, how much to scale back the number of blocks requested at once
    backoffMultiplicative: Env.Configurable.SyncConfig.backoffMultiplicative->Option.getOr(
      backoffMultiplicative->Option.getOr(0.8),
    ),
    // Without RPC errors or timeouts, how much to increase the number of blocks requested by for the next batch
    accelerationAdditive: Env.Configurable.SyncConfig.accelerationAdditive->Option.getOr(
      accelerationAdditive->Option.getOr(500),
    ),
    // Do not further increase the block interval past this limit
    intervalCeiling: Env.Configurable.SyncConfig.intervalCeiling->Option.getOr(
      intervalCeiling->Option.getOr(10_000),
    ),
    // After an error, how long to wait before retrying
    backoffMillis: backoffMillis->Option.getOr(5000),
    // How long to wait before cancelling an RPC request
    queryTimeoutMillis,
    fallbackStallTimeout: fallbackStallTimeout->Option.getOr(queryTimeoutMillis / 2),
    // How frequently to check for new blocks in realtime (default: 1000ms)
    pollingInterval: pollingInterval->Option.getOr(1000),
  }
}

let makeSources = (
  ~chain,
  ~contracts: array<Internal.evmContractConfig>,
  ~hyperSync,
  ~allEventSignatures,
  ~rpcs: array<rpc>,
  ~lowercaseAddresses,
) => {
  let eventRouter =
    contracts
    ->Belt.Array.flatMap(contract => contract.events)
    ->EventRouter.fromEvmEventModsOrThrow(~chain)

  let sources = switch hyperSync {
  | Some(endpointUrl) => [
      HyperSyncSource.make({
        chain,
        endpointUrl,
        allEventSignatures,
        eventRouter,
        apiToken: Env.envioApiToken,
        clientMaxRetries: Env.hyperSyncClientMaxRetries,
        clientTimeoutMillis: Env.hyperSyncClientTimeoutMillis,
        lowercaseAddresses,
        serializationFormat: Env.hypersyncClientSerializationFormat,
        enableQueryCaching: Env.hypersyncClientEnableQueryCaching,
      }),
    ]
  | _ => []
  }
  rpcs->Array.forEach(({?syncConfig, url, sourceFor, ?ws}) => {
    let source = RpcSource.make({
      chain,
      sourceFor,
      syncConfig: getSyncConfig(syncConfig->Option.getOr({})),
      url,
      eventRouter,
      allEventSignatures,
      lowercaseAddresses,
      ?ws,
    })
    let _ = sources->Array.push(source)
  })

  sources
}
