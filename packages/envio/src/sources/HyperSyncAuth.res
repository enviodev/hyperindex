// A token the HyperSync/HyperFuel edge rejected. Both sources see the same error
// shape and owe the same response, so they share this rather than keeping two
// copies that can drift apart.

// Surfaced by the client (Rust) when the edge rejects the API token. The
// corrupted-token test feeds the real server error (from the query endpoint;
// the edge no longer 401s malformed tokens on /height) through this so it can't
// silently drift away from the message shape a 401 actually produces.
let isUnauthorizedError = (message: string) => message->String.includes("401 Unauthorized")

// Never swallows the failure: the caller's retry ramp has to keep asking,
// because a token can be replaced without restarting the indexer. All this adds
// is one loud line the first time a source sees a 401 - saying it on every retry
// would bury everything else in the log.
let rethrowLoggingUnauthorized = (exn: exn, ~warned: ref<bool>, ~product: string): 'a => {
  switch exn {
  | JsExn(jsExn) =>
    switch jsExn->JsExn.message {
    | Some(message) if message->isUnauthorizedError =>
      if !warned.contents {
        warned := true
        Logging.error(`Your ENVIO_API_TOKEN was rejected by ${product} (401 Unauthorized). The indexer will not be able to fetch events. Update the token and try again using 'envio start' or 'envio dev'. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens`)
      }
    | _ => ()
    }
  | _ => ()
  }
  throw(exn)
}
