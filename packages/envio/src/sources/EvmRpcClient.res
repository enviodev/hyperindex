type cfg = {
  url: string,
  httpReqTimeoutMillis?: int,
  headers?: dict<string>,
  // Sync-tuning knobs for the paging AIMD state that now lives in Rust (see
  // `getNextPage` below). Omitted by callers (like the low-level napi tests)
  // that only ever use `getHeight`/`getLogs`.
  initialBlockInterval?: int,
  backoffMultiplicative?: float,
  accelerationAdditive?: int,
  intervalCeiling?: int,
  backoffMillis?: int,
  queryTimeoutMillis?: int,
}

// `addresses` omitted matches any address (a wildcard selection). Each `topics`
// position is `null` (match any) or a list of accepted topic hashes; the
// single-match case is a one-element list.
type getLogsParams = {
  fromBlock: int,
  toBlock: int,
  addresses?: array<Address.t>,
  topics: array<Nullable.t<array<string>>>,
}

// Decoded `params` keyed by contract name, matching the HyperSync decoder's
// shape so the caller routes by address then picks its contract's params.
type rpcEventItem = {
  log: Rpc.GetLogs.log,
  params: Nullable.t<dict<Internal.eventParams>>,
}

// Same shape as `getLogsParams` minus `fromBlock`/`toBlock` — `getNextPage`
// applies one shared range (that it decides internally) across every selection.
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

type t = {
  getHeight: unit => promise<int>,
  getLogs: getLogsParams => promise<array<rpcEventItem>>,
  // Paging, dedup, the query-timeout race, and the AIMD-suggested interval
  // state all live in the Rust client now — this just asks for a range and
  // Rust decides the actual `toBlock`. On failure, throws a napi error whose
  // message encodes the retry decision (see `RpcSource.res`'s
  // `parseGetNextPageRetryError`).
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
  ~httpReqTimeoutMillis=?,
  ~headers=?,
  ~allEventParams=[],
  ~initialBlockInterval=?,
  ~backoffMultiplicative=?,
  ~accelerationAdditive=?,
  ~intervalCeiling=?,
  ~backoffMillis=?,
  ~queryTimeoutMillis=?,
) => {
  let client = Core.getAddon().evmRpcClient->classNew(
    {
      url,
      ?httpReqTimeoutMillis,
      ?headers,
      ?initialBlockInterval,
      ?backoffMultiplicative,
      ?accelerationAdditive,
      ?intervalCeiling,
      ?backoffMillis,
      ?queryTimeoutMillis,
    },
    allEventParams,
    ~checksumAddresses,
  )
  {
    getHeight: () => client.getHeight()->Promise.catch(coerceErrorOrThrow),
    getLogs: params => client.getLogs(params)->Promise.catch(coerceErrorOrThrow),
    getNextPage: params => client.getNextPage(params)->Promise.catch(coerceErrorOrThrow),
  }
}
