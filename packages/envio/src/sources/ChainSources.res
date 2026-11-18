// Sits below `ChainState`/`Persistence` in the module graph so that
// `StartBlockResolver` (called from `Persistence.init`) can build a chain's
// sources without a dependency cycle.
let make = (
  ~chainConfig: Config.chain,
  ~addressStore: AddressStore.t,
  ~lowercaseAddresses: bool,
  ~chainBuffer: ChainBuffer.t,
  ~logger: Logger.t,
  ~maxAddressesPerRequest: int,
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
      ~hyperSync=hypersync,
      ~rpcs=evmRpcs,
      ~lowercaseAddresses,
      ~chainBuffer,
      ~logger,
      ~maxAddressesPerRequest,
    )
  | Config.FuelSourceConfig({hypersync}) => [
      FuelHyperSyncSource.make({
        chainId,
        endpointUrl: hypersync,
        apiToken: Env.envioApiToken,
        chainBuffer,
        logger,
      }),
    ]
  | Config.SvmSourceConfig({hypersync}) => [
      SvmHyperSyncSource.make({
        chainId,
        endpointUrl: hypersync,
        apiToken: Env.envioApiToken,
        clientTimeoutMillis: Env.hyperSyncClientTimeoutMillis,
        chainBuffer,
      }),
    ]
  | Config.SimulateSourceConfig({items, getBlock, endBlock, ?page}) => [
      SimulateSource.make(
        ~items,
        ~getBlock,
        ~endBlock,
        ~chainId,
        ~addressStore,
        ~ecosystem=chainConfig.ecosystem,
        ~page,
      ),
    ]
  // For tests: use ready-to-use sources directly
  | Config.CustomSources(sources) => sources
  }
}
