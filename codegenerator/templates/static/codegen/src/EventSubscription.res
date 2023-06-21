let startWatchingEventsOnRpc = async (~chainConfig: Config.chainConfig, ~provider) => {
  let traceLogger = Logging.createChild(~params={"chainId": chainConfig.chainId})

  let blockLoader = LazyLoader.make(~loaderFn=EventFetching.getUnwrappedBlock(provider), ())

  let addressInterfaceMapping: Js.Dict.t<Ethers.Interface.t> = Js.Dict.empty()

  let eventFilters = EventFetching.getAllEventFilters(
    ~addressInterfaceMapping,
    ~chainConfig,
    ~provider,
  )

  provider->Ethers.JsonRpcProvider.onBlock(blockNumber => {
    traceLogger->Logging.childTrace({
      "msg": "Querying events on new block",
      "blockNumber": blockNumber,
    })

    EventSyncing.queryEventsWithCombinedFilterAndProcessEventBatch(
      ~addressInterfaceMapping,
      ~eventFilters,
      ~fromBlock=blockNumber,
      ~toBlock=blockNumber,
      ~blockLoader,
      ~provider,
      ~chainConfig,
      ~logger=traceLogger,
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
