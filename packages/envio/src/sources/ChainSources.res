// Sits below `ChainState`/`Persistence` in the module graph so that
// `StartBlockResolver` (called from `Persistence.init`) can build a chain's
// sources without a dependency cycle.
let make = (
  ~chainConfig: Config.chain,
  ~onEventRegistrations: array<Internal.onEventRegistration>,
  ~addressStore: AddressStore.t,
  ~lowercaseAddresses: bool,
): array<Source.t> => {
  let chainId = chainConfig.id
  switch chainConfig.sourceConfig {
  | Config.EvmSourceConfig({hypersync, rpcs}) =>
    let evmRpcs: array<EvmChain.rpc> = rpcs->Array.map((rpc): EvmChain.rpc => {
      let syncConfig = rpc.syncConfig
      let ws = rpc.ws
      let headers = rpc.headers
      {
        url: rpc.url,
        sourceFor: rpc.sourceFor,
        ?syncConfig,
        ?ws,
        ?headers,
      }
    })
    EvmChain.makeSources(
      ~chainId,
      ~onEventRegistrations=onEventRegistrations->(
        Utils.magic: array<Internal.onEventRegistration> => array<Internal.evmOnEventRegistration>
      ),
      ~hyperSync=hypersync,
      ~rpcs=evmRpcs,
      ~lowercaseAddresses,
      ~addressStore,
    )
  | Config.FuelSourceConfig({hypersync}) => [
      FuelHyperSyncSource.make({
        chainId,
        endpointUrl: hypersync,
        apiToken: Env.envioApiToken,
        onEventRegistrations,
        addressStore,
      }),
    ]
  | Config.SvmSourceConfig({hypersync, rpc}) =>
    switch (hypersync, rpc) {
    | (None, None) =>
      JsError.throwWithMessage(`Chain ${chainId->ChainId.toString} has no SVM data source`)
    | (None, Some(rpc)) => [Svm.makeRPCSource(~chainId, ~rpc)]
    | (Some(hypersyncUrl), _) =>
      // HyperSync drives instruction sync. A configured RPC is ignored for now
      // (RPC fallback isn't wired up yet).
      let apiToken = Env.envioApiToken
      [
        SvmHyperSyncSource.make({
          chainId,
          endpointUrl: hypersyncUrl,
          apiToken,
          onEventRegistrations,
          clientTimeoutMillis: Env.hyperSyncClientTimeoutMillis,
          addressStore,
        }),
      ]
    }
  | Config.SimulateSourceConfig({items, endBlock, ?transactionStore, ?blockStore}) => [
      SimulateSource.make(
        ~items,
        ~endBlock,
        ~chainId,
        ~addressStore,
        ~ecosystem=chainConfig.ecosystem,
        ~transactionStore,
        ~blockStore,
      ),
    ]
  // For tests: use ready-to-use sources directly
  | Config.CustomSources(sources) => sources
  }
}
