// Real sources for tests that talk to a local HyperSync or RPC server.

let chainId = 1

let make = (config: ChainSources.config, ~chainBuffer, ~logger) =>
  ChainSources.fromConfig(
    config,
    ~chainId=chainId->ChainId.fromInt,
    ~chainBuffer,
    ~logger,
  )->Array.getUnsafe(0)

let hyperSync = (
  ~url,
  ~chainBuffer,
  ~ecosystem=Ecosystem.Evm,
  ~apiToken=Some(MockHyperSyncServer.apiToken),
  ~logger=Logger.makeInMemory(),
): Source.t =>
  make(
    {
      chainId,
      ecosystem,
      hyperSync: {
        url,
        apiToken,
        httpReqTimeoutMillis: 10_000,
        serializationFormat: Json,
        enableQueryCaching: false,
        logFilter: "error",
      },
      rpcs: [],
      maxAddressesPerRequest: 5_000,
      userAgent: ChainSources.userAgent,
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
      userAgent: ChainSources.userAgent,
    },
    ~chainBuffer,
    ~logger,
  )
