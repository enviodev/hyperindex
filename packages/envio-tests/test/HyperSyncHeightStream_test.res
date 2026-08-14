open Vitest

module NodeHttp = {
  type incomingMessage = {url: string}
  type serverResponse
  type server
  type address = {port: int}

  @module("node:http")
  external createServer: ((incomingMessage, serverResponse) => unit) => server = "createServer"

  @send external listen: (server, int, string, unit => unit) => unit = "listen"
  @send external closeServer: (server, unit => unit) => unit = "close"
  @send external address: server => address = "address"
  @send external writeHead: (serverResponse, int, dict<string>) => unit = "writeHead"
  @send external write: (serverResponse, string) => unit = "write"
  @send external endWith: (serverResponse, string) => unit = "end"
  @send external endResponse: (serverResponse, unit) => unit = "end"
}

type capturedLog = {
  level: string,
  msg: string,
  chainId: int,
  url: string,
  status: option<int>,
  error: option<string>,
  errorCount: int,
  fatal: bool,
  connectedForMillis: option<int>,
  retryInMillis: int,
}

// Swap the global logger for one that records structured payloads, so a test
// can assert on what an operator would actually see.
let withCapturedLogs = async (fn: (unit => array<capturedLog>) => promise<unit>) => {
  let captured = []
  let record = (level, message) => {
    let payload =
      message->(
        Utils.magic: Pino.pinoMessageBlob => {
          "msg": string,
          "chainId": option<int>,
          "url": option<string>,
          "status": option<int>,
          "error": option<string>,
          "errorCount": option<int>,
          "fatal": option<bool>,
          "connectedForMillis": option<int>,
          "retryInMillis": option<int>,
        }
      )
    captured
    ->Array.push({
      level,
      msg: payload["msg"],
      chainId: payload["chainId"]->Option.getOr(-1),
      url: payload["url"]->Option.getOr(""),
      status: payload["status"],
      error: payload["error"],
      errorCount: payload["errorCount"]->Option.getOr(-1),
      fatal: payload["fatal"]->Option.getOr(false),
      // Wall-clock dependent, so normalise it to a presence marker.
      connectedForMillis: payload["connectedForMillis"]->Option.map(_ => 0),
      retryInMillis: payload["retryInMillis"]->Option.getOr(-1),
    })
    ->ignore
  }
  let original = Logging.getLogger()
  Logging.setLogger({
    trace: message => record("trace", message),
    debug: message => record("debug", message),
    info: message => record("info", message),
    warn: message => record("warn", message),
    error: message => record("error", message),
    fatal: message => record("fatal", message),
  })
  let failure = try {
    await fn(() => captured)
    None
  } catch {
  | exn => Some(exn)
  }
  Logging.setLogger(original)
  switch failure {
  | Some(exn) => throw(exn)
  | None => ()
  }
}

let listen = handler => {
  let server = NodeHttp.createServer(handler)
  Promise.make((resolve, _) => {
    server->NodeHttp.listen(0, "127.0.0.1", () => {
      resolve((server, `http://127.0.0.1:${(server->NodeHttp.address).port->Int.toString}`))
    })
  })
}

let closeServer = server =>
  Promise.make((resolve, _) => server->NodeHttp.closeServer(() => resolve()))

let waitUntil = async (predicate: unit => bool) => {
  let deadline = Performance.now() +. 5_000.
  let rec loop = async () => {
    if predicate() {
      ()
    } else if Performance.now() > deadline {
      JsError.throwWithMessage("Timed out waiting for condition")
    } else {
      await Promise.make((resolve, _) => setTimeout(() => resolve(), 10)->ignore)
      await loop()
    }
  }
  await loop()
}

describe("HyperSyncHeightStream", () => {
  Async.it("logs the HTTP status when HyperSync rejects the height stream", async t => {
    let (server, url) = await listen((_req, res) => {
      res->NodeHttp.writeHead(429, Dict.fromArray([("Content-Type", "text/plain")]))
      res->NodeHttp.endWith("rate limited")
    })

    await withCapturedLogs(async getLogs => {
      let unsubscribe = HyperSyncHeightStream.subscribe(
        ~hyperSyncUrl=url,
        ~apiToken="test-token",
        ~chainId=137,
        ~onHeight=_ => (),
      )
      await waitUntil(() => getLogs()->Array.length > 0)
      unsubscribe()

      t.expect((getLogs())[0]).toStrictEqual(
        Some({
          level: "trace",
          msg: "EventSource error on height stream, reconnecting",
          chainId: 137,
          url,
          status: Some(429),
          error: Some("Non-200 status code (429)"),
          errorCount: 1,
          // The eventsource package gives up on a non-200 response instead of
          // retrying, so our layer owns the reconnect.
          fatal: true,
          connectedForMillis: None,
          retryInMillis: 100,
        }),
      )
    })

    await closeServer(server)
  })

  Async.it("logs an actionable error when the API token is rejected", async t => {
    let (server, url) = await listen((_req, res) => {
      res->NodeHttp.writeHead(401, Dict.fromArray([("Content-Type", "text/plain")]))
      res->NodeHttp.endWith("unauthorized")
    })

    await withCapturedLogs(async getLogs => {
      let unsubscribe = HyperSyncHeightStream.subscribe(
        ~hyperSyncUrl=url,
        ~apiToken="bad-token",
        ~chainId=137,
        ~onHeight=_ => (),
      )
      await waitUntil(() => getLogs()->Array.length > 0)
      unsubscribe()

      let first = (getLogs())[0]
      t.expect((first->Option.map(l => (l.level, l.msg, l.status)))).toStrictEqual(
        Some((
          "error",
          "Your ENVIO_API_TOKEN was rejected by HyperSync for the height stream. The indexer will not see new blocks until the token is fixed. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens",
          Some(401),
        )),
      )
    })

    await closeServer(server)
  })

  Async.it("reports how long a stream stayed connected before dropping", async t => {
    let (server, url) = await listen((_req, res) => {
      res->NodeHttp.writeHead(
        200,
        Dict.fromArray([("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")]),
      )
      res->NodeHttp.write("event: height\ndata: 123\n\n")
      // Ending the response drops the stream without any HTTP error, which is
      // the shape of the reconnect logs seen in production.
      res->NodeHttp.endResponse()
    })

    await withCapturedLogs(async getLogs => {
      let heights = []
      let unsubscribe = HyperSyncHeightStream.subscribe(
        ~hyperSyncUrl=url,
        ~apiToken="test-token",
        ~chainId=137,
        ~onHeight=height => heights->Array.push(height)->ignore,
      )
      await waitUntil(() =>
        getLogs()->Array.some(log => log.msg->String.includes("EventSource error"))
      )
      unsubscribe()

      let errorLog = (getLogs())->Array.find(log => log.msg->String.includes("EventSource error"))
      t.expect((heights, errorLog)).toStrictEqual((
        [123],
        Some({
          level: "trace",
          msg: "EventSource error on height stream, reconnecting",
          chainId: 137,
          url,
          status: None,
          error: None,
          errorCount: 1,
          // A clean stream end is recoverable, the library would have retried
          // on its own.
          fatal: false,
          connectedForMillis: Some(0),
          retryInMillis: 100,
        }),
      ))
    })

    await closeServer(server)
  })
})
