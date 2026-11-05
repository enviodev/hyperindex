// The napi clients wrap a failure of a multi-request operation in a
// structured payload, so its timings survive the error. Read back here for the
// tests that call a client directly.
type t = {
  message: option<string>,
  requestStats: array<Source.requestStat>,
}

// Keep in sync with `request_stats.rs` `NATIVE_FAILURE_PREFIX`.
let prefix = "ENVIO_NATIVE_FAILURE:"

let payloadSchema = S.schema(s => {
  message: s.matches(S.option(S.string)),
  requestStats: s.matches(
    S.array(
      S.schema(s => {
        Source.method: s.matches(S.string),
        seconds: s.matches(S.float),
      }),
    ),
  ),
})

let unpack = (exn: exn): t => {
  let message = switch exn->JsExn.anyToExnInternal {
  | JsExn(jsExn) => jsExn->JsExn.message
  | _ => None
  }
  switch message {
  | Some(message) if message->String.startsWith(prefix) =>
    message
    ->String.slice(~start=prefix->String.length)
    ->JSON.parseOrThrow
    ->S.parseOrThrow(payloadSchema)
  | _ => {message, requestStats: []}
  }
}
