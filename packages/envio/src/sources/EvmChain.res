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
    backoffMillis: backoffMillis->Option.getOr(5000),
    queryTimeoutMillis,
    fallbackStallTimeout: fallbackStallTimeout->Option.getOr(queryTimeoutMillis / 2),
    pollingInterval: pollingInterval->Option.getOr(1000),
  }
}

let collectEventParams = (contracts: array<Internal.evmContractConfig>): array<
  HyperSyncClient.Decoder.eventParamsInput,
> => {
  let result = []
  contracts->Array.forEach(contract => {
    contract.events->Array.forEach(event => {
      result
      ->Array.push({
        HyperSyncClient.Decoder.sighash: event.sighash,
        topicCount: event.topicCount,
        eventName: event.name,
        contractName: contract.name,
        params: event.paramsMetadata,
      })
      ->ignore
    })
  })
  result
}

let makeSources = (
  ~chain,
  ~contracts: array<Internal.evmContractConfig>,
  ~hyperSync,
  ~rpcs: array<rpc>,
  ~lowercaseAddresses,
) => {
  let eventRouter =
    contracts
    ->Array.flatMap(contract => contract.events)
    ->EventRouter.fromEvmEventModsOrThrow(~chain)

  let allEventParams = collectEventParams(contracts)

  let sources = switch hyperSync {
  | Some(endpointUrl) => [
      HyperSyncSource.make({
        chain,
        endpointUrl,
        allEventParams,
        eventRouter,
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
      eventRouter,
      allEventParams,
      lowercaseAddresses,
      ?ws,
      ?headers,
    })
    let _ = sources->Array.push(source)
  })

  sources
}
