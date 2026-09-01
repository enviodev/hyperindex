type cfg = {
  url: string,
  httpReqTimeoutMillis?: int,
  maxConcurrentRequests?: int,
  headers?: dict<string>,
  initialBlockInterval: int,
  backoffMultiplicative: float,
  accelerationAdditive: int,
  intervalCeiling: int,
  backoffMillis: int,
  queryTimeoutMillis: int,
}

type nextPageParams = {
  fromBlock: int,
  toBlockCeiling: int,
  partitionId: string,
  registrationIndexes: array<int>,
  clientFilteredContracts: option<array<string>>,
  retry: int,
}

// Rust reports what to do about a page it could not read rather than throwing
// it; see `NextPageResult` in `evm_rpc_source/mod.rs` for which fields each
// `kind` populates. A thrown error from `getNextPage` is a genuine bug, not an
// outcome to recover from.
type nextPageResult = {
  kind: string,
  requestStats: array<Source.requestStat>,
  toBlock: int,
  items: array<EvmEventItem.t>,
  message: option<string>,
  providerMessage: option<string>,
  blockNumber: option<int>,
  retryToBlock: option<int>,
  backoffMillis: option<int>,
}

// `message` is set when the read failed, in which case the page returned
// alongside it is empty.
type blockHashResult = {
  message: option<string>,
  requestStats: array<Source.requestStat>,
}

type t = {
  getHeight: unit => promise<(int, array<Source.requestStat>)>,
  // The stores it returns are this page's own, for the caller to merge.
  getNextPage: (
    nextPageParams,
    AddressSet.t,
    BlockStore.t,
    TransactionStore.t,
  ) => promise<(nextPageResult, BlockStore.t, TransactionStore.t)>,
  getBlockHashes: array<int> => promise<(blockHashResult, BlockStore.t)>,
  onReorg: unit => unit,
}

@send
external classNew: (
  Core.evmRpcClientCtor,
  cfg,
  array<HyperSyncClient.Registration.input>,
  ~checksumAddresses: bool,
  ~addressStore: AddressStore.t,
) => t = "new"

let make = (
  ~url,
  ~checksumAddresses,
  ~syncConfig: Config.sourceSync,
  ~httpReqTimeoutMillis=?,
  ~maxConcurrentRequests=?,
  ~headers=?,
  ~eventRegistrations=[],
  ~addressStore,
) =>
  Core.getAddon().evmRpcClient->classNew(
    {
      url,
      ?httpReqTimeoutMillis,
      ?maxConcurrentRequests,
      ?headers,
      initialBlockInterval: syncConfig.initialBlockInterval,
      backoffMultiplicative: syncConfig.backoffMultiplicative,
      accelerationAdditive: syncConfig.accelerationAdditive,
      intervalCeiling: syncConfig.intervalCeiling,
      backoffMillis: syncConfig.backoffMillis,
      queryTimeoutMillis: syncConfig.queryTimeoutMillis,
    },
    eventRegistrations,
    ~checksumAddresses,
    ~addressStore,
  )
