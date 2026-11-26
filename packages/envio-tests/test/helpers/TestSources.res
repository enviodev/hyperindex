// Real native sources for tests that talk to a local HyperSync or RPC server.

let chainId = 1

let make = (config: NativeSource.chainSourcesConfig, ~chainBuffer, ~logger) =>
  NativeSource.makeChainSources(
    config,
    ~chainId=chainId->ChainId.fromInt,
    ~chainBuffer,
    ~logger,
  )->Array.getUnsafe(0)

let hyperSync = (
  ~url,
  ~chainBuffer,
  ~ecosystem=Ecosystem.Evm,
  ~logger=Logger.makeInMemory(),
): Source.t =>
  make(
    {
      chainId,
      ecosystem,
      hyperSync: {
        url,
        apiToken: Some(MockHyperSyncServer.apiToken),
        httpReqTimeoutMillis: 10_000,
        serializationFormat: Json,
        enableQueryCaching: false,
        logFilter: "error",
      },
      rpcs: [],
      maxAddressesPerRequest: 5_000,
      userAgent: NativeSource.userAgent,
    },
    ~chainBuffer,
    ~logger,
  )

let rpc = (
  ~url,
  ~chainBuffer,
  ~syncConfig: Config.sourceSyncOptions={},
  ~headers=?,
  ~ws=?,
  ~maxAddressesPerRequest=5_000,
  ~logger=Logger.makeInMemory(),
): Source.t =>
  make(
    {
      chainId,
      ecosystem: Evm,
      rpcs: [{url, sourceFor: Sync, ?headers, ?ws, syncConfig}],
      maxAddressesPerRequest,
      userAgent: NativeSource.userAgent,
    },
    ~chainBuffer,
    ~logger,
  )
