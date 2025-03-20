open Belt

type rpc = {
  url: string,
  sourceFor: Source.sourceFor,
  syncConfig?: Config.syncConfigOptions,
}

let evm = (
  ~chain,
  ~contracts: array<Internal.evmContractConfig>,
  ~hyperSync,
  ~allEventSignatures,
  ~shouldUseHypersyncClientDecoder,
  ~rpcs: array<rpc>,
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
        shouldUseHypersyncClientDecoder: Env.Configurable.shouldUseHypersyncClientDecoder->Option.getWithDefault(
          shouldUseHypersyncClientDecoder,
        ),
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
        syncConfig: Config.getSyncConfig(syncConfig->Option.getWithDefault({})),
        url,
        eventRouter,
      }),
    )
  })

  sources
}
