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
// its registration's chain-scoped index.
type rpcEventItem = {
  log: Rpc.GetLogs.log,
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
  addressesByContractName: dict<array<Address.t>>,
  // Contract names to fetch address-free even though their registrations
  // depend on addresses (client-side filtering). None/empty means
  // every address-dependent contract is filtered server-side.
  clientFilteredContracts: option<array<string>>,
}

type nextPageResponse = {
  items: array<rpcEventItem>,
  toBlock: int,
  requestStats: array<Source.requestStat>,
}

// The caller provides a range; Rust decides the actual `toBlock` and returns it.
type t = {
  getHeight: unit => promise<int>,
  getNextPage: nextPageParams => promise<nextPageResponse>,
}

@send
external classNew: (
  Core.evmRpcClientCtor,
  cfg,
  array<HyperSyncClient.Registration.input>,
  ~checksumAddresses: bool,
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
  )
  {
    getHeight: () => client.getHeight()->Promise.catch(coerceErrorOrThrow),
    getNextPage: params => client.getNextPage(params)->Promise.catch(coerceErrorOrThrow),
  }
}
