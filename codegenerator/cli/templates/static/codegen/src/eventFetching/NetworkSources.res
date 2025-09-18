open Belt

type rpc = {
  url: string,
  sourceFor: Source.sourceFor,
  syncConfig?: InternalConfig.sourceSyncOptions,
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
  | Some(endpointUrl) =>
    switch Env.envioApiToken {
    | Some(apiToken) => [
        HyperSyncSource.make({
          chain,
          contracts,
          endpointUrl,
          allEventSignatures,
          eventRouter,
          shouldUseHypersyncClientDecoder: Env.Configurable.shouldUseHypersyncClientDecoder->Option.getWithDefault(
            shouldUseHypersyncClientDecoder,
          ),
          apiToken,
          clientMaxRetries: Env.hyperSyncClientMaxRetries,
          clientTimeoutMillis: Env.hyperSyncClientTimeoutMillis,
          lowercaseAddresses,
        }),
      ]
    | None => {
        Js.Console.error("HyperSync is configured as a datasource but ENVIO_API_TOKEN is not set.")
        Js.Console.error(
          "Please run 'envio login` to log in, or alternatively add your ENVIO_API_TOKEN to your project .env file.",
        )
        NodeJs.process->NodeJs.exitWithCode(Failure)
        []
      }
    }
  | _ => []
  }
  rpcs->Js.Array2.forEach(({?syncConfig, url, sourceFor}) => {
    let _ = sources->Js.Array2.push(
      RpcSource.make({
        chain,
        sourceFor,
        contracts,
        syncConfig: Config.getSyncConfig(syncConfig->Option.getWithDefault({})),
        url,
        eventRouter,
      }),
    )
  })

  sources
}
