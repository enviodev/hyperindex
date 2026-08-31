type cfg = {
  url: string,
  httpReqTimeoutMillis?: int,
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
  // The partition's registration selection, by chain-scoped index. Log
  // selections and the routing index are derived on the Rust side from the
  // registrations passed at construction.
  registrationIndexes: array<int>,
  // Contract names to fetch address-free even though their registrations
  // depend on addresses (client-side filtering). None/empty means
  // every address-dependent contract is filtered server-side.
  clientFilteredContracts: option<array<string>>,
  // How many times this query has already been retried, which sets how long a
  // transient miss waits before the next attempt.
  retry: int,
}

// Rust reports what to do about a page it could not read, rather than throwing
// it: `tag` picks which of the two shapes below is populated.
type retryDecision = {
  tag: string,
  toBlock: option<int>,
  message: option<string>,
  backoffMillis: option<int>,
}

// `kind` discriminates the outcome: "ok" carries the page, "retry" carries a
// `retry` decision, and "fieldSelection" reports a selection this provider
// cannot serve. A thrown error from `getNextPage` is a genuine bug, not an
// outcome to recover from.
type nextPageResult = {
  kind: string,
  requestStats: array<Source.requestStat>,
  toBlock: int,
  items: array<EvmEventItem.t>,
  message: option<string>,
  // The block a "fieldSelection" failure happened on.
  blockNumber: option<int>,
  errorMessage: option<string>,
  retry: option<retryDecision>,
}

// `message` is set when the read failed, in which case the page returned
// alongside it is empty.
type blockHashResult = {
  message: option<string>,
  requestStats: array<Source.requestStat>,
}

type t = {
  getHeight: unit => promise<int>,
  // The chain's stores are passed in so a block or transaction another
  // partition already read is not read again; the returned stores are this
  // page's own, to be merged by the caller.
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
  ~headers=?,
  ~eventRegistrations=[],
  ~addressStore,
) =>
  Core.getAddon().evmRpcClient->classNew(
    {
      url,
      ?httpReqTimeoutMillis,
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

// Turn Rust's retry decision into the variant the source manager acts on. The
// client returns exactly these two shapes; anything else is the addon and this
// module disagreeing, which no backoff recovers from.
let toSourceRetry = (decision: retryDecision): Source.getItemsRetry =>
  switch (decision.tag, decision.toBlock, decision.backoffMillis) {
  | ("suggestedToBlock", Some(toBlock), _) => WithSuggestedToBlock({toBlock: toBlock})
  | ("backoff", _, Some(backoffMillis)) =>
    WithBackoff({
      message: decision.message->Option.getOr("Retrying the block range."),
      backoffMillis,
    })
  | (tag, _, _) =>
    JsError.throwWithMessage(
      `The RPC client returned an unrecognised retry decision "${tag}". Please, report to the Envio team.`,
    )
  }
