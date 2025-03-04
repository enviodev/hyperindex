open Belt

type rpc = {
  sourceFor: Source.sourceFor,
  syncConfig: Config.syncConfig,
  // FIXME: Instead of multiple urls we should have different rpc sources
  urls: array<string>,
}

let evm = (
  ~chain,
  ~contracts: array<Config.contract>,
  ~hyperSync,
  ~allEventSignatures,
  ~shouldUseHypersyncClientDecoder,
  ~rpcs: array<rpc>,
) => {
  let eventRouter =
    contracts
    ->Belt.Array.flatMap(contract => contract.events)
    ->EventRouter.fromEvmEventModsOrThrow(~chain)

  let isRpcSync = rpcs->Js.Array2.some(rpc => rpc.sourceFor === Sync)

  let sources = switch hyperSync {
  | Some(endpointUrl) if !isRpcSync => [
      HyperSyncSource.make({
        chain,
        contracts,
        endpointUrl,
        allEventSignatures,
        eventRouter,
        shouldUseHypersyncClientDecoder: Env.Configurable.shouldUseHypersyncClientDecoder->Option.getWithDefault(
          shouldUseHypersyncClientDecoder,
        ),
      }),
    ]
  | _ => []
  }
  rpcs->Js.Array2.forEach(({syncConfig, urls, sourceFor}) => {
    let _ = sources->Js.Array2.push(
      RpcSource.make({
        chain,
        sourceFor,
        contracts,
        syncConfig: {
          initialBlockInterval: Env.Configurable.SyncConfig.initialBlockInterval->Option.getWithDefault(
            syncConfig.initialBlockInterval,
          ),
          // After an RPC error, how much to scale back the number of blocks requested at once
          backoffMultiplicative: Env.Configurable.SyncConfig.backoffMultiplicative->Option.getWithDefault(
            syncConfig.backoffMultiplicative,
          ),
          // Without RPC errors or timeouts, how much to increase the number of blocks requested by for the next batch
          accelerationAdditive: Env.Configurable.SyncConfig.accelerationAdditive->Option.getWithDefault(
            syncConfig.accelerationAdditive,
          ),
          // Do not further increase the block interval past this limit
          intervalCeiling: Env.Configurable.SyncConfig.intervalCeiling->Option.getWithDefault(
            syncConfig.intervalCeiling,
          ),
          // After an error, how long to wait before retrying
          backoffMillis: syncConfig.backoffMillis,
          // How long to wait before cancelling an RPC request
          queryTimeoutMillis: syncConfig.queryTimeoutMillis,
          fallbackStallTimeout: syncConfig.fallbackStallTimeout,
        },
        urls,
        eventRouter,
      }),
    )
  })

  sources
}
