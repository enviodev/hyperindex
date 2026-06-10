open Vitest

module MockJsonRpcServer = {
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

  type t = {
    url: string,
    requests: array<string>,
    close: unit => unit,
  }

  let make = (~status, ~body) =>
    Promise.make((resolve, _reject) => {
      let requests = []
      let server = createServer((req, res) => {
        req->setEncoding("utf8")
        let data = ref("")
        req->onData(chunk => data := data.contents ++ chunk)
        req->onEnd(() => {
          requests->Array.push(data.contents)
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
}

let getHeightJsonRpcError = async (client: EvmRpcClient.t): option<Rpc.rpcError> =>
  try {
    let _ = await client.getHeight()
    None
  } catch {
  | Rpc.JsonRpcError(e) => Some(e)
  }

let getHeightErrorMessage = async (client: EvmRpcClient.t) =>
  try {
    let _ = await client.getHeight()
    None
  } catch {
  | JsExn(e) => e->JsExn.message
  }

describe("EvmRpcClient - getHeight via napi", () => {
  Async.it("Parses hex result and sends a JSON-RPC request", async t => {
    let mock = await MockJsonRpcServer.make(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":"0x1b4"}`,
    )
    let client = EvmRpcClient.make(~url=mock.url)

    let height = await client.getHeight()
    mock.close()

    t.expect((height, mock.requests->Array.map(r => r->JSON.parseOrThrow))).toEqual((
      436,
      [JSON.parseOrThrow(`{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}`)],
    ))
  })

  Async.it("Transfers JSON-RPC error as structured Rpc.JsonRpcError", async t => {
    let mock = await MockJsonRpcServer.make(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"limited to a 1000 blocks range"}}`,
    )
    let client = EvmRpcClient.make(~url=mock.url)

    let error = await getHeightJsonRpcError(client)
    mock.close()

    t.expect(error).toEqual(Some({code: -32005, message: "limited to a 1000 blocks range"}))
  })

  Async.it("Parses JSON-RPC error body even with a non-200 status", async t => {
    let mock = await MockJsonRpcServer.make(
      ~status=429,
      ~body=`{"jsonrpc":"2.0","id":1,"error":{"code":-32029,"message":"rate limited"}}`,
    )
    let client = EvmRpcClient.make(~url=mock.url)

    let error = await getHeightJsonRpcError(client)
    mock.close()

    t.expect(error).toEqual(Some({code: -32029, message: "rate limited"}))
  })

  Async.it("Reports HTTP status and body snippet for a non-JSON response", async t => {
    let mock = await MockJsonRpcServer.make(~status=502, ~body="upstream exploded")
    let client = EvmRpcClient.make(~url=mock.url)

    let message = await getHeightErrorMessage(client)
    mock.close()

    t.expect(message->Option.getOr("no error")).toMatch(
      /invalid JSON-RPC response for eth_blockNumber \(HTTP 502 Bad Gateway\): .+; body: upstream exploded/,
    )
  })

  Async.it("Fails when the response has neither result nor error", async t => {
    let mock = await MockJsonRpcServer.make(~status=200, ~body=`{"jsonrpc":"2.0","id":1}`)
    let client = EvmRpcClient.make(~url=mock.url)

    let message = await getHeightErrorMessage(client)
    mock.close()

    t.expect(message).toEqual(
      Some("JSON-RPC response for eth_blockNumber (HTTP 200 OK) has neither result nor error"),
    )
  })

  Async.it("Fails when getHeight result is null", async t => {
    let mock = await MockJsonRpcServer.make(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":null}`,
    )
    let client = EvmRpcClient.make(~url=mock.url)

    let message = await getHeightErrorMessage(client)
    mock.close()

    t.expect(message->Option.getOr("no error")).toMatch(/parse eth_blockNumber result/)
  })
})
