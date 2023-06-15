let startWatchingEventsOnRpc = async (~chainConfig: Config.chainConfig, ~provider) => {
  let blockLoader = LazyLoader.make(~loaderFn=EventFetching.getUnwrappedBlock(provider), ())

  let addressInterfaceMapping: Js.Dict.t<Ethers.Interface.t> = Js.Dict.empty()

  let eventFilters = EventFetching.getAllEventFilters(
    ~addressInterfaceMapping,
    ~chainConfig,
    ~provider,
  )

  provider->Ethers.JsonRpcProvider.onBlock(blockNumber => {
    Js.log2("Querying events on new block: ", blockNumber)

    EventSyncing.queryEventsWithCombinedFilterAndProcessEventBatch(
      ~addressInterfaceMapping,
      ~eventFilters,
      ~fromBlock=blockNumber,
      ~toBlock=blockNumber,
      ~blockLoader,
      ~provider,
      ~chainConfig,
    )
    ->Promise.thenResolve(_ => ())
    ->ignore
  })
}

let startWatchingEvents = () => {
  Config.config
  ->Js.Dict.values
  ->Belt.Array.map(chainConfig => {
    startWatchingEventsOnRpc(~chainConfig, ~provider=chainConfig.provider)
  })
  ->Promise.all
}
