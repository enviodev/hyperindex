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

// Only logs that resolved to a registration cross the boundary, each carrying
// its registration's chain-scoped index. Block and transaction data stay in
// the Rust-built store pages returned alongside the items.
type eventItem = {
  logIndex: int,
  srcAddress: Address.t,
  blockNumber: int,
  transactionIndex: int,
  onEventRegistrationIndex: int,
  params: Internal.eventParams,
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
}

type nextPageResponse = {
  items: array<eventItem>,
  toBlock: int,
  requestStats: array<Source.requestStat>,
  missing: Source.missingStoreData,
}

type fetchStoreDataResponse = {
  missing: Source.missingStoreData,
  requestStats: array<Source.requestStat>,
}

// The caller provides a range; Rust decides the actual `toBlock` and returns
// it, together with the page's transaction and block store pages.
type t = {
  getHeight: unit => promise<int>,
  getNextPage: (
    nextPageParams,
    AddressSet.t,
  ) => promise<(nextPageResponse, TransactionStore.t, BlockStore.t)>,
  fetchStoreData: Source.missingStoreData => promise<(
    fetchStoreDataResponse,
    TransactionStore.t,
    BlockStore.t,
  )>,
  getBlockHashes: array<int> => promise<(BlockStore.t, array<Source.requestStat>)>,
}

@send
external classNew: (
  Core.evmRpcClientCtor,
  cfg,
  array<HyperSyncClient.Registration.input>,
  ~checksumAddresses: bool,
  ~addressStore: AddressStore.t,
) => t = "new"

// Rust encodes JSON-RPC errors as a JSON payload in the napi error's
// message: `{"kind":"JsonRpcError","code":-32005,"message":"..."}`.
// Parse it back so callers keep matching on Rpc.JsonRpcError.
let getJsonRpcError = (exn: exn): option<Rpc.rpcError> =>
  switch exn {
  | JsExn(e) =>
    switch e->JsExn.message {
    | Some(msg) =>
      switch msg->JSON.parseOrThrow->JSON.Decode.object {
      | exception _ => None
      | None => None
      | Some(obj) =>
        switch (obj->Dict.get("kind"), obj->Dict.get("code"), obj->Dict.get("message")) {
        | (Some(String("JsonRpcError")), Some(Number(code)), Some(String(message))) =>
          Some({code: code->Float.toInt, message})
        | _ => None
        }
      }
    | None => None
    }
  | _ => None
  }

let coerceErrorOrThrow = exn =>
  switch exn->getJsonRpcError {
  | Some(rpcError) => throw(Rpc.JsonRpcError(rpcError))
  | None => exn->throw
  }

let make = (
  ~url,
  ~checksumAddresses,
  ~syncConfig: Config.sourceSync,
  ~httpReqTimeoutMillis=?,
  ~headers=?,
  ~eventRegistrations=[],
  ~addressStore,
) => {
  let client = Core.getAddon().evmRpcClient->classNew(
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
  {
    getHeight: () => client.getHeight()->Promise.catch(coerceErrorOrThrow),
    getNextPage: (params, addressSet) =>
      client.getNextPage(params, addressSet)->Promise.catch(coerceErrorOrThrow),
    fetchStoreData: missing => client.fetchStoreData(missing)->Promise.catch(coerceErrorOrThrow),
    getBlockHashes: blockNumbers => client.getBlockHashes(blockNumbers),
  }
}
