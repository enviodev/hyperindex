// Short enough that a chain at the head is not held up behind it, long enough
// that a wait polling through a whole block interval is not thousands of
// requests.
let pollingInterval = 400

// A napi error carries nothing but a message, so the native clients signal the
// recoverable conditions SourceManager knows how to retry as a `PREFIX:<int>`
// marker. Keep in sync with `request_stats.rs`.
let rateLimitedPrefix = "RATE_LIMITED:"
let behindHeadPrefix = "SOURCE_BEHIND_HEAD:"

let requireApiToken = apiToken =>
  switch apiToken {
  | Some(token) => token
  | None =>
    JsError.throwWithMessage(`An Envio API token is required for using HyperSync as a data-source.
Set the ENVIO_API_TOKEN environment variable in your .env file.
Learn more or get a free Envio API token at: https://envio.dev/app/api-tokens`)
  }

let isUnauthorizedError = (message: string) => message->String.includes("401 Unauthorized")

// Never swallows the failure: the caller's retry ramp has to keep asking,
// because a token can be replaced without restarting the indexer. All this adds
// is one loud line the first time a source sees a 401 - saying it on every retry
// would bury everything else in the log.
let rethrowLoggingUnauthorized = (
  exn: exn,
  ~logger: Logger.t,
  ~warned: ref<bool>,
  ~product: string,
): 'a => {
  switch exn {
  | JsExn(jsExn) =>
    switch jsExn->JsExn.message {
    | Some(message) if message->isUnauthorizedError =>
      if !warned.contents {
        warned := true
        logger->Logger.error(
          `Your ENVIO_API_TOKEN was rejected by ${product} (401 Unauthorized). The indexer will not be able to fetch events. Update the token and try again using 'envio start' or 'envio dev'. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens`,
        )
      }
    | _ => ()
    }
  | _ => ()
  }
  throw(exn)
}

let markerValue = (msg, ~prefix) =>
  msg->String.slice(~start=prefix->String.length, ~end=msg->String.length)->Int.fromString

let mapNativeFailure = (failure: Source.nativeRequestFailure) => {
  switch failure.message {
  | Some(msg) if msg->String.startsWith(rateLimitedPrefix) =>
    Source.RateLimited({
      resetMs: msg->markerValue(~prefix=rateLimitedPrefix)->Option.getOr(1000),
      requestStats: failure.requestStats,
    })
  | Some(msg) if msg->String.startsWith(behindHeadPrefix) =>
    Source.SourceBehindHead({
      blockNumber: msg->markerValue(~prefix=behindHeadPrefix)->Option.getOr(0),
      requestStats: failure.requestStats,
    })
  | _ => failure.cause
  }
}

let mapNativeFailureExn = exn => exn->Source.unpackNativeRequestFailure->mapNativeFailure

// Every HyperSync client paginates block hashes in Rust and returns the page
// store with the timings of the requests it took. A failure arrives as the
// native envelope, which carries those same timings, so the caller records them
// either way.
let makeGetBlockHashes = (
  ~query: (~blockNumbers: array<int>) => promise<(BlockStore.t, array<Source.requestStat>)>,
) =>
  async (~blockNumbers, ~logger as _) => {
    let (result, requestStats) = try {
      let (blockStore, requestStats) = await query(~blockNumbers)
      (Ok(blockStore), requestStats)
    } catch {
    | exn =>
      let failure = exn->Source.unpackNativeRequestFailure
      (Error(failure->mapNativeFailure), failure.requestStats)
    }
    {Source.result, requestStats}
  }

let reraiseIfRecoverable = exn =>
  switch exn->mapNativeFailureExn {
  | (Source.RateLimited(_) | Source.SourceBehindHead(_)) as exn => throw(exn)
  | _ => ()
  }
