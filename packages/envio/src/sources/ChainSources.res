// Sits below `ChainState`/`Persistence` in the module graph so that
// `StartBlockResolver` (called from `Persistence.init`) can build a chain's
// sources without a dependency cycle.
let make = (
  ~chainConfig: Config.chain,
  ~onEventRegistrations: array<Internal.onEventRegistration>,
  ~onBlockRegistrations: array<Internal.onBlockRegistration>=[],
  ~onTransactionRegistrations: array<Internal.onTransactionRegistration>=[],
  ~addressStore: AddressStore.t,
  ~lowercaseAddresses: bool,
  ~blockStore: BlockStore.t,
  ~transactionStore: TransactionStore.t,
  ~logger: Logger.t,
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
      ~onBlockRegistrations,
      ~onTransactionRegistrations,
      ~hyperSync=hypersync,
      ~rpcs=evmRpcs,
      ~lowercaseAddresses,
      ~addressStore,
      ~blockStore,
      ~transactionStore,
      ~logger,
    )
  | Config.FuelSourceConfig({hypersync}) => [
      FuelHyperSyncSource.make({
        chainId,
        endpointUrl: hypersync,
        apiToken: Env.envioApiToken,
        onEventRegistrations,
        addressStore,
        logger,
      }),
    ]
  | Config.SvmSourceConfig({hypersync}) => [
      SvmHyperSyncSource.make({
        chainId,
        endpointUrl: hypersync,
        apiToken: Env.envioApiToken,
        onEventRegistrations: onEventRegistrations->(
          Utils.magic: array<Internal.onEventRegistration> => array<Internal.svmOnEventRegistration>
        ),
        onBlockRegistrations,
        clientTimeoutMillis: Env.hyperSyncClientTimeoutMillis,
        addressStore,
      }),
    ]
  | Config.SimulateSourceConfig({items, getBlock, endBlock, ?transactionStore, ?blockStore}) => [
      SimulateSource.make(
        ~items,
        ~getBlock,
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
