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

// Decoded `params` keyed by contract name, matching the HyperSync decoder's
// shape so the caller routes by address then picks its contract's params.
type rpcEventItem = {
  log: Rpc.GetLogs.log,
  params: Nullable.t<dict<Internal.eventParams>>,
}

// `addresses` omitted matches any address (a wildcard selection). Each `topics`
// position is `null` (match any) or a list of accepted topic hashes; the
// single-match case is a one-element list.
type logSelectionInput = {
  addresses?: array<Address.t>,
  topics: array<Nullable.t<array<string>>>,
}

type nextPageParams = {
  fromBlock: int,
  toBlockCeiling: int,
  logSelections: array<logSelectionInput>,
  partitionId: string,
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
  array<HyperSyncClient.Decoder.eventParamsInput>,
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
  ~allEventParams=[],
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
    allEventParams,
    ~checksumAddresses,
  )
  {
    getHeight: () => client.getHeight()->Promise.catch(coerceErrorOrThrow),
    getNextPage: params => client.getNextPage(params)->Promise.catch(coerceErrorOrThrow),
  }
}
