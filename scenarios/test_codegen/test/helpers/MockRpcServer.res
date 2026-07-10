// A real local JSON-RPC server. eth_getLogs runs through the Rust client's own
// HTTP stack, which a globalThis.fetch stub can't intercept — tests point the
// source/client at one of these instead.
type server
type req
type res

@module("node:http")
external createServer: ((req, res) => unit) => server = "createServer"
@send external listen: (server, int, unit => unit) => unit = "listen"
@send external closeAllConnections: server => unit = "closeAllConnections"
@send external close: (server, unit => unit) => unit = "close"

type address = {port: int}
@send external address: server => address = "address"

@send external setEncoding: (req, string) => unit = "setEncoding"
@send external onData: (req, @as("data") _, string => unit) => unit = "on"
@send external onEnd: (req, @as("end") _, unit => unit) => unit = "on"
// Node's IncomingHttpHeaders values are `string | string[]` (duplicated headers
// arrive as arrays); model both and expose a single-value accessor below.
@unboxed type headerValue = Single(string) | Multiple(array<string>)
@get external reqHeaders: req => dict<headerValue> = "headers"

@send external writeHead: (res, int, dict<string>) => unit = "writeHead"
@send external end_: (res, string) => unit = "end"

type t = {
  url: string,
  requests: array<string>,
  requestHeaders: array<dict<headerValue>>,
  close: unit => unit,
}

// Read a single-valued request header (first value if it was repeated).
let getHeader = (headers: dict<headerValue>, name: string): option<string> =>
  switch headers->Dict.get(name) {
  | Some(Single(value)) => Some(value)
  | Some(Multiple(values)) => values->Array.get(0)
  | None => None
  }

let start = (~handler: string => (int, string)) =>
  Promise.make((resolve, _reject) => {
    let requests = []
    let requestHeaders = []
    let server = createServer((req, res) => {
      req->setEncoding("utf8")
      let data = ref("")
      req->onData(chunk => data := data.contents ++ chunk)
      req->onEnd(() => {
        requests->Array.push(data.contents)->ignore
        requestHeaders->Array.push(req->reqHeaders)->ignore
        let (status, body) = handler(data.contents)
        res->writeHead(status, Dict.fromArray([("Content-Type", "application/json")]))
        res->end_(body)
      })
    })
    server->listen(0, () => {
      resolve({
        url: `http://127.0.0.1:${(server->address).port->Int.toString}`,
        requests,
        requestHeaders,
        close: () => {
          server->closeAllConnections
          server->close(() => ())
        },
      })
    })
  })

// Reply with a fixed status and body to every request.
let makeRaw = (~status, ~body) => start(~handler=_ => (status, body))

// Reply 200 with a JSON-RPC envelope whose `result` is routed by the request's
// `method` and `params`, echoing the request's `id` back.
let makeWithParams = (~getResult: (~method: string, ~params: JSON.t) => JSON.t) =>
  start(~handler=requestBody => {
    let parsed = requestBody->JSON.parseOrThrow->JSON.Decode.object
    let method =
      parsed
      ->Option.flatMap(Dict.get(_, "method"))
      ->Option.flatMap(JSON.Decode.string)
      ->Option.getOr("")
    let params = parsed->Option.flatMap(Dict.get(_, "params"))->Option.getOr(JSON.Null)
    let id = parsed->Option.flatMap(Dict.get(_, "id"))->Option.getOr(JSON.Number(1.))
    (
      200,
      JSON.stringify(
        JSON.Object(
          Dict.fromArray([
            ("jsonrpc", JSON.String("2.0")),
            ("id", id),
            ("result", getResult(~method, ~params)),
          ]),
        ),
      ),
    )
  })

// Reply 200 with a JSON-RPC envelope whose `result` is routed by the request's
// `method`, echoing the request's `id` back.
let make = (~getResult: string => JSON.t) =>
  makeWithParams(~getResult=(~method, ~params as _) => getResult(method))
