open Belt

type rpc = {
  url: string,
  sourceFor: Source.sourceFor,
  syncConfig?: Config.sourceSyncOptions,
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
  }: Config.sourceSyncOptions,
): Config.sourceSync => {
  let queryTimeoutMillis = queryTimeoutMillis->Option.getWithDefault(20_000)
  {
    initialBlockInterval: Env.Configurable.SyncConfig.initialBlockInterval->Option.getWithDefault(
      initialBlockInterval->Option.getWithDefault(10_000),
    ),
    // After an RPC error, how much to scale back the number of blocks requested at once
    backoffMultiplicative: Env.Configurable.SyncConfig.backoffMultiplicative->Option.getWithDefault(
      backoffMultiplicative->Option.getWithDefault(0.8),
    ),
    // Without RPC errors or timeouts, how much to increase the number of blocks requested by for the next batch
    accelerationAdditive: Env.Configurable.SyncConfig.accelerationAdditive->Option.getWithDefault(
      accelerationAdditive->Option.getWithDefault(500),
    ),
    // Do not further increase the block interval past this limit
    intervalCeiling: Env.Configurable.SyncConfig.intervalCeiling->Option.getWithDefault(
      intervalCeiling->Option.getWithDefault(10_000),
    ),
    // After an error, how long to wait before retrying
    backoffMillis: backoffMillis->Option.getWithDefault(5000),
    // How long to wait before cancelling an RPC request
    queryTimeoutMillis,
    fallbackStallTimeout: fallbackStallTimeout->Option.getWithDefault(queryTimeoutMillis / 2),
  }
}

let evm = (
  ~chain,
  ~contracts: array<Internal.evmContractConfig>,
  ~hyperSync,
  ~allEventSignatures,
  ~shouldUseHypersyncClientDecoder,
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
        contracts,
        endpointUrl,
        allEventSignatures,
        eventRouter,
        shouldUseHypersyncClientDecoder,
        apiToken: Env.envioApiToken,
        clientMaxRetries: Env.hyperSyncClientMaxRetries,
        clientTimeoutMillis: Env.hyperSyncClientTimeoutMillis,
        lowercaseAddresses,
      }),
    ]
  | _ => []
  }
  rpcs->Js.Array2.forEach(({?syncConfig, url, sourceFor}) => {
    let _ = sources->Js.Array2.push(
      RpcSource.make({
        chain,
        sourceFor,
        contracts,
        syncConfig: getSyncConfig(syncConfig->Option.getWithDefault({})),
        url,
        eventRouter,
        allEventSignatures,
        shouldUseHypersyncClientDecoder,
        lowercaseAddresses,
      }),
    )
  })

  sources
}
