// Sits below `ChainState`/`Persistence` in the module graph so that
// `StartBlockResolver` (called from `Persistence.prepare`) can build a chain's
// sources without a dependency cycle.

let make = (
  ~chainConfig: Config.chain,
  ~addressStore: AddressStore.t,
  ~chainBuffer: ChainBuffer.t,
  ~logger: Logger.t,
  ~maxAddressesPerRequest: int,
): array<Source.t> => {
  let chainId = chainConfig.id
  let native = (~hyperSync=?, ~rpcs=[]) =>
    NativeSource.makeChainSources(
      {
        chainId: chainId->ChainId.toInt,
        ecosystem: chainConfig.ecosystem,
        ?hyperSync,
        rpcs,
        maxAddressesPerRequest,
        userAgent: NativeSource.userAgent,
      },
      ~chainId,
      ~chainBuffer,
      ~logger,
    )
  switch chainConfig.sourceConfig {
  | Config.EvmSourceConfig({hypersync, rpcs}) =>
    native(
      ~hyperSync=?hypersync,
      ~rpcs=rpcs->Array.map((rpc): NativeSource.rpcConfig => {
        url: rpc.url,
        sourceFor: rpc.sourceFor,
        ws: ?rpc.ws,
        headers: ?rpc.headers,
        syncConfig: rpc.syncConfig,
      }),
    )
  | Config.FuelSourceConfig({hypersync})
  | Config.SvmSourceConfig({hypersync}) =>
    native(~hyperSync=hypersync)
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
