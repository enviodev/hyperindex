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

@send external writeHead: (res, int, dict<string>) => unit = "writeHead"
@send external end_: (res, string) => unit = "end"

type t = {url: string, requests: array<string>, close: unit => unit}

let start = (~handler: string => (int, string)) =>
  Promise.make((resolve, _reject) => {
    let requests = []
    let server = createServer((req, res) => {
      req->setEncoding("utf8")
      let data = ref("")
      req->onData(chunk => data := data.contents ++ chunk)
      req->onEnd(() => {
        requests->Array.push(data.contents)->ignore
        let (status, body) = handler(data.contents)
        res->writeHead(status, Dict.fromArray([("Content-Type", "application/json")]))
        res->end_(body)
      })
    })
    server->listen(0, () => {
      resolve({
        url: `http://127.0.0.1:${(server->address).port->Int.toString}`,
        requests,
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
// `method`.
let make = (~getResult: string => JSON.t) =>
  start(~handler=requestBody => {
    let method =
      requestBody
      ->JSON.parseOrThrow
      ->JSON.Decode.object
      ->Option.flatMap(Dict.get(_, "method"))
      ->Option.flatMap(JSON.Decode.string)
      ->Option.getOr("")
    (
      200,
      JSON.stringify(
        JSON.Object(
          Dict.fromArray([
            ("jsonrpc", JSON.String("2.0")),
            ("id", JSON.Number(1.)),
            ("result", getResult(method)),
          ]),
        ),
      ),
    )
  })
