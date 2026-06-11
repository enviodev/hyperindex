type cfg = {url: string, httpReqTimeoutMillis?: int}

type t = {getHeight: unit => promise<int>}

@send
external classNew: (Core.evmRpcClientCtor, cfg) => t = "new"

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

let make = (~url, ~httpReqTimeoutMillis=?) => {
  let client = Core.getAddon().evmRpcClient->classNew({url, ?httpReqTimeoutMillis})
  {
    getHeight: () => client.getHeight()->Promise.catch(coerceErrorOrThrow),
  }
}
