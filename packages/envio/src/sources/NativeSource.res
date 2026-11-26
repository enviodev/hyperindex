// Every production source is one Rust `NativeSource`: HyperSync for EVM, Fuel
// and SVM, and RPC for EVM. Its answers cross napi as tagged objects whose
// shape is the ReScript type, so nothing here decodes them.

type rpcConfig = {
  url: string,
  sourceFor: Source.sourceFor,
  ws?: string,
  headers?: dict<string>,
  // Rust fills in the defaults of what config.yaml leaves out.
  syncConfig: Config.sourceSyncOptions,
}

type chainSourcesConfig = {
  chainId: int,
  ecosystem: Ecosystem.name,
  // A missing API token fails here, with how to get one.
  hyperSync?: Config.hyperSync,
  rpcs: array<rpcConfig>,
  maxAddressesPerRequest: int,
  userAgent: string,
}

let userAgent = `hyperindex/${Utils.EnvioPackage.value.version}`

@tag("kind")
type heightSubscriptionTarget =
  | HyperSyncSse({url: string, apiToken: string})
  | RpcWs({url: string})

type itemsQuery = {
  fromBlock: int,
  toBlock?: int,
  partitionId: string,
  onEventRegistrationIndexes: array<int>,
  onBlockRegistrationIndexes: array<int>,
  onTransactionRegistrationIndexes: array<int>,
  clientFilteredContracts?: array<string>,
  retry: int,
  reorgableFrom?: int,
  knownHeight: int,
}

@tag("kind")
type heightAnswer =
  | Height({height: int, requestStats: array<Source.requestStat>})
  | Failed({failure: Source.failure, requestStats: array<Source.requestStat>})

@tag("kind")
type itemsAnswer =
  | Fetched({
      page: BufferPage.t,
      latestFetchedBlockNumber: int,
      knownHeight?: int,
      requestStats: array<Source.requestStat>,
    })
  | Failed({failure: Source.failure, requestStats: array<Source.requestStat>})

@tag("kind")
type blockHashesAnswer =
  | Hashes({page: BufferPage.t, requestStats: array<Source.requestStat>})
  | Failed({failure: Source.failure, requestStats: array<Source.requestStat>})

type native = {
  name: string,
  sourceFor: Source.sourceFor,
  pollingInterval: int,
  poweredByHyperSync: bool,
  canReadBlockHashes: bool,
  heightSubscription: Null.t<heightSubscriptionTarget>,
  getHeight: unit => promise<heightAnswer>,
  getItems: (itemsQuery, AddressSet.t, BufferPage.buffer) => promise<itemsAnswer>,
  getBlockHashes: array<int> => promise<blockHashesAnswer>,
  onReorg: unit => unit,
}

@send
external makeChainSourcesRaw: (
  Core.nativeSourceCtor,
  chainSourcesConfig,
  BufferPage.buffer,
  Logger.native,
  array<string>,
) => array<native> = "makeChainSources"

let toSource = (native: native, ~chainId, ~chainBuffer: BufferPage.buffer): Source.t => {
  name: native.name,
  sourceFor: native.sourceFor,
  chainId,
  poweredByHyperSync: native.poweredByHyperSync,
  pollingInterval: native.pollingInterval,
  getHeight: async () =>
    switch await native.getHeight() {
    | Height({height, requestStats}) => {result: Ok(height), requestStats}
    | Failed({failure, requestStats}) => {result: Error(failure), requestStats}
    },
  getItems: async (
    ~fromBlock,
    ~toBlock,
    ~addressSet,
    ~reorgableFrom,
    ~knownHeight,
    ~partitionId,
    ~selection: FetchState.selection,
    ~retry,
  ) => {
    let query = {
      fromBlock,
      toBlock: ?(selection->FetchState.sourceToBlock(~toBlock, ~knownHeight)),
      partitionId,
      onEventRegistrationIndexes: selection.onEventRegistrations->Array.map(reg => reg.index),
      onBlockRegistrationIndexes: selection.onBlockRegistrations->Array.map(reg => reg.index),
      onTransactionRegistrationIndexes: selection.onTransactionRegistrations->Array.map(reg =>
        reg.index
      ),
      clientFilteredContracts: ?selection.clientFilteredContracts,
      retry,
      ?reorgableFrom,
      knownHeight,
    }
    switch await native.getItems(query, addressSet, chainBuffer) {
    | Fetched({page, latestFetchedBlockNumber, ?knownHeight, requestStats}) => {
        result: Ok({page, latestFetchedBlockNumber, knownHeight}),
        requestStats,
      }
    | Failed({failure, requestStats}) => {result: Error(failure), requestStats}
    }
  },
  getBlockHashes: native.canReadBlockHashes
    ? Some(
        async blockNumbers =>
          switch await native.getBlockHashes(blockNumbers) {
          | Hashes({page, requestStats}) => {result: Ok(page), requestStats}
          | Failed({failure, requestStats}) => {result: Error(failure), requestStats}
          },
      )
    : None,
  createHeightSubscription: ?switch native.heightSubscription->Null.toOption {
  | Some(HyperSyncSse({url, apiToken})) =>
    Some(
      (~clock, ~onHeight, ~onStatus) =>
        HyperSyncSSE.subscribe(~clock, ~hyperSyncUrl=url, ~apiToken, ~onHeight, ~onStatus),
    )
  | Some(RpcWs({url})) =>
    Some(
      (~clock, ~onHeight, ~onStatus) =>
        EvmRpcWs.subscribe(~clock, ~wsUrl=url, ~onHeight, ~onStatus),
    )
  | None => None
  },
  onReorg: () => native.onReorg(),
}

let makeChainSources = (
  config: chainSourcesConfig,
  ~chainId,
  ~chainBuffer: BufferPage.buffer,
  ~logger: Logger.t,
): array<Source.t> =>
  Core.getAddon().nativeSource
  ->makeChainSourcesRaw(config, chainBuffer, logger.output.native, logger.boundFieldsJson)
  ->Array.map(native => native->toSource(~chainId, ~chainBuffer))
