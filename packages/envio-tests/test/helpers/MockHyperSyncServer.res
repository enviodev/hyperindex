// A real local HyperSync server (Rust, from the native addon). The query is
// built, sent, and decoded inside the addon's HTTP stack, so this is the only
// place a test can see what the source asks HyperSync for — and the only way to
// answer it with a page the real decoder accepts.
//
// Rows are JSON objects keyed by HyperSync field names (snake_case, as in the
// query's `field_selection`); values are `0x` hex strings, or numbers for
// numeric fields. Only fields the query selected are read back, so a row may
// carry as few as the test cares about.
type t

@send
external classNew: (Core.mockHyperSyncServerCtor, Null.t<int>) => t = "new"
@send external url: t => string = "url"
@send external setHeight: (t, int) => unit = "setHeight"
@send external pushResponseJson: (t, string) => unit = "pushResponse"
@send external takeQueriesJson: t => array<string> = "takeQueries"
@send external close: t => unit = "close"

// The addon's client rejects a token that isn't a UUID before it ever reaches
// the server, so tests need a well-formed one.
let apiToken = "00000000-0000-0000-0000-000000000000"

type page = {
  blocks?: array<JSON.t>,
  transactions?: array<JSON.t>,
  logs?: array<JSON.t>,
  // Defaults to the query's exclusive `to_block`, ie the whole range was scanned.
  nextBlock?: int,
  // Defaults to the server's height.
  archiveHeight?: int,
  rollbackGuard?: JSON.t,
}

let make = (~height=?) =>
  Core.getAddon().mockHyperSyncServer->classNew(height->Null.fromOption)

/// Queue the page answering the next query. Queries past the last queued page
/// are answered with an empty page covering the range they asked for.
let pushResponse = (server, page: page) =>
  server->pushResponseJson(page->JSON.stringifyAny->Option.getOrThrow)

// A reply given at the HTTP level instead of as a page — the statuses the
// client acts on itself (429 rate limited, 413 payload too large).
type rawReply = {status: int, headers?: dict<string>, body?: string}

/// Queue an HTTP-level reply for the next query.
let pushRawReply = (server, reply: rawReply) =>
  server->pushResponseJson(reply->JSON.stringifyAny->Option.getOrThrow)

/// The query bodies received so far, oldest first, draining them.
let takeQueries = server => server->takeQueriesJson->Array.map(body => body->JSON.parseOrThrow)

let withServer = async (~height=?, body) => {
  let server = make(~height?)
  try {
    let result = await body(server)
    server->close
    result
  } catch {
  | exn =>
    server->close
    throw(exn)
  }
}
